import Foundation
import Combine

// MARK: - Connection

/// A named server connection with its own endpoint and PAT.
///
/// In DEBUG builds the PAT is stored directly on this struct so it round-trips
/// through UserDefaults alongside the other connection fields — no Keychain
/// involved, no password prompts during development.
/// In Release builds `token` is excluded from Codable; the PAT lives
/// exclusively in the Keychain keyed by `hermit.account.<UUID>`.
struct Connection: Identifiable, Equatable {
    var id:       UUID   = UUID()
    var name:     String          // e.g. "GitHub"
    var endpoint: String          // e.g. "https://api.github.com"
#if DEBUG
    var token:    String? = nil   // stored in UserDefaults in DEBUG builds only
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
    var serverID:  String? = nil
    var accountID: UUID           // foreign key → Connection.id
    var owner:     String         // e.g. "gitea_admin"
    var name:      String         // e.g. "hermit-rfcs"
    var docsPath:  String         // e.g. "docs-cms/rfcs"
    var rfcLabel:  String         // e.g. ""
    var lastSyncedAt: Date? = nil

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
        // Skip loopback endpoints — those are the embedded server's own address.
        if conns.isEmpty {
            if let endpoint = UserDefaults.standard.string(forKey: "hermit.serverBaseURL"),
               !endpoint.isEmpty,
               !Self.isLoopbackEndpoint(endpoint) {
                let conn = Connection(name: "Default", endpoint: endpoint)
                let legacyToken = KeychainHelper.shared.readAccountToken(key: "hermit.pat") ?? ""
                if !legacyToken.isEmpty {
                    KeychainHelper.shared.writeAccountToken(legacyToken, key: conn.keychainKey)
                }
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
        if !token.isEmpty {
            KeychainHelper.shared.writeAccountToken(token, key: conn.keychainKey)
        }
#endif
        connections.append(conn)
        save()
        NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
        Task { await probe(conn) }
    }

    func update(_ connection: Connection, token: String? = nil) {
        updateInPlace(connection, token: token)
        save()
        NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
        // Re-probe after an edit so any token or endpoint change is reflected at once.
        if let refreshed = connections.first(where: { $0.id == connection.id }) {
            Task { await probe(refreshed) }
        }
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
        NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
    }

    func token(for connection: Connection) -> String? {
#if DEBUG
        return connection.token
#else
        return KeychainHelper.shared.readAccountToken(key: connection.keychainKey)
#endif
    }

    // MARK: - SSO URL reporting
    // Repo-level SAML errors (detected during RFC loading) are pushed here so
    // ConnectionStateView can surface the authorization link on the account row
    // even when the /user probe doesn't return an X-GitHub-SSO header.

    private var ssoURLs: [UUID: URL] = [:]

    func reportSSO(url: URL, for accountID: UUID) {
        guard ssoURLs[accountID] != url else { return }
        ssoURLs[accountID] = url
        objectWillChange.send()
    }

    func clearSSO(for accountID: UUID) {
        guard ssoURLs[accountID] != nil else { return }
        ssoURLs.removeValue(forKey: accountID)
        objectWillChange.send()
    }

    /// Returns the best available SSO URL for the connection — from either the
    /// account probe (X-GitHub-SSO header) or a repo-level SAML error.
    func ssoURL(for connection: Connection) -> URL? {
        probeErrors[connection.id]?.ssoURL ?? ssoURLs[connection.id]
    }

    // MARK: - Connectivity probe

    struct ProbeError {
        let statusCode: Int?
        let message: String
        let ssoURL: URL?
    }

    func isConnected(_ connection: Connection) -> Bool {
        connectedIDs.contains(connection.id)
    }

    func probeError(for connection: Connection) -> ProbeError? {
        probeErrors[connection.id]
    }

    func probe(_ connection: Connection) async {
        let base = connection.endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        // GitHub  → GET /user          (authenticated; returns 401 on bad/missing token)
        // Gitea   → GET /api/v1/user   (authenticated; same behaviour as GitHub)
        // Other   → GET /api/v1/health (unauthenticated reachability check only)
        let isGitHub = Self.isGitHubAPIEndpoint(base)
        let isGitea  = Self.isGiteaEndpoint(base)
        let healthPath: String
        if isGitHub || isGitea {
            healthPath = "/user"
        } else {
            healthPath = "/api/v1/health"
        }
        guard let url = URL(string: "\(base)\(healthPath)") else { return }

        var req = URLRequest(url: url, timeoutInterval: 8)
        if let token = token(for: connection) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let httpResp   = resp as? HTTPURLResponse
            let statusCode = httpResp?.statusCode
            let ok = statusCode.map { (200..<300).contains($0) } ?? false
            if ok {
                connectedIDs.insert(connection.id)
                probeErrors.removeValue(forKey: connection.id)
                ssoURLs.removeValue(forKey: connection.id)
            } else {
                connectedIDs.remove(connection.id)
                let body      = String(data: data, encoding: .utf8) ?? ""
                let ssoHeader = httpResp?.value(forHTTPHeaderField: "X-GitHub-SSO")
                var ssoURL    = extractSAMLURL(from: body) ?? extractSAMLURLFromHeader(ssoHeader)

                // /user on GitHub doesn't return SAML headers even when SSO is
                // enforced — it just returns 401 "Bad credentials".  Probe an
                // associated repo endpoint which DOES return X-GitHub-SSO.
                if ssoURL == nil, statusCode == 401, Self.isGitHubAPIEndpoint(base) {
                    ssoURL = await probeRepoForSSO(base: base, connection: connection)
                }

                probeErrors[connection.id] = ProbeError(
                    statusCode: statusCode,
                    message:    probeMessage(statusCode: statusCode, body: body, ssoHeader: ssoHeader, ssoURL: ssoURL),
                    ssoURL:     ssoURL
                )
            }
        } catch {
            connectedIDs.remove(connection.id)
            probeErrors[connection.id] = ProbeError(
                statusCode: nil,
                message:    error.localizedDescription,
                ssoURL:     nil
            )
        }
        objectWillChange.send()
    }

    /// When the /user probe returns 401, try a repo endpoint which returns
    /// the X-GitHub-SSO header when SAML SSO authorization is required.
    private func probeRepoForSSO(base: String, connection: Connection) async -> URL? {
        let repos = RepositoryStore.shared.repos(for: connection)
        guard let repo = repos.first,
              let repoURL = URL(string: "\(base)/repos/\(repo.owner)/\(repo.name)")
        else { return nil }

        var req = URLRequest(url: repoURL, timeoutInterval: 8)
        if let token = token(for: connection) {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
        let body      = String(data: data, encoding: .utf8) ?? ""
        let ssoHeader = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-GitHub-SSO")
        return extractSAMLURL(from: body) ?? extractSAMLURLFromHeader(ssoHeader)
    }

    // MARK: - Private

    private var connectedIDs: Set<UUID> = []
    private var probeErrors:  [UUID: ProbeError] = [:]

    private func probeMessage(statusCode: Int?, body: String, ssoHeader: String? = nil, ssoURL: URL? = nil) -> String {
        // SAML SSO takes priority — detected via header, body, or repo probe.
        if ssoURL != nil || ssoHeader != nil ||
           body.localizedCaseInsensitiveContains("SAML") ||
           body.localizedCaseInsensitiveContains("sso") {
            return "Organization SSO authorization required."
        }
        switch statusCode {
        case 401: return "Authentication failed — check the token for this account."
        case 403: return "Access denied (403)."
        default:  return statusCode.map { "HTTP \($0)." } ?? "Connection failed."
        }
    }

    private func extractSAMLURL(from body: String) -> URL? {
        guard body.localizedCaseInsensitiveContains("SAML") ||
              body.localizedCaseInsensitiveContains("sso") else { return nil }
        let pattern = #"https://[^\s\\"]+authorization_request=[^\s\\"]+"#
        guard let range = body.range(of: pattern, options: .regularExpression) else { return nil }
        return URL(string: String(body[range]))
    }

    /// Parses `X-GitHub-SSO: required; url=https://github.com/.../sso?...`
    private func extractSAMLURLFromHeader(_ header: String?) -> URL? {
        guard let header else { return nil }
        let pattern = #"url=(https://[^\s;,]+)"#
        guard let range = header.range(of: pattern, options: .regularExpression) else { return nil }
        let matched = String(header[range]).replacingOccurrences(of: "url=", with: "")
        return URL(string: matched)
    }

    private static func isLoopbackEndpoint(_ endpoint: String) -> Bool {
        guard let host = URL(string: endpoint)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// True for github.com and GitHub Enterprise API endpoints.
    private static func isGitHubAPIEndpoint(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint),
              let host = url.host?.lowercased() else { return false }

        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return host == "api.github.com" ||
            host == "github.com" ||
            host.hasPrefix("github.") ||
            host.contains(".github.") ||
            path == "api/v3" ||
            path.hasSuffix("/api/v3")
    }

    /// True for self-hosted Gitea instances.  Gitea exposes GET /api/v1/user
    /// as an authenticated endpoint (returns 401 on bad/missing token), which
    /// gives us proper credential validation rather than the unauthenticated
    /// /api/v1/health check.
    private static func isGiteaEndpoint(_ endpoint: String) -> Bool {
        guard let url = URL(string: endpoint),
              let host = url.host?.lowercased() else { return false }
        // Localhost Gitea dev instances
        if host == "localhost" || host == "127.0.0.1" { return true }
        // Explicit /api/v1 path is the Gitea API base convention
        let path = url.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "api/v1" || path.hasSuffix("/api/v1")
    }

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
             docsPath: String = "docs-cms/rfcs", rfcLabel: String = "") {
        let repo = Repository(accountID: accountID, owner: owner, name: name,
                              docsPath: docsPath, rfcLabel: rfcLabel)
        add(repo)
    }

    func add(_ repo: Repository, requiresRestart: Bool = true) {
        repositories.append(repo)
        save()
        if requiresRestart {
            // hermit-9ds: no live server restart — user must relaunch to apply config changes.
            NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
        }
    }

    func update(_ repo: Repository) {
        guard let idx = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[idx] = repo
        save()
        // hermit-9ds: no live server restart — user must relaunch to apply config changes.
        NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
    }

    func markSynced(_ repo: Repository, at date: Date = Date()) {
        guard let idx = repositories.firstIndex(where: { $0.id == repo.id }) else { return }
        repositories[idx].lastSyncedAt = date
        save()
    }

    func remove(_ repo: Repository) {
        repositories.removeAll { $0.id == repo.id }
        save()
        // hermit-9ds: no live server restart — user must relaunch to apply config changes.
        NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
    }

    /// Moves `repo` to index 0 so that `makeAPIClient()` (which uses `.first`)
    /// treats it as the active repository. Does not trigger a server restart —
    /// all repos are always registered with the server simultaneously.
    func setActive(_ repo: Repository) {
        guard let idx = repositories.firstIndex(where: { $0.id == repo.id }),
              idx != 0 else { return }
        repositories.remove(at: idx)
        repositories.insert(repo, at: 0)
        save()
    }

    /// Replaces the stored list with repos received over mDNS from the Mac.
    /// Preserves UUIDs for repos already known (matched by owner+name) so that
    /// any in-flight references remain valid. Order is preserved (first = active).
    /// Does NOT post .hermitRestartRequired — no server restart needed on iPad.
    func replaceAll(fromMDNS incoming: [Repository]) {
        let merged: [Repository] = incoming.map { inbound in
            if let existing = repositories.first(where: {
                $0.owner.lowercased() == inbound.owner.lowercased() &&
                $0.name.lowercased()  == inbound.name.lowercased()
            }) {
                // Preserve the existing UUID; update mutable fields.
                return Repository(id: existing.id, serverID: inbound.serverID, accountID: existing.accountID,
                                  owner: inbound.owner, name: inbound.name,
                                  docsPath: inbound.docsPath, rfcLabel: inbound.rfcLabel,
                                  lastSyncedAt: existing.lastSyncedAt)
            }
            return inbound
        }
        guard merged != repositories else { return }
        repositories = merged
        save()
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
                let label = ud.string(forKey: "hermit.rfcLabel")  ?? ""
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

// MARK: - hermit-9ds: Notification posted when config changes require an app relaunch

extension Notification.Name {
    /// Posted by AccountStore/RepositoryStore when the user saves a change that
    /// requires the app to be relaunched for the embedded server to pick it up.
    /// Config changes no longer trigger a live server restart.
    static let hermitRestartRequired = Notification.Name("com.hashicorp.hermit.restartRequired")
    /// Posted by "Refresh All" in the menu bar to force all RepoSubmenu loaders to reload.
    static let hermitRefreshAll = Notification.Name("com.hashicorp.hermit.refreshAll")
}
