import Foundation
import Security

// Exercises the production helper against an in-memory Keychain substitute.
// No system Keychain access or saved credentials are used by these tests.
private final class FakeKeychain {
    var values: [String: Data] = [:]
    var reads = 0
    var readStatus: OSStatus = errSecSuccess
    var writeStatus: OSStatus = errSecSuccess

    func account(_ query: CFDictionary) -> String {
        (query as NSDictionary)[kSecAttrAccount] as! String
    }

    var operations: KeychainHelper.Operations {
        KeychainHelper.Operations(
            read: { query in
                self.reads += 1
                guard self.readStatus == errSecSuccess else { return (self.readStatus, nil) }
                guard let data = self.values[self.account(query)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data as NSData)
            },
            update: { query, attributes in
                guard self.writeStatus == errSecSuccess else { return self.writeStatus }
                let account = self.account(query)
                guard self.values[account] != nil else { return errSecItemNotFound }
                self.values[account] = (attributes as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            },
            add: { query in
                guard self.writeStatus == errSecSuccess else { return self.writeStatus }
                self.values[self.account(query)] = (query as NSDictionary)[kSecValueData] as? Data
                return errSecSuccess
            },
            delete: { query in
                guard self.writeStatus == errSecSuccess else { return self.writeStatus }
                self.values.removeValue(forKey: self.account(query))
                return errSecSuccess
            }
        )
    }
}

@main
struct KeychainTests {
    static func main() {
        let backing = FakeKeychain()
        backing.values["account-a"] = Data("first".utf8)
        backing.values["account-b"] = Data("second".utf8)
        let helper = KeychainHelper(operations: backing.operations)

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            precondition(helper.readAccountToken(key: "account-a") == "first")
        }
        precondition(backing.reads == 1, "Concurrent callers must share one successful Keychain read")
        precondition(helper.readAccountToken(key: "account-b") == "second", "Accounts must stay isolated")
        precondition(backing.reads == 2)

        helper.writeAccountToken("replacement", key: "account-a")
        precondition(helper.readAccountToken(key: "account-a") == "replacement")
        precondition(backing.reads == 2, "Successful updates should refresh the cache")
        helper.writeAccountToken("new", key: "new-account")
        precondition(helper.readAccountToken(key: "new-account") == "new")
        precondition(backing.reads == 2, "Successful inserts should populate the cache")

        helper.deleteAccountToken(key: "account-a")
        precondition(helper.readAccountToken(key: "account-a") == nil, "Deletion must invalidate cached credentials")
        backing.values["account-a"] = Data("restored".utf8)
        backing.readStatus = errSecUserCanceled
        precondition(helper.readAccountToken(key: "account-a") == nil)
        backing.readStatus = errSecSuccess
        precondition(helper.readAccountToken(key: "account-a") == "restored", "Canceled reads must remain retryable")

        backing.writeStatus = errSecAuthFailed
        let beforeFailedUpdate = backing.reads
        helper.writeAccountToken("unsaved", key: "account-a")
        precondition(helper.readAccountToken(key: "account-a") == "restored")
        precondition(backing.reads == beforeFailedUpdate + 1, "A failed update must invalidate, not cache an unsaved value")
        helper.deleteAccountToken(key: "account-a")
        backing.readStatus = errSecAuthFailed
        precondition(helper.readAccountToken(key: "account-a") == nil, "A failed delete must not leave a cached credential")
        helper.writeAccountToken("unsaved", key: "missing-account")
        precondition(helper.readAccountToken(key: "missing-account") == nil)

        backing.writeStatus = errSecSuccess
        backing.readStatus = errSecSuccess
        helper.tlsPrivateKey = "test-key"
        helper.openAIKey = "test-api-key"
        helper.localNetworkToken = "test-pairing-token"
        let beforeSecrets = backing.reads
        precondition(helper.tlsPrivateKey == "test-key")
        precondition(helper.openAIKey == "test-api-key")
        precondition(helper.localNetworkToken == "test-pairing-token")
        precondition(backing.reads == beforeSecrets)
        helper.deleteAll()
        precondition(helper.openAIKey == nil, "Reset must invalidate the AI credential")

        let newSession = KeychainHelper(operations: backing.operations)
        let beforeNewSession = backing.reads
        precondition(newSession.readAccountToken(key: "account-b") == "second")
        precondition(backing.reads == beforeNewSession + 1, "The cache must be scoped to a helper session")
        print("Keychain session cache regressions passed")
    }
}
