import Foundation
import Security

/// Securely stores and retrieves credentials from the system Keychain.
///
/// Keys stored:
/// - API base URL        (`hermit.base-url`)      e.g. http://localhost:3000/api/v1
/// - PAT                 (`hermit.pat`)
/// - Repo owner          (`hermit.repo-owner`)    e.g. gitea_admin
/// - Repo name           (`hermit.repo-name`)     e.g. hermit-rfcs
/// - Docs path           (`hermit.docs-path`)     e.g. docs-cms/rfcs
/// - RFC label           (`hermit.rfc-label`)     e.g. hermit:rfc-ready
/// - OpenAI API key      (`hermit.openai-key`)
/// - AI provider pref    (`hermit.ai-provider`)
final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    // MARK: - Service identifiers

    private enum Key: String {
        case baseURL          = "hermit.base-url"
        case pat              = "hermit.pat"
        case repoOwner        = "hermit.repo-owner"
        case repoName         = "hermit.repo-name"
        case docsPath         = "hermit.docs-path"
        case rfcLabel         = "hermit.rfc-label"
        case openAIKey        = "hermit.openai-key"
        case aiProvider       = "hermit.ai-provider"
        case serverMode       = "hermit.server-mode"
        case serverBaseURL    = "hermit.server-base-url"
        case localNetworkToken = "hermit.local-token"
        // Paired device tokens are stored with key "hermit.paired.<displayName>"
        // handled by loadPairedTokens/savePairedToken/deletePairedToken helpers.
    }

    // MARK: - Public API

    var baseURL: String? {
        get { read(key: .baseURL) }
        set { write(newValue, key: .baseURL) }
    }

    var pat: String? {
        get { read(key: .pat) }
        set { write(newValue, key: .pat) }
    }

    var repoOwner: String? {
        get { read(key: .repoOwner) }
        set { write(newValue, key: .repoOwner) }
    }

    var repoName: String? {
        get { read(key: .repoName) }
        set { write(newValue, key: .repoName) }
    }

    var docsPath: String? {
        get { read(key: .docsPath) }
        set { write(newValue, key: .docsPath) }
    }

    var rfcLabel: String? {
        get { read(key: .rfcLabel) }
        set { write(newValue, key: .rfcLabel) }
    }

    var openAIKey: String? {
        get { read(key: .openAIKey) }
        set { write(newValue, key: .openAIKey) }
    }

    var aiProvider: String? {
        get { read(key: .aiProvider) }
        set { write(newValue, key: .aiProvider) }
    }

    /// Persists the active ServerMode as JSON.
    var serverMode: ServerMode? {
        get {
            guard let raw = read(key: .serverMode),
                  let data = raw.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(ServerMode.self, from: data)
        }
        set {
            if let mode = newValue,
               let data = try? JSONEncoder().encode(mode),
               let str  = String(data: data, encoding: .utf8) {
                write(str, key: .serverMode)
            } else {
                write(nil, key: .serverMode)
            }
        }
    }

    var serverBaseURL: String? {
        get { read(key: .serverBaseURL) }
        set { write(newValue, key: .serverBaseURL) }
    }

    var localNetworkToken: String? {
        get { read(key: .localNetworkToken) }
        set { write(newValue, key: .localNetworkToken) }
    }

    // MARK: - Paired device token store (macOS — hermit-1ow)

    /// Returns all (peerName → token) pairs persisted in the Keychain.
    func loadPairedTokens() -> [String: String] {
#if DEBUG
        return [:]
#else
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
#endif
    }

    func savePairedToken(peerName: String, token: String) {
#if !DEBUG
        guard let data = token.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:        kSecClassGenericPassword,
            kSecAttrService:  "hermit.paired" as CFString,
            kSecAttrAccount:  peerName,
            kSecValueData:    data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
#endif
    }

    func deletePairedToken(peerName: String) {
#if !DEBUG
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: "hermit.paired" as CFString,
            kSecAttrAccount: peerName,
        ]
        SecItemDelete(query as CFDictionary)
#endif
    }

    // MARK: - Convenience: is fully configured?

    var isConfigured: Bool {
#if DEBUG
        return false   // Debug: always use config-file path, never Keychain
#else
        return pat != nil && baseURL != nil && repoOwner != nil && repoName != nil
#endif
    }

    // MARK: - Bulk write (used by auto-config)

    struct RepoConfig {
        let baseURL: String
        let pat: String
        let owner: String
        let repo: String
        let docsPath: String
        let rfcLabel: String
    }

    func apply(_ config: RepoConfig) {
        baseURL   = config.baseURL
        pat       = config.pat
        repoOwner = config.owner
        repoName  = config.repo
        docsPath  = config.docsPath
        rfcLabel  = config.rfcLabel
    }

    // MARK: - Private helpers

    private func write(_ value: String?, key: Key) {
#if !DEBUG
        if let value { save(value, key: key) } else { delete(key: key) }
#endif
    }

    private func save(_ value: String, key: Key) {
#if !DEBUG
        guard let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key.rawValue,
            kSecValueData:   data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
#endif
    }

    private func read(key: Key) -> String? {
#if DEBUG
        return nil   // Debug: never read from Keychain
#else
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key.rawValue,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
#endif
    }

    @discardableResult
    private func delete(key: Key) -> Bool {
#if DEBUG
        return true   // Debug: no-op
#else
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key.rawValue,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
#endif
    }
}
