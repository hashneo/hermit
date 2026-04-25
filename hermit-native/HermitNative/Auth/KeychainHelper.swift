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
        case baseURL    = "hermit.base-url"
        case pat        = "hermit.pat"
        case repoOwner  = "hermit.repo-owner"
        case repoName   = "hermit.repo-name"
        case docsPath   = "hermit.docs-path"
        case rfcLabel   = "hermit.rfc-label"
        case openAIKey  = "hermit.openai-key"
        case aiProvider = "hermit.ai-provider"
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
