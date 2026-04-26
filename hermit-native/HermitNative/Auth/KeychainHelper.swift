import Foundation
import Security

/// Stores only secrets in the system Keychain:
///   - PAT (Gitea personal access token)
///   - OpenAI API key
///   - Per-peer pairing tokens (service "hermit.paired")
///
/// All non-secret config (URLs, owner, repo, etc.) lives in UserDefaults
/// via ConfigStore so it survives rebuilds without Keychain prompts.
final class KeychainHelper {
    static let shared = KeychainHelper()
    private init() {}

    private let service = "HermitNative"

    // MARK: - Generic low-level helpers

    private func readString(account: String) -> String? {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeString(_ value: String?, account: String) {
        let query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString,
        ]
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attrs: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Secrets

    var pat: String? {
        get { readString(account: "hermit.pat") }
        set { writeString(newValue, account: "hermit.pat") }
    }

    var openAIKey: String? {
        get { readString(account: "hermit.openai-key") }
        set { writeString(newValue, account: "hermit.openai-key") }
    }

    // MARK: - Convenience: is a PAT stored?

    var hasPAT: Bool { pat != nil && !(pat!.isEmpty) }

    // MARK: - Delete all secrets (for sign-out / reset)

    func deleteAll() {
        writeString(nil, account: "hermit.pat")
        writeString(nil, account: "hermit.openai-key")
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
               let data    = item[kSecValueData]   as? Data,
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
