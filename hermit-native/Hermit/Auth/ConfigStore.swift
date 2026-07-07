import Foundation

// MARK: - MenuBarStyle

/// Controls how Hermit presents itself in the macOS menu bar.
enum MenuBarStyle: String {
    /// Native macOS dropdown menu with per-repo RFC submenus (default).
    case nativeMenu = "native"
    /// Popup dashboard panel with full review workflow UI.
    case popup = "popup"
}

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
        case cacheReadTTLSeconds = "hermit.cache.readTTLSeconds"
        case cacheJitterSeconds  = "hermit.cache.jitterSeconds"
        case menuBarStyle        = "hermit.menuBarStyle"
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

    /// The pairing token used by the iPad to authenticate with the Mac's server.
    ///
    /// On iOS the token is stored in the Keychain (via KeychainHelper) so it
    /// survives `make dev` installs that recreate the app container and wipe
    /// UserDefaults.  A UserDefaults shadow copy is kept for fast synchronous
    /// reads (e.g. PairingBrowser.isPaired init) and is refreshed on every write.
    ///
    /// On macOS this key is unused — the Mac never sends its own token.
    var localNetworkToken: String? {
        get {
#if os(iOS)
            // Keychain is authoritative; fall back to legacy UserDefaults value
            // so existing installs don't lose their token on the first upgrade.
            if let kc = KeychainHelper.shared.localNetworkToken, !kc.isEmpty { return kc }
            let ud = defaults.string(forKey: Key.localNetworkToken.rawValue)
            if let ud, !ud.isEmpty {
                // Migrate: write to Keychain and clear UserDefaults copy.
                KeychainHelper.shared.localNetworkToken = ud
                defaults.removeObject(forKey: Key.localNetworkToken.rawValue)
                return ud
            }
            return nil
#else
            return defaults.string(forKey: Key.localNetworkToken.rawValue)
#endif
        }
        set {
#if os(iOS)
            KeychainHelper.shared.localNetworkToken = newValue
            // Keep UserDefaults in sync for synchronous init-time reads.
            defaults.set(newValue, forKey: Key.localNetworkToken.rawValue)
#else
            defaults.set(newValue, forKey: Key.localNetworkToken.rawValue)
#endif
        }
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

    var cacheReadTTLSeconds: Int {
        get {
            let value = defaults.integer(forKey: Key.cacheReadTTLSeconds.rawValue)
            return value > 0 ? value : 180
        }
        set { defaults.set(max(1, newValue), forKey: Key.cacheReadTTLSeconds.rawValue) }
    }

    var cacheJitterSeconds: Int {
        get {
            if defaults.object(forKey: Key.cacheJitterSeconds.rawValue) == nil { return 60 }
            return max(0, defaults.integer(forKey: Key.cacheJitterSeconds.rawValue))
        }
        set { defaults.set(max(0, newValue), forKey: Key.cacheJitterSeconds.rawValue) }
    }

    var menuBarStyle: MenuBarStyle {
        get {
            MenuBarStyle(rawValue: defaults.string(forKey: Key.menuBarStyle.rawValue) ?? "")
                ?? .nativeMenu
        }
        set { defaults.set(newValue.rawValue, forKey: Key.menuBarStyle.rawValue) }
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
                    .docsPath, .rfcLabel, .aiProvider, .serverMode, .localNetworkToken,
                    .cacheReadTTLSeconds, .cacheJitterSeconds, .menuBarStyle] {
            defaults.removeObject(forKey: key.rawValue)
        }
        // Paired device tokens are stored in UserDefaults (not Keychain).
        defaults.removeObject(forKey: "hermit.pairedDevices")
#if os(iOS)
        // Clear Keychain copy of the pairing token so reset is complete.
        KeychainHelper.shared.localNetworkToken = nil
#endif
    }
}
