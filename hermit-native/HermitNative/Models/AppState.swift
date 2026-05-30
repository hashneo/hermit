import Foundation
import Combine

// MARK: - ServerMode (hermit-u1k / hermit-3wh)

/// The three connectivity modes defined in RFC-013 / ADR-009.
enum ServerMode: Codable, Equatable, Hashable {
    /// macOS only: Go server runs in-process, client hits localhost.
    case embeddedLocal
    /// iPad (and macOS): server discovered via Bonjour on the local network.
    case localNetwork
    /// Both platforms: explicit hosted URL entered manually.
    case remote(url: String)

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case type, url }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "embeddedLocal":  self = .embeddedLocal
        case "localNetwork":   self = .localNetwork
        case "remote":
            let url = try c.decode(String.self, forKey: .url)
            self = .remote(url: url)
        default: self = .embeddedLocal
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .embeddedLocal:     try c.encode("embeddedLocal", forKey: .type)
        case .localNetwork:      try c.encode("localNetwork",  forKey: .type)
        case .remote(let url):
            try c.encode("remote", forKey: .type)
            try c.encode(url,      forKey: .url)
        }
    }
}

// MARK: - AppState

/// Central application state shared across all views via @EnvironmentObject.
@MainActor
final class AppState: ObservableObject {
    /// Shared singleton used by HermitNativeApp so AppState is ready before SwiftUI scenes render.
    static let shared = AppState()

    @Published var isAuthenticated: Bool
    @Published var baseURL: String        // Hermit server base URL (legacy field, superseded by serverBaseURL)
    @Published var giteaBaseURL: String   // Gitea/registry API base URL (e.g. http://localhost:3000/api/v1)
    @Published var repoOwner: String
    @Published var repoName: String
    @Published var docsPath: String
    @Published var rfcLabel: String
    @Published var pat: String

    // hermit-999: NSUserActivity — shared selection state
    /// The RFC currently being viewed. Written by iPadRootView (iOS) and
    /// RFCViewerWindowManager (macOS) so NSUserActivity machinery can read it.
    @Published var selectedRFC: RFC? = nil
    /// The comment-thread line currently selected, coordinated across devices.
    @Published var selectedLine: Int? = nil
    /// The last raw file line of the selected block (inclusive). Used alongside
    /// selectedLine to match threads anchored anywhere within a multi-line block
    /// (e.g. a comment placed on a line inside a fenced code block).
    @Published var selectedLineEnd: Int? = nil

    // hermit-z9j: pending Handoff navigation (set on continuation, consumed once store loads)
    @Published var pendingHandoffRFCID: String? = nil
    @Published var pendingHandoffLine: Int?     = nil

    // hermit-txn: pending deep-link navigation (set by onOpenURL / open(urls:), consumed once store loads)
    /// Decoded RFC path from a hermit://rfc/<path> URL, waiting for the RFC store to load.
    @Published var pendingDeepLinkPath: String? = nil

    // hermit-iwq: UserDefaults keys for scene restoration
    private enum RestoreKey {
        static let rfcID   = "hermit.restore.rfcID"
        static let rfcPath = "hermit.restore.rfcPath"
    }

    /// Persist the last-viewed RFC id and path so the next launch can restore it.
    func persistLastViewedRFC(_ rfc: RFC?) {
        if let rfc {
            UserDefaults.standard.set(rfc.id,   forKey: RestoreKey.rfcID)
            UserDefaults.standard.set(rfc.path, forKey: RestoreKey.rfcPath)
        } else {
            UserDefaults.standard.removeObject(forKey: RestoreKey.rfcID)
            UserDefaults.standard.removeObject(forKey: RestoreKey.rfcPath)
        }
    }

    /// Returns the persisted RFC id from the previous session, if any.
    var restoredRFCID: String? { UserDefaults.standard.string(forKey: RestoreKey.rfcID) }

    // hermit-u1k / RFC-013: server connectivity
    @Published var serverMode: ServerMode = .embeddedLocal
    /// The resolved base URL of the active Hermit server (set by EmbeddedServerManager
    /// or chosen from discovered/remote servers).
    @Published var serverBaseURL: String = ""
    /// Bearer token received via MPC pairing (local-network mode). Held in memory
    /// so it works in both DEBUG (no Keychain) and release builds.
    @Published var localNetworkToken: String = ""

    init() {
#if DEBUG
        // Debug builds: load config directly from bundled DevConfig/ (hermit.yaml +
        // gitea-token-export.sh embedded by `make native-embed-config`).
        // This works on both iOS and macOS and avoids relying on cfprefsd cache
        // timing issues or Keychain prompts on first launch after a reset.
        do {
            let detected = try GiteaAutoConfig.detect()
            isAuthenticated = true
            baseURL         = detected.baseURL
            giteaBaseURL    = detected.giteaBaseURL
            repoOwner       = detected.owner
            repoName        = detected.repo
            docsPath        = detected.docsPath
            rfcLabel        = detected.rfcLabel
            pat             = detected.pat
            serverMode      = .embeddedLocal
#if os(iOS)
            // On the simulator there is no mDNS pairing, so seed serverBaseURL
            // directly from the bundled config so makeAPIClient() can return a
            // client on first load (rather than waiting for a pairing event that
            // never arrives).
            serverBaseURL   = detected.baseURL
#else
            serverBaseURL   = ""   // set by EmbeddedServerManager after server starts
#endif
            localNetworkToken = ConfigStore.shared.localNetworkToken ?? ""
            // Persist so ConfigStore is warm on next launch
            ConfigStore.shared.apply(ConfigStore.RepoConfig(
                baseURL:  detected.giteaBaseURL.isEmpty ? detected.baseURL : detected.giteaBaseURL,
                owner:    detected.owner,
                repo:     detected.repo,
                docsPath: detected.docsPath,
                rfcLabel: detected.rfcLabel
            ))
            if !detected.pat.isEmpty {
                if let conn = AccountStore.shared.connections.first {
                    // Use updateTokenOnly to avoid posting hermitRestartRequired
                    // during init — the server has not started yet at this point.
                    AccountStore.shared.updateTokenOnly(conn, token: detected.pat)
                }
            }
#if os(iOS)
            // Seed RepositoryStore from bundled config so the repo switcher is
            // populated on the simulator (no mDNS replaceAll(fromMDNS:) fires here).
            if RepositoryStore.shared.repositories.isEmpty {
                let accountID = AccountStore.shared.connections.first?.id
                              ?? UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
                RepositoryStore.shared.add(
                    accountID: accountID,
                    owner:     detected.owner,
                    name:      detected.repo,
                    docsPath:  detected.docsPath,
                    rfcLabel:  detected.rfcLabel
                )
            }
#endif
            debugLog("loaded from bundled config — \(detected.owner)/\(detected.repo) @ \(detected.baseURL)")
            pendingHandoffRFCID = UserDefaults.standard.string(forKey: RestoreKey.rfcID)
            return
        } catch {
            debugLog("GiteaAutoConfig.detect() failed — falling back to ConfigStore: \(error)")
        }
#endif
        // Release builds (and debug fallback when bundled config is absent):
        // Non-secret config lives in UserDefaults (ConfigStore); PAT in Keychain (release)
        // or UserDefaults via the Connection struct (debug).
        let cs = ConfigStore.shared
        let resolvedPAT   = AccountStore.shared.connections.first.flatMap {
            AccountStore.shared.token(for: $0)
        } ?? ""
        pat               = resolvedPAT
        baseURL           = cs.baseURL   ?? ""
        giteaBaseURL      = ""
        repoOwner         = cs.repoOwner ?? ""
        repoName          = cs.repoName  ?? ""
        docsPath          = cs.docsPath  ?? "docs-cms/rfcs"
        rfcLabel          = cs.rfcLabel  ?? "hermit:rfc-ready"
        serverMode        = cs.serverMode ?? .embeddedLocal
        localNetworkToken = cs.localNetworkToken ?? ""
        isAuthenticated   = cs.isConfigured && !resolvedPAT.isEmpty
#if os(iOS)
        serverBaseURL = ""
#else
        serverBaseURL = cs.serverBaseURL ?? ""
#endif
        pendingHandoffRFCID = UserDefaults.standard.string(forKey: RestoreKey.rfcID)
    }

    /// Refreshes published state from ConfigStore + Keychain/UserDefaults (call after saving settings).
    func applyConfig() {
        let cs = ConfigStore.shared
        pat           = AccountStore.shared.connections.first.flatMap {
            AccountStore.shared.token(for: $0)
        } ?? ""
        baseURL       = cs.baseURL   ?? ""
        repoOwner     = cs.repoOwner ?? ""
        repoName      = cs.repoName  ?? ""
        docsPath      = cs.docsPath  ?? "docs-cms/rfcs"
        rfcLabel      = cs.rfcLabel  ?? "hermit:rfc-ready"
        serverMode    = cs.serverMode ?? .embeddedLocal
        serverBaseURL = cs.serverBaseURL ?? ""
        isAuthenticated = cs.isConfigured && !pat.isEmpty
    }

    // Keep old name as an alias so any missed call sites still compile.
    func applyKeychain() { applyConfig() }

    // MARK: - API client factory

    /// Returns a HermitAPIClient aimed at the configured server URL, or nil
    /// if authentication or a server URL is not yet set.
    ///
    /// All GitHub interactions flow through the Go backend — there is no
    /// direct GitHub API fallback in the native client.
    func makeAPIClient() -> (any HermitClientProtocol)? {
        guard !serverBaseURL.isEmpty else { return nil }

        // Local-network mode: authenticate with the MPC-paired bearer token.
        // The Go server validates it against PairedTokenStore; no GitHub PAT needed.
        let bearer: String
        if case .localNetwork = serverMode {
            guard !localNetworkToken.isEmpty else { return nil }
            bearer = localNetworkToken
        } else {
            // Read the PAT from the live AccountStore so we always use the token
            // for the first/matching account, not a potentially stale AppState snapshot.
            let livePAT = AccountStore.shared.connections.first.flatMap {
                AccountStore.shared.token(for: $0)
            } ?? pat
            guard !livePAT.isEmpty else { return nil }
            bearer = livePAT
        }

        // Read owner/repo/docsPath from the live RepositoryStore so that switching
        // repos is reflected immediately without waiting for applyConfig().
        let activeRepo = RepositoryStore.shared.repositories.first
        let cfg = HermitAPIClient.Config(
            baseURL:  serverBaseURL,
            repositoryID: activeRepo?.serverID,
            owner:    activeRepo?.owner    ?? repoOwner,
            repo:     activeRepo?.name     ?? repoName,
            docsPath: activeRepo?.docsPath ?? docsPath,
            rfcLabel: activeRepo?.rfcLabel ?? rfcLabel,
            pat:      bearer
        )
        return HermitAPIClient(config: cfg)
    }

    /// Returns a client scoped to a specific repository.
    func makeAPIClient(for repo: Repository) -> (any HermitClientProtocol)? {
        guard !serverBaseURL.isEmpty else { return nil }
        let bearer: String
        if case .localNetwork = serverMode {
            guard !localNetworkToken.isEmpty else { return nil }
            bearer = localNetworkToken
        } else {
            let conn = AccountStore.shared.connections.first(where: { $0.id == repo.accountID })
                    ?? AccountStore.shared.connections.first
            // Fall back to appState.pat (set by GiteaAutoConfig bundled config) when
            // the account store has no token — this covers the dev migration path.
            let storeToken = conn.flatMap { AccountStore.shared.token(for: $0) } ?? ""
            let token = storeToken.isEmpty ? pat : storeToken
            guard !token.isEmpty else { return nil }
            bearer = token
        }
        let cfg = HermitAPIClient.Config(
            baseURL:  serverBaseURL,
            repositoryID: repo.serverID,
            owner:    repo.owner,
            repo:     repo.name,
            docsPath: repo.docsPath,
            rfcLabel: repo.rfcLabel,
            pat:      bearer
        )
        return HermitAPIClient(config: cfg)
    }

    // MARK: - Display helpers

    /// Human-readable repo label for display in the UI.
    var repoLabel: String {
        guard !repoOwner.isEmpty, !repoName.isEmpty else { return "Not configured" }
        return "\(repoOwner)/\(repoName)"
    }

    /// Short display name for the server (hostname only).
    var serverLabel: String {
        guard let url = URL(string: baseURL), let host = url.host else { return baseURL }
        let port = url.port.map { ":\($0)" } ?? ""
        return host + port
    }
}

#if DEBUG
private func debugLog(_ message: String) {
    let line = "[\(Date())] [AppState] \(message)\n"
    let logURL = URL(fileURLWithPath: "/tmp/hermit-native-debug.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
}
#endif
