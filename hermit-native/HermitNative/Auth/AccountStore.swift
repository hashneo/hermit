import Foundation
import Combine

// MARK: - Connection

/// A named server connection with its own endpoint and PAT.
///
/// In DEBUG builds the PAT is stored directly on this struct so it persists
/// in UserDefaults alongside the other connection fields — no Keychain prompts
/// during development. In Release builds `token` is excluded from Codable and
/// the PAT lives exclusively in the Keychain.
struct Connection: Identifiable, Equatable {
    var id:       UUID   = UUID()
    var name:     String          // e.g. "HashiCorp Gitea"
    var endpoint: String          // e.g. "https://gitea.example.com"
#if DEBUG
    var token:    String? = nil   // stored in UserDefaults in debug builds only
#endif

    var keychainKey: String { "hermit.account.\(id.uuidString)" }
}

// MARK: Connection + Codable

extension Connection: Codable {
    enum CodingKeys: String, CodingKey {
        case id, name, endpoint
#if DEBUG
        case token
#endif
    }

    init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        id       = try c.decode(UUID.self,   forKey: .id)
        name     = try c.decode(String.self, forKey: .name)
        endpoint = try c.decode(String.self, forKey: .endpoint)
#if DEBUG
        token    = try c.decodeIfPresent(String.self, forKey: .token)
#endif
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id,       forKey: .id)
        try c.encode(name,     forKey: .name)
        try c.encode(endpoint, forKey: .endpoint)
#if DEBUG
        try c.encodeIfPresent(token, forKey: .token)
#endif
    }
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
/// All accounts are always active — there is no single "active" account.
/// - Non-secret fields (name, endpoint, id) persist in UserDefaults as JSON.
/// - Tokens persist in Keychain keyed by `hermit.account.<UUID>`.
@MainActor
final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published private(set) var connections: [Connection] = []

    private let defaults       = UserDefaults.standard
    private let connectionsKey = "hermit.accounts"

    private init() {
        let loaded = AccountStore.loadFromDefaults()
        var conns  = loaded

        // Migrate legacy single-account config when no accounts exist yet.
        if conns.isEmpty {
            if let endpoint = UserDefaults.standard.string(forKey: "hermit.serverBaseURL"),
               !endpoint.isEmpty {
                var conn = Connection(name: "Default", endpoint: endpoint)
                let legacyToken = KeychainHelper.shared.readAccountToken(key: "hermit.pat") ?? ""
#if DEBUG
                conn.token = legacyToken.isEmpty ? nil : legacyToken
#else
                KeychainHelper.shared.writeAccountToken(legacyToken, key: conn.keychainKey)
#endif
                conns = [conn]
                AccountStore.saveToDefaults(connections: conns)
            }
        }

        self.connections = conns
    }

    // MARK: - Public API

    func add(name: String, endpoint: String, token: String) {
        var conn = Connection(name: name, endpoint: endpoint)
#if DEBUG
        conn.token = token.isEmpty ? nil : token
#else
        KeychainHelper.shared.writeAccountToken(token, key: conn.keychainKey)
#endif
        connections.append(conn)
        save()
        restartEmbeddedServer()
    }

    func update(_ connection: Connection, token: String? = nil) {
        updateInPlace(connection, token: token)
        save()
        restartEmbeddedServer()
    }

    /// Update a token without triggering a server restart.
    /// Use this only during app initialisation, before the server has started,
    /// to avoid a dispatch_once re-entrancy deadlock via AppState.shared.
    func updateTokenOnly(_ connection: Connection, token: String) {
        updateInPlace(connection, token: token)
        save()
    }

    private func updateInPlace(_ connection: Connection, token: String?) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        var updated = connection
        if let token {
#if DEBUG
            updated.token = token.isEmpty ? nil : token
#else
            KeychainHelper.shared.writeAccountToken(token, key: connection.keychainKey)
#endif
        }
        connections[idx] = updated
    }

    func remove(_ connection: Connection) {
#if !DEBUG
        KeychainHelper.shared.deleteAccountToken(key: connection.keychainKey)
#endif
        connections.removeAll { $0.id == connection.id }
        save()
        restartEmbeddedServer()
    }

    func token(for connection: Connection) -> String? {
#if DEBUG
        return connection.token
#else
        return KeychainHelper.shared.readAccountToken(key: connection.keychainKey)
#endif
    }

    // MARK: - Connectivity probe

    func isConnected(_ connection: Connection) -> Bool {
        connectedIDs.contains(connection.id)
    }

    func probe(_ connection: Connection) async {
        let base = connection.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        let isGitHub = base.contains("github.com")
        let healthPath = isGitHub ? "/user" : "/api/v1/health"
        guard let url = URL(string: "\(base)\(healthPath)") else { return }

        var req = URLRequest(url: url, timeoutInterval: 8)
        if let token = token(for: connection) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
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
        AccountStore.saveToDefaults(connections: connections)
    }

    private static func loadFromDefaults() -> [Connection] {
        let defaults  = UserDefaults.standard
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
        return conns
    }

    private static func saveToDefaults(connections: [Connection]) {
        if let data = try? JSONEncoder().encode(connections) {
            UserDefaults.standard.set(data, forKey: "hermit.accounts")
        }
    }
}

// MARK: - RepositoryStore

/// Observable store for all saved repositories.
///
/// All repositories are always registered with the server simultaneously —
/// there is no single "active" repository. The menu bar shows all repos
/// as submenus; recently opened RFCs appear at the top.
@MainActor
final class RepositoryStore: ObservableObject {
    static let shared = RepositoryStore()

    @Published private(set) var repositories: [Repository] = []

    func repos(for account: Connection) -> [Repository] {
        repositories.filter { $0.accountID == account.id }
    }

    func add(accountID: UUID, owner: String, name: String,
             docsPath: String = "docs-cms/rfcs", rfcLabel: String = "hermit:rfc-ready") {
        let repo = Repository(accountID: accountID, owner: owner, name: name,
                              docsPath: docsPath, rfcLabel: rfcLabel)
        repositories.append(repo)
        save()
        restartEmbeddedServer()
    }

    func update(_ repo: Repository) {
        guard let idx = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[idx] = repo
        save()
        restartEmbeddedServer()
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0.id == repo.id }
        save()
        restartEmbeddedServer()
    }

    // MARK: - Private

    private init() {
        let defaults = UserDefaults.standard

        if let data = defaults.data(forKey: "hermit.repositories") ??
                      defaults.string(forKey: "hermit.repositories")?.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([Repository].self, from: data) {
            repositories = decoded
        }

        // Migrate legacy single-repo config when no repos exist yet.
        if repositories.isEmpty {
            let ud    = UserDefaults.standard
            let owner = ud.string(forKey: "hermit.repoOwner") ?? ""
            let name  = ud.string(forKey: "hermit.repoName")  ?? ""
            let accountID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
            if !owner.isEmpty, !name.isEmpty {
                let docs  = ud.string(forKey: "hermit.docsPath")  ?? "docs-cms/rfcs"
                let label = ud.string(forKey: "hermit.rfcLabel")  ?? "hermit:rfc-ready"
                let repo  = Repository(accountID: accountID, owner: owner, name: name,
                                       docsPath: docs, rfcLabel: label)
                repositories = [repo]
                save()
            }
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(repositories) {
            UserDefaults.standard.set(data, forKey: "hermit.repositories")
        }
    }
}

// MARK: - Embedded server restart helper

@MainActor
private func restartEmbeddedServer() {
#if os(macOS)
    EmbeddedServerManager.shared.restart()
#endif
}
