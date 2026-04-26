import Foundation

/// Persists non-secret application config in UserDefaults.
///
/// UserDefaults are keyed by bundle ID and survive app rebuilds, so values
/// entered during setup (server URL, owner, repo, etc.) are not lost on every
/// Xcode build. Only the PAT lives in Keychain (KeychainHelper).
final class ConfigStore {
    static let shared = ConfigStore()
    private init() {}

    private let defaults = UserDefaults.standard

    // MARK: - Keys

    private enum Key: String {
        case baseURL           = "hermit.baseURL"
        case serverBaseURL     = "hermit.serverBaseURL"
        case repoOwner         = "hermit.repoOwner"
        case repoName          = "hermit.repoName"
        case docsPath          = "hermit.docsPath"
        case rfcLabel          = "hermit.rfcLabel"
        case aiProvider        = "hermit.aiProvider"
        case serverMode        = "hermit.serverMode"   // JSON-encoded ServerMode
        case localNetworkToken = "hermit.localNetworkToken"
    }

    // MARK: - Properties

    var baseURL: String? {
        get { defaults.string(forKey: Key.baseURL.rawValue) }
        set { defaults.set(newValue, forKey: Key.baseURL.rawValue) }
    }

    var serverBaseURL: String? {
        get { defaults.string(forKey: Key.serverBaseURL.rawValue) }
        set { defaults.set(newValue, forKey: Key.serverBaseURL.rawValue) }
    }

    var repoOwner: String? {
        get { defaults.string(forKey: Key.repoOwner.rawValue) }
        set { defaults.set(newValue, forKey: Key.repoOwner.rawValue) }
    }

    var repoName: String? {
        get { defaults.string(forKey: Key.repoName.rawValue) }
        set { defaults.set(newValue, forKey: Key.repoName.rawValue) }
    }

    var docsPath: String? {
        get { defaults.string(forKey: Key.docsPath.rawValue) }
        set { defaults.set(newValue, forKey: Key.docsPath.rawValue) }
    }

    var rfcLabel: String? {
        get { defaults.string(forKey: Key.rfcLabel.rawValue) }
        set { defaults.set(newValue, forKey: Key.rfcLabel.rawValue) }
    }

    var aiProvider: String? {
        get { defaults.string(forKey: Key.aiProvider.rawValue) }
        set { defaults.set(newValue, forKey: Key.aiProvider.rawValue) }
    }

    /// localNetworkToken is not a secret in the Keychain sense — it is a
    /// short-lived session bearer issued by the paired Mac and rotates on
    /// every pairing. Store it in UserDefaults so it doesn't trigger
    /// Keychain prompts; the Mac will re-pair if it expires.
    var localNetworkToken: String? {
        get { defaults.string(forKey: Key.localNetworkToken.rawValue) }
        set { defaults.set(newValue, forKey: Key.localNetworkToken.rawValue) }
    }

    var serverMode: ServerMode? {
        get {
            guard let raw = defaults.string(forKey: Key.serverMode.rawValue),
                  let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ServerMode.self, from: data)
        }
        set {
            if let mode = newValue,
               let data = try? JSONEncoder().encode(mode),
               let str  = String(data: data, encoding: .utf8) {
                defaults.set(str, forKey: Key.serverMode.rawValue)
            } else {
                defaults.removeObject(forKey: Key.serverMode.rawValue)
            }
        }
    }

    // MARK: - Convenience

    /// True when the minimum fields needed to connect are present.
    /// PAT readiness is checked separately via KeychainHelper.shared.hasPAT.
    var isConfigured: Bool {
        serverBaseURL != nil && repoOwner != nil && repoName != nil
    }

    // MARK: - Bulk write (used by SetupView / install-keychain-pat.sh bootstrap)

    struct RepoConfig {
        let baseURL: String
        let owner: String
        let repo: String
        let docsPath: String
        let rfcLabel: String
    }

    func apply(_ config: RepoConfig) {
        baseURL   = config.baseURL
        repoOwner = config.owner
        repoName  = config.repo
        docsPath  = config.docsPath
        rfcLabel  = config.rfcLabel
    }

    // MARK: - Reset (wipe all non-secret config)

    func deleteAll() {
        for key in [Key.baseURL, .serverBaseURL, .repoOwner, .repoName,
                    .docsPath, .rfcLabel, .aiProvider, .serverMode, .localNetworkToken] {
            defaults.removeObject(forKey: key.rawValue)
        }
    }
}
