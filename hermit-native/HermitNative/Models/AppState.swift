import Foundation
import Combine

/// Central application state shared across all views via @EnvironmentObject.
@MainActor
final class AppState: ObservableObject {
    @Published var isAuthenticated: Bool = false

    // Current repo config (mirrors Keychain, kept in memory for fast access)
    @Published var baseURL: String   = ""
    @Published var repoOwner: String = ""
    @Published var repoName: String  = ""
    @Published var docsPath: String  = "docs-cms/rfcs"
    @Published var rfcLabel: String  = "hermit:rfc-ready"

    private let keychain = KeychainHelper.shared

    init() {
        applyKeychain()
    }

    /// Refreshes published state from whatever is currently in the Keychain.
    /// Called after SetupView writes new credentials.
    func applyKeychain() {
        isAuthenticated = keychain.isConfigured
        baseURL   = keychain.baseURL   ?? ""
        repoOwner = keychain.repoOwner ?? ""
        repoName  = keychain.repoName  ?? ""
        docsPath  = keychain.docsPath  ?? "docs-cms/rfcs"
        rfcLabel  = keychain.rfcLabel  ?? "hermit:rfc-ready"
    }

    /// Builds a GitHubAPIClient from the current in-memory config.
    func makeAPIClient() -> GitHubAPIClient? {
        guard isAuthenticated else { return nil }
        let config = GitHubAPIClient.Config(
            baseURL:  baseURL,
            owner:    repoOwner,
            repo:     repoName,
            docsPath: docsPath,
            rfcLabel: rfcLabel
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
