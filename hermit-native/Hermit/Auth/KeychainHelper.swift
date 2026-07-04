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
    private init() {
        migrateAccessibility()
    }

    private let service = "Hermit"

    // MARK: - Generic low-level helpers

    private func readString(account: String) -> String? {
        // NOTE: kSecAttrAccessible must NOT be included in read queries — it
        // filters by accessibility class and silently misses items written
        // with a different value.
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
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service as CFString,
            kSecAttrAccount:    account as CFString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attrs: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            // Create the item with an open ACL (nil trusted-app list) so that
            // any rebuild of the app binary — with a new ad-hoc code signature
            // — can read it without triggering the login-keychain password
            // prompt.  A nil trusted list means "any application may access
            // this item"; the item is still confined to the login keychain and
            // only accessible after first unlock.
            var add = query
            add[kSecValueData] = data
#if os(macOS) && DEBUG
            // In DEBUG builds the app is ad-hoc signed ("Sign to Run Locally"),
            // which changes the binary signature on every rebuild.  An open ACL
            // (nil trusted-app list) prevents the login-keychain password prompt
            // that would otherwise appear when the new binary tries to read an
            // item created by the old one.
            //
            // Release builds use a stable Developer ID signature, so the default
            // per-app ACL is correct and secure — no override needed.
            var secAccess: SecAccess?
            if SecAccessCreate(service as CFString, nil as CFArray?, &secAccess) == errSecSuccess,
               let access = secAccess {
                add[kSecAttrAccess] = access
            }
#endif
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Accessibility migration

    /// Re-writes all Hermit Keychain items to kSecAttrAccessibleAfterFirstUnlock.
    /// Items written by older builds used the default (kSecAttrAccessibleWhenUnlocked)
    /// which triggers an unlock prompt when the Settings pane reads them.
    private func migrateAccessibility() {
        let query: [CFString: Any] = [
            kSecClass:             kSecClassGenericPassword,
            kSecAttrService:       service as CFString,
            kSecReturnAttributes:  true,
            kSecReturnData:        true,
            kSecMatchLimit:        kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount] as? String,
                  let data    = item[kSecValueData]   as? Data else { continue }
            // Delete the old item (which has a per-binary ACL) and re-create
            // it with writeString, which sets a nil-trusted-list ACL.
            let find: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: service as CFString,
                kSecAttrAccount: account as CFString,
            ]
            SecItemDelete(find as CFDictionary)
            if let value = String(data: data, encoding: .utf8) {
                writeString(value, account: account)
            }
        }
    }

    // MARK: - Secrets

    var openAIKey: String? {
        get { readString(account: "hermit.openai-key") }
        set { writeString(newValue, account: "hermit.openai-key") }
    }

    // MARK: - Delete non-account secrets (for sign-out / reset)

    func deleteAll() {
        writeString(nil, account: "hermit.openai-key")
    }

    // MARK: - Per-account token store (AccountStore)

    func readAccountToken(key: String) -> String? {
        readString(account: key)
    }

    func writeAccountToken(_ token: String, key: String) {
        writeString(token.isEmpty ? nil : token, account: key)
    }

    func deleteAccountToken(key: String) {
        writeString(nil, account: key)
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
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    "hermit.paired" as CFString,
            kSecAttrAccount:    peerName as CFString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
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
            kSecAttrAccount: peerName as CFString,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
