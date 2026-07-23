import Foundation
import CryptoKit

// MARK: - SharedConfigStore
// hermit-jxi: Loads shareable account/repository catalogs dropped into the
// user-facing config directory:
//
//     ~/Library/Application Support/Hermit/config/
//
// Team members running a binary build place a `hermit-repos*.json` file here to
// populate their account + repository list without a source checkout or any
// build-time embedding. Tokens are NOT stored here — each user adds their own
// PAT per account (Keychain), keyed by the account's stable derived UUID.
// See ADR-010.

enum SharedConfigStore {

    /// `~/Library/Application Support/Hermit/config/` — the user-facing config
    /// directory. Same Application Support root the embedded Go server uses for
    /// its data dir (`EmbeddedServerManager.appSupportDirectory()`).
    static var directory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first else {
            return nil
        }
        return base.appendingPathComponent("Hermit", isDirectory: true)
                   .appendingPathComponent("config", isDirectory: true)
    }

    // MARK: - Catalog model (matches config/hermit-repos.*.json schema)

    struct Catalog: Codable {
        struct Account: Codable {
            let id: String
            let name: String
            let endpoint: String
        }
        struct Repository: Codable {
            let account: String
            let owner: String
            let name: String
            let docsPath: String?
            let rfcLabel: String?
        }
        let accounts: [Account]
        let repositories: [Repository]
        let version: Int?
    }

    // MARK: - Apply

    /// Loads every `hermit-repos*.json` file in the config directory and upserts
    /// the accounts + repositories into the live stores.
    ///
    /// Idempotent: accounts are keyed by a stable UUID derived from their string
    /// `id`, so re-loading (or updating the file and relaunching) preserves any
    /// PAT the user already added. Safe to call on every launch; a no-op when
    /// the directory or no matching file is present.
    ///
    /// - Returns: The number of catalog files applied.
    @discardableResult
    @MainActor
    static func applyToStoresIfPresent() -> Int {
        guard let dir = directory,
              FileManager.default.fileExists(atPath: dir.path) else { return 0 }

        let urls: [URL]
        do {
            urls = try FileManager.default
                .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "json"
                       && $0.lastPathComponent.hasPrefix("hermit-repos") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            NSLog("[SharedConfigStore] could not list %@: %@", dir.path, error.localizedDescription)
            return 0
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var applied = 0
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let catalog = try? decoder.decode(Catalog.self, from: data) else {
                NSLog("[SharedConfigStore] failed to decode %@", url.lastPathComponent)
                continue
            }
            upsert(catalog: catalog, source: url)
            applied += 1
        }
        if applied > 0 {
            NSLog("[SharedConfigStore] applied %d catalog file(s) from %@", applied, dir.path)
        }
        return applied
    }

    @MainActor
    private static func upsert(catalog: Catalog, source: URL) {
        // 1. Accounts → one stable UUID per string id; tokens are preserved by
        //    AccountStore.upsertShared (matched on the same UUID).
        var idByAccount: [String: UUID] = [:]
        for acct in catalog.accounts {
            let uuid = Self.deterministicUUID(for: acct.id)
            idByAccount[acct.id] = uuid
            AccountStore.shared.upsertShared(id: uuid, name: acct.name, endpoint: acct.endpoint)
        }

        // 2. Repositories → matched by accountID + owner + name so UUIDs persist.
        for repo in catalog.repositories {
            guard let accountID = idByAccount[repo.account] else {
                NSLog("[SharedConfigStore] repo %@/%@ references unknown account '%@' — skipped",
                      repo.owner, repo.name, repo.account)
                continue
            }
            RepositoryStore.shared.upsertShared(
                accountID: accountID,
                owner:     repo.owner,
                name:      repo.name,
                docsPath:  repo.docsPath ?? "docs-cms/rfcs",
                rfcLabel:  repo.rfcLabel ?? "hermit:rfc-ready"
            )
        }
    }

    /// Derives a stable UUID from an arbitrary string (e.g. an account id like
    /// `"github-ibm"`) so the same catalog always maps to the same UUIDs.
    /// This keeps Keychain token keys stable across launches and catalog updates.
    /// Uses UUIDv3 (MD5) variant/version bits per RFC 4122.
    static func deterministicUUID(for string: String) -> UUID {
        var bytes = Array(Insecure.MD5.hash(data: Data(string.utf8)))
        bytes[6] = (bytes[6] & 0x0F) | 0x30   // version 3
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // variant 10
        return UUID(uuid: (bytes[0],  bytes[1],  bytes[2],  bytes[3],
                          bytes[4],  bytes[5],  bytes[6],  bytes[7],
                          bytes[8],  bytes[9],  bytes[10], bytes[11],
                          bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
