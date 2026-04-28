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
        load()
    }

    // MARK: - Public API

    func add(name: String, endpoint: String, token: String) {
        let conn = Connection(name: name, endpoint: endpoint)
        KeychainHelper.shared.writeAccountToken(token, key: conn.keychainKey)
        connections.append(conn)
        if connections.count == 1 { activeID = conn.id }
        save()
    }

    func update(_ connection: Connection, token: String? = nil) {
        guard let idx = connections.firstIndex(where: { $0.id == connection.id }) else { return }
        connections[idx] = connection
        if let token { KeychainHelper.shared.writeAccountToken(token, key: connection.keychainKey) }
        save()
    }

    func remove(_ connection: Connection) {
        KeychainHelper.shared.deleteAccountToken(key: connection.keychainKey)
        connections.removeAll { $0.id == connection.id }
        if activeID == connection.id { activeID = connections.first?.id }
        save()
    }

    func setActive(_ connection: Connection) {
        activeID = connection.id
        defaults.set(connection.id.uuidString, forKey: activeIDKey)
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
        guard let url = URL(string: "\(base)/api/v1/health") else { return }
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

    // MARK: - Migration

    /// Called once at launch to import the legacy single-account config.
    func migrateIfNeeded() {
        guard connections.isEmpty,
              let endpoint = ConfigStore.shared.serverBaseURL,
              !endpoint.isEmpty else { return }

        let name  = "Default"
        let token = KeychainHelper.shared.pat ?? ""
        add(name: name, endpoint: endpoint, token: token)
    }

    // MARK: - Private

    private var connectedIDs: Set<UUID> = []

    private func load() {
        if let data = defaults.data(forKey: connectionsKey),
           let decoded = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = decoded
        }
        if let raw = defaults.string(forKey: activeIDKey),
           let uuid = UUID(uuidString: raw) {
            activeID = uuid
        } else {
            activeID = connections.first?.id
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(connections) {
            defaults.set(data, forKey: connectionsKey)
        }
        if let id = activeID {
            defaults.set(id.uuidString, forKey: activeIDKey)
        }
    }
}
