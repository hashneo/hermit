import Foundation
#if os(macOS)
import AppKit
#endif

// MARK: - GiteaAutoConfig
// hermit-rij: Reads the local hermit repo config and Gitea token, then
// produces a ConfigStore.RepoConfig ready to apply.
//
// Resolution strategy (in order):
//  1. BookmarkStore (security-scoped bookmark, set by user via NSOpenPanel)
//  2. HERMIT_REPO_PATH environment variable
//  3. The directory containing the running app bundle, walking up to find
//     a directory that contains both "config/hermit.yaml" and ".tmp/"
//  4. Well-known developer paths
//
// With app-sandbox enabled (required for Handoff), only strategy 1 can
// reliably access paths outside the sandbox container. Strategies 2-4 are
// retained for the initial setup flow where the user hasn't chosen a path yet.

enum GiteaAutoConfig {

    struct DetectedConfig: Equatable {
        let baseURL: String        // Hermit Go server URL (e.g. http://localhost:8080)
        let giteaBaseURL: String   // Gitea/registry API base URL (e.g. http://localhost:3000/api/v1)
        let pat: String
        let owner: String
        let repo: String
        let docsPath: String
        let rfcLabel: String
        let resolvedFrom: String   // path of hermit.yaml for display in UI
    }

    enum AutoConfigError: LocalizedError {
        case repoNotFound
        case configFileMissing(String)
        case tokenFileMissing(String)
        case noGiteaRegistry
        case noGiteaRepository
        case parseError(String)

        var errorDescription: String? {
            switch self {
            case .repoNotFound:
                return "Could not locate the Hermit repository on this machine."
            case .configFileMissing(let p):
                return "config/hermit.yaml not found at \(p)."
            case .tokenFileMissing(let p):
                return "Gitea token file not found at \(p). Run 'make gitea-up' first."
            case .noGiteaRegistry:
                return "No Gitea registry found in hermit.yaml."
            case .noGiteaRepository:
                return "No Gitea-backed repository found in hermit.yaml."
            case .parseError(let detail):
                return "Failed to parse config: \(detail)"
            }
        }
    }

    // MARK: - Main entry point

    /// Detects the local Gitea config without any user input.
    /// On a sandboxed build the bookmark must already be stored; call
    /// `promptAndDetect()` first if `BookmarkStore.shared.hasBookmark` is false.
    static func detect() throws -> DetectedConfig {
        // Try reading config embedded in the app bundle first (sandboxed debug builds).
        if let bundled = try? loadFromBundle() { return bundled }
        let repoRoot = try findRepoRoot()
        return try load(from: repoRoot)
    }

    /// Reads hermit.yaml and the token file from the DevConfig/ folder
    /// embedded in the app bundle by `make native-embed-config`.
    private static func loadFromBundle() throws -> DetectedConfig {
        guard
            let configURL = Bundle.main.url(forResource: "hermit", withExtension: "yaml", subdirectory: "DevConfig"),
            let tokenURL  = Bundle.main.url(forResource: "gitea-token-export", withExtension: "sh", subdirectory: "DevConfig")
        else {
            throw AutoConfigError.repoNotFound  // not bundled — fall through
        }
        let configText = try String(contentsOf: configURL, encoding: .utf8)
        let tokenText  = try String(contentsOf: tokenURL,  encoding: .utf8)
        let token = try parseToken(from: tokenText)
        let (giteaBaseURL, owner, repo, docsPath) = try parseConfig(configText, token: token)
        let hermitServerURL = parseListenAddress(configText) ?? "http://localhost:8080"
        return DetectedConfig(
            baseURL:       hermitServerURL,
            giteaBaseURL:  giteaBaseURL,
            pat:           token,
            owner:         owner,
            repo:          repo,
            docsPath:      docsPath,
            rfcLabel:      "",
            resolvedFrom:  configURL.path
        )
    }

#if os(macOS)
    /// Presents NSOpenPanel asking the user to select the Hermit repo root,
    /// saves a security-scoped bookmark, then returns the detected config.
    /// Must be called on the main thread.
    @MainActor
    static func promptAndDetect() throws -> DetectedConfig {
        let panel = NSOpenPanel()
        panel.title = "Locate Hermit Repository"
        panel.message = "Select the root folder of your local Hermit repository (the folder that contains config/hermit.yaml)."
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Repository"

        guard panel.runModal() == .OK, let url = panel.url else {
            throw AutoConfigError.repoNotFound
        }
        guard isHermitRoot(url) else {
            throw AutoConfigError.configFileMissing(url.path)
        }

        BookmarkStore.shared.save(url)
        return try load(from: url)
    }
#endif

    // MARK: - Repo root discovery

    private static func findRepoRoot() throws -> URL {
#if os(macOS)
        // 1. Security-scoped bookmark (sandboxed access persisted by user)
        if let bookmarked = BookmarkStore.shared.resolve() {
            if isHermitRoot(bookmarked) { return bookmarked }
            BookmarkStore.shared.stopAccessing()
        }
#endif

        // 2. Environment override
        if let envPath = ProcessInfo.processInfo.environment["HERMIT_REPO_PATH"] {
            let url = URL(fileURLWithPath: envPath)
            if isHermitRoot(url) { return url }
        }

        // 3. Walk up from the app bundle
        var candidate = Bundle.main.bundleURL
        for _ in 0..<10 {
            candidate = candidate.deletingLastPathComponent()
            if isHermitRoot(candidate) { return candidate }
        }

        // 4. Well-known developer paths
        let knownPaths = [
            "~/Development/github/hashicorp/hermit",
            "~/code/hashicorp/hermit",
            "~/projects/hashicorp/hermit",
        ]
        for rawPath in knownPaths {
            let expanded = URL(fileURLWithPath: (rawPath as NSString).expandingTildeInPath)
            if isHermitRoot(expanded) { return expanded }
        }

        throw AutoConfigError.repoNotFound
    }

    private static func isHermitRoot(_ url: URL) -> Bool {
        let configPath = url.appendingPathComponent("config/hermit.yaml")
        return FileManager.default.fileExists(atPath: configPath.path)
    }

    // MARK: - Config + token loading

    private static func load(from repoRoot: URL) throws -> DetectedConfig {
        let configURL = repoRoot.appendingPathComponent("config/hermit.yaml")
        let tokenURL  = repoRoot.appendingPathComponent(".tmp/gitea-token-export.sh")

        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw AutoConfigError.configFileMissing(repoRoot.path)
        }
        guard FileManager.default.fileExists(atPath: tokenURL.path) else {
            throw AutoConfigError.tokenFileMissing(tokenURL.path)
        }

        let configText = try String(contentsOf: configURL, encoding: .utf8)
        let tokenText  = try String(contentsOf: tokenURL,  encoding: .utf8)

        let token = try parseToken(from: tokenText)
        let (giteaBaseURL, owner, repo, docsPath) = try parseConfig(configText, token: token)

        // The native app talks to the Hermit Go backend, not Gitea directly.
        // GUI → Go server (:8080) → Gitea/GitHub
        let hermitServerURL = parseListenAddress(configText) ?? "http://localhost:8080"

        return DetectedConfig(
            baseURL:       hermitServerURL,
            giteaBaseURL:  giteaBaseURL,
            pat:           token,
            owner:         owner,
            repo:          repo,
            docsPath:      docsPath,
            rfcLabel:      "",
            resolvedFrom:  configURL.path
        )
    }

    // MARK: - Listen address parsing

    /// Reads listen_address from hermit.yaml and converts it to an http:// URL.
    /// e.g. ":8080" → "http://localhost:8080"
    private static func parseListenAddress(_ yaml: String) -> String? {
        for line in yaml.components(separatedBy: .newlines) {
            let stripped = line.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("listen_address:") {
                if let raw = value(from: stripped, key: "listen_address:") {
                    // raw may be ":8080" or "0.0.0.0:8080"
                    let port = raw.components(separatedBy: ":").last ?? "8080"
                    return "http://localhost:\(port)"
                }
            }
        }
        return nil
    }

    // MARK: - Token parsing
    // Parses:  export GITEA_TOKEN=abc123...
    // or:      GITEA_TOKEN=abc123...

    private static func parseToken(from text: String) throws -> String {
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Match both `export GITEA_TOKEN=value` and `GITEA_TOKEN=value`
            if let range = trimmed.range(of: #"(?:export\s+)?GITEA_TOKEN=(.+)"#,
                                          options: .regularExpression) {
                let full = String(trimmed[range])
                if let eqRange = full.range(of: "=") {
                    let value = String(full[full.index(after: eqRange.lowerBound)...])
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                    if !value.isEmpty { return value }
                }
            }
        }
        throw AutoConfigError.parseError("GITEA_TOKEN not found in token file.")
    }

    // MARK: - YAML parsing (lightweight, no dependencies)
    // We only need a handful of values so a full YAML parser is overkill.
    // Strategy: find the gitea-local registry base_url, then the repo that
    // references it, extract owner/name/docs_path_policy.

    private static func parseConfig(
        _ yaml: String,
        token: String
    ) throws -> (baseURL: String, owner: String, repo: String, docsPath: String) {

        let lines = yaml.components(separatedBy: .newlines)

        // ── Find the Gitea registry base_url ──────────────────────────────
        var giteaRegistryName: String? = nil
        var giteaBaseURL: String? = nil
        var inRegistry = false
        var currentRegistryName: String? = nil
        var currentRegistryKind: String? = nil
        var currentRegistryBase: String? = nil

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)

            // Detect start of a registry block (list item with `- name:`)
            if stripped.hasPrefix("- name:") {
                // Flush previous registry
                if currentRegistryKind == "github",
                   let base = currentRegistryBase,
                   base.contains("localhost") || base.contains("gitea"),
                   let name = currentRegistryName {
                    giteaRegistryName = name
                    giteaBaseURL = base
                }
                currentRegistryName = value(from: stripped, key: "- name:")
                currentRegistryKind = nil
                currentRegistryBase = nil
                inRegistry = true
            } else if inRegistry {
                if stripped.hasPrefix("kind:") {
                    currentRegistryKind = value(from: stripped, key: "kind:")
                } else if stripped.hasPrefix("base_url:") {
                    currentRegistryBase = value(from: stripped, key: "base_url:")
                } else if stripped.hasPrefix("name:") && !stripped.hasPrefix("- name:") {
                    // sub-key in another section — we've left the registry block
                    inRegistry = false
                }
            }
        }
        // Flush last registry
        if currentRegistryKind == "github",
           let base = currentRegistryBase,
           (base.contains("localhost") || base.contains("gitea")),
           let name = currentRegistryName {
            giteaRegistryName = name
            giteaBaseURL = base
        }

        guard let registryName = giteaRegistryName,
              let baseURL = giteaBaseURL else {
            throw AutoConfigError.noGiteaRegistry
        }

        // ── Find the repository that uses this registry ───────────────────
        var owner: String? = nil
        var repoName: String? = nil
        var docsPath: String? = nil

        var inRepo = false
        var currentOwner: String? = nil
        var currentRepoName: String? = nil
        var currentRegistry: String? = nil
        var currentDocs: String? = nil

        for line in lines {
            let stripped = line.trimmingCharacters(in: .whitespaces)

            if stripped.hasPrefix("- owner:") {
                // Flush previous repo
                if currentRegistry == registryName,
                   let o = currentOwner, let r = currentRepoName {
                    owner    = o
                    repoName = r
                    docsPath = currentDocs
                }
                currentOwner    = value(from: stripped, key: "- owner:")
                currentRepoName = nil
                currentRegistry = nil
                currentDocs     = nil
                inRepo = true
            } else if inRepo {
                if stripped.hasPrefix("name:") {
                    currentRepoName = value(from: stripped, key: "name:")
                } else if stripped.hasPrefix("registry:") {
                    currentRegistry = value(from: stripped, key: "registry:")
                } else if stripped.hasPrefix("docs_path_policy:") {
                    currentDocs = value(from: stripped, key: "docs_path_policy:")
                }
            }
        }
        // Flush last repo
        if currentRegistry == registryName,
           let o = currentOwner, let r = currentRepoName {
            owner    = o
            repoName = r
            docsPath = currentDocs
        }

        guard let resolvedOwner = owner, let resolvedRepo = repoName else {
            throw AutoConfigError.noGiteaRepository
        }

        return (
            baseURL:  baseURL,
            owner:    resolvedOwner,
            repo:     resolvedRepo,
            docsPath: (docsPath ?? "docs-cms/rfcs")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
    }

    /// Extracts the value after a key prefix in a YAML line.
    /// e.g. value(from: "  base_url: http://localhost:3000", key: "base_url:") → "http://localhost:3000"
    private static func value(from line: String, key: String) -> String? {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix(key) else { return nil }
        s = String(s.dropFirst(key.count))
            .trimmingCharacters(in: .whitespaces)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return s.isEmpty ? nil : s
    }
}

// MARK: - Convenience: apply detected config to stores

extension GiteaAutoConfig.DetectedConfig {
    func toRepoConfig() -> ConfigStore.RepoConfig {
        ConfigStore.RepoConfig(
            baseURL:  baseURL,
            owner:    owner,
            repo:     repo,
            docsPath: docsPath,
            rfcLabel: rfcLabel
        )
    }
}
