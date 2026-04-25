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
    @Published var repoOwner: String
    @Published var repoName: String
    @Published var docsPath: String
    @Published var rfcLabel: String
    @Published var pat: String

    // hermit-u1k / RFC-013: server connectivity
    @Published var serverMode: ServerMode = .embeddedLocal
    /// The resolved base URL of the active Hermit server (set by EmbeddedServerManager
    /// or chosen from discovered/remote servers).
    @Published var serverBaseURL: String = ""

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
            serverMode      = .embeddedLocal
            serverBaseURL   = detected.baseURL
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
        serverMode      = kc.serverMode ?? .embeddedLocal
        serverBaseURL   = kc.serverBaseURL ?? ""
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
        serverMode    = keychain.serverMode    ?? .embeddedLocal
        serverBaseURL = keychain.serverBaseURL ?? ""
    }

    // MARK: - API client factory

    /// Returns a HermitAPIClient aimed at the configured server URL, or nil
    /// if authentication or a server URL is not yet set.
    ///
    /// All GitHub interactions flow through the Go backend — there is no
    /// direct GitHub API fallback in the native client.
    func makeAPIClient() -> (any HermitClientProtocol)? {
        guard isAuthenticated, !pat.isEmpty, !serverBaseURL.isEmpty else { return nil }

        let cfg = HermitAPIClient.Config(
            baseURL:  serverBaseURL,
            owner:    repoOwner,
            repo:     repoName,
            docsPath: docsPath,
            rfcLabel: rfcLabel,
            pat:      pat
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
