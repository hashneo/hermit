import Foundation
import Security

/// Stores secrets in the system Keychain:
///   - PAT (GitHub / Gitea personal access token) — per account UUID
///   - OpenAI API key
///   - Per-peer pairing tokens (service "hermit.paired")
///
/// All items are scoped to the `keychain-access-groups` declared in the app
/// entitlements (`$(AppIdentifierPrefix)$(HERMIT_BUNDLE_ID)`, e.g.
/// `KCM5F3ZYT3.me.steven.hermit`).  Because the group is keyed to the Apple
/// Developer Team ID rather than the binary's code signature, items survive:
///   • Every `make dev` rebuild
///   • Debug → Release builds
///   • Certificate rotation / renewal
///   • Any app update
///
/// The access group is read from Info.plist at runtime (key: `KeychainAccessGroup`)
/// so no Team ID is hardcoded in source.
///
/// Non-secret config (URLs, repo owner/name, etc.) lives in UserDefaults via
/// ConfigStore so it remains readable without Keychain queries.
final class KeychainHelper {
    static let shared = KeychainHelper()

    /// The Keychain access group for all Hermit items.
    /// Set in Info.plist as `$(DEVELOPMENT_TEAM).$(PRODUCT_BUNDLE_IDENTIFIER)`.
    /// Falls back to an empty string on iOS simulator / unit tests where the
    /// Info.plist key may be absent — queries without a group still work there.
    static let accessGroup: String =
        Bundle.main.infoDictionary?["KeychainAccessGroup"] as? String ?? ""

    private init() {
        migrateToAccessGroup()
    }

    private let service       = "Hermit"
    private let pairedService = "hermit.paired"

    // MARK: - Generic low-level helpers

    private func readString(account: String) -> String? {
        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString,
            kSecReturnData:  true,
            kSecMatchLimit:  kSecMatchLimitOne,
        ]
        if !Self.accessGroup.isEmpty {
            query[kSecAttrAccessGroup] = Self.accessGroup as CFString
        }
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func writeString(_ value: String?, account: String) {
        var query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    service as CFString,
            kSecAttrAccount:    account as CFString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if !Self.accessGroup.isEmpty {
            query[kSecAttrAccessGroup] = Self.accessGroup as CFString
        }
        guard let value, let data = value.data(using: .utf8) else {
            SecItemDelete(query as CFDictionary)
            return
        }
        let attrs: [CFString: Any] = [
            kSecValueData:      data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    // MARK: - Migration: move old items (no access group) into the declared group

    /// On the first launch after the keychain-access-groups entitlement is added,
    /// existing items written by old builds have no explicit access group.  This
    /// migration reads them via a group-less query (which still matches items in
    /// the app's legacy sandbox partition), then re-writes them into the new
    /// named group so all future builds can read them regardless of code signature.
    ///
    /// Items that are unreadable (locked to an old per-binary ACL from a different
    /// binary) are silently skipped — the user re-enters them once, then they are
    /// permanently fixed on the next write.
    private func migrateToAccessGroup() {
        guard !Self.accessGroup.isEmpty else { return }
        migrateService(service)
        migrateService(pairedService)
    }

    private func migrateService(_ svc: String) {
        // Query WITHOUT access group to catch items in the legacy sandbox partition.
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      svc as CFString,
            kSecReturnAttributes: true,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitAll,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[CFString: Any]] else { return }

        for item in items {
            guard let account = item[kSecAttrAccount] as? String,
                  let data    = item[kSecValueData]   as? Data,
                  let value   = String(data: data, encoding: .utf8) else { continue }

            // Check whether the item is already in the correct access group.
            let existingGroup = item[kSecAttrAccessGroup] as? String ?? ""
            if existingGroup == Self.accessGroup { continue }

            // Delete the old item and re-create it in the named access group.
            let find: [CFString: Any] = [
                kSecClass:       kSecClassGenericPassword,
                kSecAttrService: svc as CFString,
                kSecAttrAccount: account as CFString,
            ]
            SecItemDelete(find as CFDictionary)

            if svc == pairedService {
                savePairedToken(peerName: account, token: value)
            } else {
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

    // MARK: - Local network token (iOS — survives app container wipes)

    /// The pairing token used by the iPad to authenticate with the Mac server.
    /// Stored in Keychain (not UserDefaults) so it persists across `make dev`
    /// installs which recreate the iOS app container and wipe UserDefaults.
    var localNetworkToken: String? {
        get { readString(account: "hermit.localNetworkToken") }
        set { writeString(newValue, account: "hermit.localNetworkToken") }
    }

    // MARK: - Paired device token store (macOS)

    func loadPairedTokens() -> [String: String] {
        var query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      pairedService as CFString,
            kSecReturnAttributes: true,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitAll,
        ]
        if !Self.accessGroup.isEmpty {
            query[kSecAttrAccessGroup] = Self.accessGroup as CFString
        }
        return keychainMap(for: query)
    }

    /// Queries WITHOUT access group restriction — used once during migration to
    /// find legacy paired tokens that were stored before the access group was added.
    func loadLegacyPairedTokens() -> [String: String] {
        let query: [CFString: Any] = [
            kSecClass:            kSecClassGenericPassword,
            kSecAttrService:      pairedService as CFString,
            kSecReturnAttributes: true,
            kSecReturnData:       true,
            kSecMatchLimit:       kSecMatchLimitAll,
        ]
        return keychainMap(for: query)
    }

    private func keychainMap(for query: [CFString: Any]) -> [String: String] {
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
        var query: [CFString: Any] = [
            kSecClass:          kSecClassGenericPassword,
            kSecAttrService:    pairedService as CFString,
            kSecAttrAccount:    peerName as CFString,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock,
        ]
        if !Self.accessGroup.isEmpty {
            query[kSecAttrAccessGroup] = Self.accessGroup as CFString
        }
        let attrs: [CFString: Any] = [kSecValueData: data]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecSuccess {
            return
        }
        var add = query
        add[kSecValueData] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    func deletePairedToken(peerName: String) {
        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: pairedService as CFString,
            kSecAttrAccount: peerName as CFString,
        ]
        if !Self.accessGroup.isEmpty {
            query[kSecAttrAccessGroup] = Self.accessGroup as CFString
        }
        SecItemDelete(query as CFDictionary)
    }

    func deleteAllPairedTokens() {
        var query: [CFString: Any] = [
            kSecClass:       kSecClassGenericPassword,
            kSecAttrService: pairedService as CFString,
        ]
        if !Self.accessGroup.isEmpty {
            query[kSecAttrAccessGroup] = Self.accessGroup as CFString
        }
        SecItemDelete(query as CFDictionary)
    }
}
