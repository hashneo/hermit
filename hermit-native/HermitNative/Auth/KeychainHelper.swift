import Foundation
import Security

/// Securely stores and retrieves credentials from the system Keychain.
///
/// Keys stored:
/// - GitHub PAT (`hermit.pat`)
/// - OpenAI API key (`hermit.openai-key`)
/// - AI provider preference (`hermit.ai-provider`)
final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    // MARK: - Service identifiers

    private enum Key: String {
        case pat           = "hermit.pat"
        case openAIKey     = "hermit.openai-key"
        case aiProvider    = "hermit.ai-provider"
    }

    // MARK: - Public API

    var pat: String? {
        get { read(key: .pat) }
        set {
            if let value = newValue { save(value, key: .pat) }
            else { delete(key: .pat) }
        }
    }

    var openAIKey: String? {
        get { read(key: .openAIKey) }
        set {
            if let value = newValue { save(value, key: .openAIKey) }
            else { delete(key: .openAIKey) }
        }
    }

    var aiProvider: String? {
        get { read(key: .aiProvider) }
        set {
            if let value = newValue { save(value, key: .aiProvider) }
            else { delete(key: .aiProvider) }
        }
    }

    // MARK: - Private helpers

    private func save(_ value: String, key: Key) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key.rawValue,
            kSecValueData:   data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func read(key: Key) -> String? {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrAccount:      key.rawValue,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    @discardableResult
    private func delete(key: Key) -> Bool {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrAccount: key.rawValue,
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }
}
