import Foundation
import Combine

// MARK: - Connection

/// A named server connection with its own endpoint and PAT.
struct Connection: Identifiable, Codable, Equatable {
    var id:       UUID   = UUID()
    var name:     String          // e.g. "HashiCorp Gitea"
    var endpoint: String          // e.g. "https://gitea.example.com"

    // token lives in Keychain — not in this struct
    var keychainKey: String { "hermit.account.\(id.uuidString)" }
}

// MARK: - Repository

/// A repository belonging to an account (connection).
struct Repository: Identifiable, Codable, Equatable {
    var id:        UUID   = UUID()
    var accountID: UUID           // foreign key → Connection.id
    var owner:     String         // e.g. "gitea_admin"
    var name:      String         // e.g. "hermit-rfcs"
    var docsPath:  String         // e.g. "docs-cms/rfcs"
    var rfcLabel:  String         // e.g. "hermit:rfc-ready"

    var fullName: String { "\(owner)/\(name)" }
}

// MARK: - AccountStore

/// Observable store for all named server connections.
///
/// - Non-secret fields (name, endpoint, id) persist in UserDefaults as JSON.
/// - Tokens persist in Keychain keyed by `hermit.account.<UUID>`.
/// - `activeID` tracks which connection is currently in use.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var connections: [Connection] = []
    @Published private(set) var activeID: UUID? = nil

    // Derived: the active connection, if any
    var active: Connection? { connections.first { $0.id == activeID } }

    private let defaults = UserDefaults.standard
    private let connectionsKey = "hermit.accounts"
    private let activeIDKey    = "hermit.accounts.activeID"

    private init() {
        // load() and migrateIfNeeded() only touch UserDefaults/Keychain — both
        // thread-safe — so it is safe to call them here before the main actor
        // is fully running. We assign directly to the stored properties rather
        // than going through @Published so there is no actor boundary to cross.
        let (loaded, activeID) = AccountStore.loadFromDefaults()
        var conns = loaded

        // Migrate legacy single-account config when no accounts exist yet.
        if conns.isEmpty {
            if let endpoint = UserDefaults.standard.string(forKey: "hermit.serverBaseURL"),
               !endpoint.isEmpty {
                let conn = Connection(name: "Default", endpoint: endpoint)
                // Migrate token from legacy hermit.pat key if present
                let legacyToken = KeychainHelper.shared.readAccountToken(key: "hermit.pat") ?? ""
                KeychainHelper.shared.writeAccountToken(legacyToken, key: conn.keychainKey)
                conns = [conn]
                AccountStore.saveToDefaults(connections: conns, activeID: conn.id)
            }
        }

        self.connections = conns
        self.activeID = activeID ?? conns.first?.id
    }

    // MARK: - Public API

    func add(name: String, endpoint: String, token: String) {
        let conn = Connection(name: name, endpoint: endpoint)
        KeychainHelper.shared.writeAccountToken(token, key: conn.keychainKey)
        connections.append(conn)
        if connections.count == 1 {
            activeID = conn.id
            // First account — restart so the server picks it up.
            restartEmbeddedServer()
        }
        save()
    }

    func update(_ connection: Connection, token: String? = nil) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx] = connection
        if let token { KeychainHelper.shared.writeAccountToken(token, key: connection.keychainKey) }
        save()
        // Restart if the updated connection is the active one.
        if activeID == connection.id {
            restartEmbeddedServer()
        }
    }

    func remove(_ connection: Connection) {
        KeychainHelper.shared.deleteAccountToken(key: connection.keychainKey)
        connections.removeAll { $0.id == connection.id }
        if activeID == connection.id {
            activeID = connections.first?.id
            // Active account removed — server must restart with new active (or no) account.
            restartEmbeddedServer()
        }
        save()
    }

    func setActive(_ connection: Connection) {
        activeID = connection.id
        UserDefaults.standard.set(connection.id.uuidString, forKey: activeIDKey)
        restartEmbeddedServer()
    }

    func token(for connection: Connection) -> String? {
        KeychainHelper.shared.readAccountToken(key: connection.keychainKey)
    }

    // MARK: - Connectivity probe

    /// Returns true if a recent health-check for this connection succeeded.
    /// Stored in memory — refreshed by `probe(_:)`.
    func isConnected(_ connection: Connection) -> Bool {
        connectedIDs.contains(connection.id)
    }

    func probe(_ connection: Connection) async {
        let base = connection.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // Pick the right health endpoint based on the server type:
        //   GitHub → GET /user  (returns 200 with valid token, 401 without)
        //   Gitea/Hermit → GET /api/v1/health
        let isGitHub = base.contains("github.com")
        let healthPath = isGitHub ? "/user" : "/api/v1/health"
        guard let url = URL(string: "\(base)\(healthPath)") else { return }

        var req = URLRequest(url: url, timeoutInterval: 8)
        if let token = token(for: connection) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            // GitHub /user returns 401 with no/bad token — treat that as reachable but
            // still mark disconnected so the user knows the token is wrong.
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            if ok { connectedIDs.insert(connection.id) } else { connectedIDs.remove(connection.id) }
        } catch {
            connectedIDs.remove(connection.id)
        }
        objectWillChange.send()
    }

    // MARK: - Private

    private var connectedIDs: Set<UUID> = []

    private func save() {
        AccountStore.saveToDefaults(connections: connections, activeID: activeID)
    }

    private static func loadFromDefaults() -> ([Connection], UUID?) {
        let defaults = UserDefaults.standard
        let rawString = defaults.string(forKey: "hermit.accounts")
        let rawData   = defaults.data(forKey: "hermit.accounts")
        NSLog("[AccountStore] hermit.accounts string=%@ data=%db",
              rawString ?? "nil", rawData?.count ?? -1)
        var conns: [Connection] = []
        if let data = rawData ?? rawString?.data(using: .utf8) {
            do {
                conns = try JSONDecoder().decode([Connection].self, from: data)
                NSLog("[AccountStore] decoded %d connection(s): %@",
                      conns.count, conns.map(\.name).joined(separator: ", "))
            } catch {
                NSLog("[AccountStore] decode error: %@", error.localizedDescription)
            }
        } else {
            NSLog("[AccountStore] no data found for hermit.accounts")
        }
        var activeID: UUID? = nil
        if let raw = defaults.string(forKey: "hermit.accounts.activeID"),
           let uuid = UUID(uuidString: raw) {
            activeID = uuid
        }
        return (conns, activeID)
    }

    private static func saveToDefaults(connections: [Connection], activeID: UUID?) {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: "hermit.accounts")
        }
        if let id = activeID {
            defaults.set(id.uuidString, forKey: "hermit.accounts.activeID")
        }
    }
}

// MARK: - RepositoryStore

/// Observable store for all saved repositories, grouped by account.
///
/// - Persists in UserDefaults as JSON under `hermit.repositories`.
/// - `activeID` is the repository currently loaded in the main RFC view.
@MainActor
final class RepositoryStore: ObservableObject {
    static let shared = RepositoryStore()

    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var activeID: UUID? = nil

    var active: Repository? { repositories.first { $0.id == activeID } }

    func repos(for account: Connection) -> [Repository] {
        repositories.filter { $0.accountID == account.id }
    }

    func add(accountID: UUID, owner: String, name: String,
             docsPath: String = "docs-cms/rfcs", rfcLabel: String = "hermit:rfc-ready") {
        let repo = Repository(accountID: accountID, owner: owner, name: name,
                              docsPath: docsPath, rfcLabel: rfcLabel)
        repositories.append(repo)
        if repositories.count == 1 {
            activeID = repo.id
            // First repo — restart so the server picks it up.
            restartEmbeddedServer()
        }
        save()
    }

    func update(_ repo: Repository) {
        guard let idx = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[idx] = repo
        save()
        // Restart if the updated repo is the active one.
        if activeID == repo.id {
            restartEmbeddedServer()
        }
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0.id == repo.id }
        if activeID == repo.id {
            activeID = repositories.first?.id
            // Active repo removed — server must restart with new active (or no) repo.
            restartEmbeddedServer()
        }
        save()
    }

    func setActive(_ repo: Repository) {
        activeID = repo.id
        UserDefaults.standard.set(repo.id.uuidString, forKey: "hermit.repositories.activeID")
        restartEmbeddedServer()
    }

    // MARK: - Private

    private init() {
        let defaults = UserDefaults.standard

        // Load repositories — support both Data and String storage (bootstrap script writes -string)
        if let data = defaults.data(forKey: "hermit.repositories") ??
                      defaults.string(forKey: "hermit.repositories")?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Repository].self, from: data) {
            repositories = decoded
        }

        if let raw = defaults.string(forKey: "hermit.repositories.activeID"),
           let uuid = UUID(uuidString: raw) {
            activeID = uuid
        } else {
            activeID = repositories.first?.id
        }

        // Migrate legacy single-repo config when no repos exist yet
        if repositories.isEmpty {
            let ud = UserDefaults.standard
            let owner = ud.string(forKey: "hermit.repoOwner") ?? ""
            let name  = ud.string(forKey: "hermit.repoName")  ?? ""
            // accountID: try to match the fixed dev UUID seeded by the script
            let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
            if !owner.isEmpty, !name.isEmpty {
                let docs  = ud.string(forKey: "hermit.docsPath")  ?? "docs-cms/rfcs"
                let label = ud.string(forKey: "hermit.rfcLabel")  ?? "hermit:rfc-ready"
                let repo  = Repository(accountID: accountID, owner: owner, name: name,
                                       docsPath: docs, rfcLabel: label)
                repositories = [repo]
                activeID     = repo.id
                save()
            }
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        if let data = try? JSONEncoder().encode(repositories) {
            defaults.set(data, forKey: "hermit.repositories")
        }
        if let id = activeID {
            defaults.set(id.uuidString, forKey: "hermit.repositories.activeID")
        }
    }
}

// MARK: - Embedded server restart helper

/// Restarts the embedded Go server so it picks up the latest active account/repo.
/// No-op on iOS where EmbeddedServerManager does not exist.
@MainActor
private func restartEmbeddedServer() {
#if os(macOS)
    EmbeddedServerManager.shared.restart()
#endif
}
