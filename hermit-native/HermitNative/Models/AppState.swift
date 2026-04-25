import Foundation
import Combine

/// Central application state shared across all views via @EnvironmentObject.
@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated: Bool
    @Published var baseURL: String
    @Published var repoOwner: String
    @Published var repoName: String
    @Published var docsPath: String
    @Published var rfcLabel: String
    @Published var pat: String

    private let keychain = KeychainHelper.shared

    init() {
#if DEBUG
        // In debug builds, load config directly from hermit.yaml + token file.
        // Keychain is fully bypassed — no permission dialogs.
        do {
            let detected = try GiteaAutoConfig.detect()
            isAuthenticated = true
            baseURL         = detected.baseURL
            repoOwner       = detected.owner
            repoName        = detected.repo
            docsPath        = detected.docsPath
            rfcLabel        = detected.rfcLabel
            pat             = detected.pat
            debugLog("loaded from config — \(detected.owner)/\(detected.repo) @ \(detected.baseURL)")
            return
        } catch {
            debugLog("GiteaAutoConfig.detect() FAILED — \(error)")
        }
#endif
        // Release path (or debug fallback if config not found): use Keychain.
        let kc = KeychainHelper.shared
        isAuthenticated = kc.isConfigured
        baseURL         = kc.baseURL   ?? ""
        repoOwner       = kc.repoOwner ?? ""
        repoName        = kc.repoName  ?? ""
        docsPath        = kc.docsPath  ?? "docs-cms/rfcs"
        rfcLabel        = kc.rfcLabel  ?? "hermit:rfc-ready"
        pat             = kc.pat       ?? ""
    }

    /// Applies a detected config into memory (used by SetupView in release).
    func apply(_ config: GiteaAutoConfig.DetectedConfig) {
        isAuthenticated = true
        baseURL   = config.baseURL
        repoOwner = config.owner
        repoName  = config.repo
        docsPath  = config.docsPath
        rfcLabel  = config.rfcLabel
        pat       = config.pat
    }

    /// Refreshes published state from the Keychain (used by SetupView after saving).
    func applyKeychain() {
        isAuthenticated = keychain.isConfigured
        baseURL   = keychain.baseURL   ?? ""
        repoOwner = keychain.repoOwner ?? ""
        repoName  = keychain.repoName  ?? ""
        docsPath  = keychain.docsPath  ?? "docs-cms/rfcs"
        rfcLabel  = keychain.rfcLabel  ?? "hermit:rfc-ready"
        pat       = keychain.pat       ?? ""
    }

    /// Builds a GitHubAPIClient from the current in-memory config.
    func makeAPIClient() -> GitHubAPIClient? {
        guard isAuthenticated, !pat.isEmpty else { return nil }
        let config = GitHubAPIClient.Config(
            baseURL:  baseURL,
            owner:    repoOwner,
            repo:     repoName,
            docsPath: docsPath,
            rfcLabel: rfcLabel,
            pat:      pat
        )
        return GitHubAPIClient(config: config)
    }

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
