import Foundation
import Security

/// Securely stores and retrieves Hermit credentials from the system Keychain.
///
/// All config is packed into a single JSON blob stored under one Keychain item:
///   service = "HermitNative"
///   account = "hermit.config"
///
/// This means macOS prompts for the password exactly once (on first write),
/// rather than once per field.
///
/// Paired device tokens are stored separately under service "hermit.paired"
/// because they are keyed by peer name and managed independently.
final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    // MARK: - Storage model

    private let keychainService = "HermitNative"
    private let keychainAccount = "hermit.config"

    /// The JSON-serialisable struct that backs the single keychain item.
    private struct Config: Codable {
        var pat: String?
        var baseURL: String?
        var serverBaseURL: String?
        var repoOwner: String?
        var repoName: String?
        var docsPath: String?
        var rfcLabel: String?
        var openAIKey: String?
        var aiProvider: String?
        var serverMode: String?      // JSON-encoded ServerMode
        var localNetworkToken: String?
    }

    // In-memory cache so repeated property reads don't hit the keychain each time.
    private var _cache: Config? = nil

    private func load() -> Config {
        if let c = _cache { return c }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let config = try? JSONDecoder().decode(Config.self, from: data)
        else { return Config() }
        _cache = config
        return config
    }

    private func save(_ config: Config) {
        _cache = config
        guard let data = try? JSONEncoder().encode(config) else { return }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private func mutate(_ block: (inout Config) -> Void) {
        var c = load()
        block(&c)
        save(c)
    }

    // MARK: - Delete all

    func deleteAll() {
        _cache = nil
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: keychainService as CFString,
            kSecAttrAccount: keychainAccount as CFString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Public API (same surface as before)

    var pat: String? {
        get { load().pat }
        set { mutate { $0.pat = newValue } }
    }

    var baseURL: String? {
        get { load().baseURL }
        set { mutate { $0.baseURL = newValue } }
    }

    var serverBaseURL: String? {
        get { load().serverBaseURL }
        set { mutate { $0.serverBaseURL = newValue } }
    }

    var repoOwner: String? {
        get { load().repoOwner }
        set { mutate { $0.repoOwner = newValue } }
    }

    var repoName: String? {
        get { load().repoName }
        set { mutate { $0.repoName = newValue } }
    }

    var docsPath: String? {
        get { load().docsPath }
        set { mutate { $0.docsPath = newValue } }
    }

    var rfcLabel: String? {
        get { load().rfcLabel }
        set { mutate { $0.rfcLabel = newValue } }
    }

    var openAIKey: String? {
        get { load().openAIKey }
        set { mutate { $0.openAIKey = newValue } }
    }

    var aiProvider: String? {
        get { load().aiProvider }
        set { mutate { $0.aiProvider = newValue } }
    }

    var serverMode: ServerMode? {
        get {
            guard let raw = load().serverMode,
                  let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ServerMode.self, from: data)
        }
        set {
            mutate {
                if let mode = newValue,
                   let data = try? JSONEncoder().encode(mode),
                   let str  = String(data: data, encoding: .utf8) {
                    $0.serverMode = str
                } else {
                    $0.serverMode = nil
                }
            }
        }
    }

    var localNetworkToken: String? {
        get { load().localNetworkToken }
        set { mutate { $0.localNetworkToken = newValue } }
    }

    // MARK: - Convenience: is fully configured?

    var isConfigured: Bool {
        let c = load()
        return c.pat != nil && c.serverBaseURL != nil && c.repoOwner != nil && c.repoName != nil
    }

    // MARK: - Bulk write

    struct RepoConfig {
        let baseURL: String
        let pat: String
        let owner: String
        let repo: String
        let docsPath: String
        let rfcLabel: String
    }

    func apply(_ config: RepoConfig) {
        mutate {
            $0.baseURL      = config.baseURL
            $0.pat          = config.pat
            $0.repoOwner    = config.owner
            $0.repoName     = config.repo
            $0.docsPath     = config.docsPath
            $0.rfcLabel     = config.rfcLabel
        }
    }

    // MARK: - Paired device token store

    func loadPairedTokens() -> [String: String] {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      "hermit.paired" as CFString,
            kSecReturnAttributes: true,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return [:] }
        var map: [String: String] = [:]
        for item in items {
            if let account = item[kSecAttrAccount] as? String,
               let data    = item[kSecValueData]    as? Data,
               let token   = String(data: data, encoding: .utf8) {
                map[account] = token
            }
        }
        return map
    }

    func savePairedToken(peerName: String, token: String) {
        guard let data = token.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "hermit.paired" as CFString,
            kSecAttrAccount: peerName,
        ]
        let attrs: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func deletePairedToken(peerName: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "hermit.paired" as CFString,
            kSecAttrAccount: peerName,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
