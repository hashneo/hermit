import SwiftUI
import Network

// MARK: - SettingsView
// hermit-3wh: Server settings tab (macOS — mode selector, Bonjour list stub, remote URL)
// hermit-ogz: Server selection UI in iPad SettingsView
// hermit-jmt: Remote URL configuration and health-check validation

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    let embedded: Bool

    // hermit-9ds: shown when any config change requires an app relaunch
    @State private var showRestartBanner = false

    init(embedded: Bool = false) {
        self.embedded = embedded
    }

    var body: some View {
        VStack(spacing: 0) {
        // hermit-9ds: transient banner shown while the server restarts in the background
            if showRestartBanner {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.white)
                    Text("Restarting server to apply changes…")
                        .foregroundStyle(.white)
                        .font(.callout)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.accentColor)
            }

            TabView {
#if os(macOS)
                AccountSettingsTab()
                    .tabItem { Label("Account", systemImage: "person.circle") }
                RepositorySettingsTab()
                    .tabItem { Label("Repository", systemImage: "arrow.triangle.branch") }
#endif
                ServerSettingsTab()
                    .tabItem { Label("Server", systemImage: "server.rack") }
                AISettingsTab()
                    .tabItem { Label("AI", systemImage: "sparkles") }
            }
        }
#if os(macOS)
        .frame(width: embedded ? nil : 600, height: embedded ? nil : 560)
#endif
        // hermit-9ds: listen for config-change notifications from AccountStore/RepositoryStore
        .onReceive(NotificationCenter.default.publisher(for: .hermitRestartRequired)) { _ in
            showRestartBanner = true
            // Auto-dismiss after 4 s — covers cases where the port publisher
            // doesn't fire a new value (restart skipped, or port unchanged).
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                showRestartBanner = false
            }
        }
        // Also dismiss as soon as the server reports a new port.
#if os(macOS)
        .onReceive(EmbeddedServerManager.shared.$port.compactMap { $0 }) { _ in
            showRestartBanner = false
        }
#endif
    }
}

// MARK: - Account tab

private struct AccountSettingsTab: View {
    @ObservedObject private var store = AccountStore.shared
    @State private var showAddSheet  = false
    @State private var editTarget: Connection? = nil
    @State private var revokeTarget: Connection? = nil
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ──────────────────────────────────────────────────
            HStack {
                Label("Hermit authenticates with saved PATs. Git Credential Helper can import that PAT when adding or editing an account.", systemImage: "key")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding([.top, .trailing, .bottom], 8)
            }
            Divider()

            // ── Table ─────────────────────────────────────────────────────
            Table(store.connections, selection: $selection) {
                TableColumn("Name") { conn in
                    HStack(spacing: 6) {
                        Text(conn.name)
                    }
                }
                .width(min: 120, ideal: 160)

                TableColumn("Endpoint") { conn in
                    Text(conn.endpoint)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                TableColumn("State") { conn in
                    ConnectionStateView(connection: conn)
                }
                .width(min: 110, ideal: 160)

                TableColumn("Actions") { conn in
                    HStack(spacing: 4) {
                        Menu {
                            Button("Edit…") { editTarget = conn }
                            Button("Revoke", role: .destructive) { revokeTarget = conn }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .width(60)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddAccountSheet(isPresented: $showAddSheet)
        }
        .sheet(item: $editTarget) { conn in
            EditAccountSheet(connection: conn, isPresented: Binding(
                get: { editTarget != nil },
                set: { if !$0 { editTarget = nil } }
            ))
        }
        .confirmationDialog(
            "Revoke \"\(revokeTarget?.name ?? "")\"?",
            isPresented: Binding(get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Revoke", role: .destructive) {
                if let c = revokeTarget { store.remove(c) }
                revokeTarget = nil
            }
        } message: {
            Text("The token will be deleted from the Keychain.")
        }
        .task(id: store.connections.map(\.id)) {
            while !Task.isCancelled {
                await refreshAccountConnectivity()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func refreshAccountConnectivity() async {
        for conn in store.connections {
#if os(macOS)
            let storedToken = store.token(for: conn)
            // Only invoke the credential helper when Hermit has no stored token.
            // Once fetched, the token is written to Hermit's own Keychain entry
            // (or UserDefaults in DEBUG) via updateTokenOnly — all subsequent
            // reads come from there, with no system Keychain ACL prompts.
            //
            // Do NOT re-invoke on 401: the bad token is already in Hermit's
            // store, and calling the helper every 60 s just re-prompts the user
            // with the same (still-invalid) credential.  On 401 the user must
            // edit the account to supply a fresh token.
            if (storedToken ?? "").isEmpty {
                let host = resolvedCredentialHost(endpoint: conn.endpoint, override: "")
                if case .success(let cred) = await GitCredentialHelper.lookup(host: host),
                   !cred.password.isEmpty {
                    store.updateTokenOnly(conn, token: cred.password)
                }
            }
#endif
            let refreshed = store.connections.first(where: { $0.id == conn.id }) ?? conn
            await store.probe(refreshed)
        }
    }
}

// MARK: - Connection state indicator

private struct ConnectionStateView: View {
    @ObservedObject private var store = AccountStore.shared
    let connection: Connection

    var body: some View {
        let connected = store.isConnected(connection)
        let ssoURL    = store.ssoURL(for: connection)
        let errMsg    = store.probeError(for: connection)?.message

        if let url = ssoURL {
            // Replace the whole state cell with a prominent SSO link so users
            // can't miss the required action.
            Link(destination: url) {
                Label("Authorize SSO", systemImage: "person.badge.key")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.borderless)
            .help("Your token must be authorized for this organization's SAML SSO. Click to open GitHub.")
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Label(
                    connected ? "Connected" : "Disconnected",
                    systemImage: connected ? "checkmark.circle.fill" : "xmark.circle.fill"
                )
                .foregroundStyle(connected ? .green : .secondary)
                .font(.subheadline)

                if !connected, let msg = errMsg {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

// MARK: - Add account sheet

private enum AccountPreset: String, CaseIterable, Identifiable {
    case github           = "GitHub"
    case githubEnterprise = "GitHub Enterprise"
    case gitea            = "Gitea"
    case other            = "Other"

    var id: String { rawValue }

    /// Well-known API endpoint, or nil when the user must supply one.
    var fixedEndpoint: String? {
        switch self {
        case .github:           return "https://api.github.com"
        case .githubEnterprise: return nil
        case .gitea:            return nil
        case .other:            return nil
        }
    }

    /// Default display name pre-filled into the Name field.
    var defaultName: String {
        switch self {
        case .github:           return "GitHub"
        case .githubEnterprise: return "GitHub Enterprise"
        case .gitea:            return "Gitea"
        case .other:            return ""
        }
    }

    /// Placeholder shown in the endpoint field when the user must type one.
    var endpointPlaceholder: String {
        switch self {
        case .github:           return ""
        case .githubEnterprise: return "https://github.mycompany.com/api/v3"
        case .gitea:            return "https://gitea.example.com"
        case .other:            return "https://example.com"
        }
    }
}

private struct AddAccountSheet: View {
    @ObservedObject private var store = AccountStore.shared
    @Binding var isPresented: Bool

    @State private var preset:   AccountPreset = .github
    @State private var name     = AccountPreset.github.defaultName
    @State private var endpoint = AccountPreset.github.fixedEndpoint ?? ""
    @State private var token    = ""
    @State private var isSaving = false
#if os(macOS)
    @State private var credentialStatus: GitCredentialHelperStatus = .idle
#endif

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !effectiveEndpoint.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The endpoint that will actually be saved — either the preset's fixed
    /// value or whatever the user typed.
    private var effectiveEndpoint: String {
        preset.fixedEndpoint ?? endpoint
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $preset) {
                        ForEach(AccountPreset.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    .onChange(of: preset) { _, newPreset in
                        // Pre-fill name when switching presets (don't clobber
                        // something the user already typed for "Other").
                        if name.isEmpty || name == preset.defaultName {
                            name = newPreset.defaultName
                        }
                        // Clear the custom endpoint field when switching away
                        // from a preset that needs one.
                        if newPreset.fixedEndpoint != nil {
                            endpoint = ""
                        }
                    }

                    TextField("Name", text: $name, prompt: Text("Display name"))

                    if let fixed = preset.fixedEndpoint {
                        // Well-known endpoint — show it as read-only.
                        LabeledContent("Endpoint", value: fixed)
                            .foregroundStyle(.secondary)
                    } else {
                        TextField(
                            "Endpoint",
                            text: $endpoint,
                            prompt: Text(preset.endpointPlaceholder)
                        )
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
#endif
                    }
                } header: {
                    Text("Connection")
                }
                // Authentication — macOS only.
                // On iOS all GitHub API calls are proxied through the paired
                // Mac's embedded server; the iPad never needs a PAT.
#if os(macOS)
                Section {
                    SecureField("Personal Access Token", text: $token)
                        .textContentType(.password)
                    if credentialStatus != .idle {
                        Label(credentialStatus.message, systemImage: credentialStatus.systemImage)
                            .font(.caption)
                            .foregroundStyle(credentialStatus.tint)
                    }
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Leave blank to use your local Git credential helper automatically when saving.")
                        .foregroundStyle(.secondary)
                }
#else
                Section {
                    Label(
                        "Credentials are managed by your paired Mac. No token is needed on this device.",
                        systemImage: "lock.laptopcomputer"
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("Authentication")
                }
#endif
            }
            .formStyle(.grouped)
            .navigationTitle("Add Account")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveAccount() }
                    }
                    .disabled(!canSave || isSaving)
                }
            }
        }
#if os(macOS)
        .frame(width: 420, height: 290)
#endif
    }

#if os(macOS)
    private func saveAccount() async {
        let resolvedToken: String
        if token.trimmingCharacters(in: .whitespaces).isEmpty {
            // No PAT entered — try the local Git credential helper automatically.
            isSaving = true
            credentialStatus = .checking
            let host = resolvedCredentialHost(endpoint: effectiveEndpoint, override: "")
            let result = await GitCredentialHelper.lookup(host: host)
            isSaving = false
            switch result {
            case .success(let credential):
                credentialStatus = .found("Token resolved via git credential helper for \(credential.host).")
                resolvedToken = credential.password
            case .failure(let msg):
                // No credential found — tell the user rather than saving an empty token.
                credentialStatus = .failed("No credential found: \(msg). Enter a Personal Access Token above.")
                return   // keep the sheet open
            }
        } else {
            resolvedToken = token
        }
        store.add(
            name: name.trimmingCharacters(in: .whitespaces),
            endpoint: effectiveEndpoint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            token: resolvedToken
        )
        isPresented = false
    }
#else
    private func saveAccount() async {
        store.add(
            name: name.trimmingCharacters(in: .whitespaces),
            endpoint: effectiveEndpoint
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            token: token
        )
        isPresented = false
    }
#endif
}

// MARK: - Edit account sheet

private struct EditAccountSheet: View {
    @ObservedObject private var store = AccountStore.shared
    let connection: Connection
    @Binding var isPresented: Bool

    @State private var name: String
    @State private var endpoint: String
    @State private var token: String = ""
#if os(macOS)
    @State private var credentialHost: String
    @State private var credentialStatus: GitCredentialHelperStatus = .idle
    @State private var checkingCredential = false
#endif

    init(connection: Connection, isPresented: Binding<Bool>) {
        self.connection = connection
        _isPresented = isPresented
        _name     = State(initialValue: connection.name)
        _endpoint = State(initialValue: connection.endpoint)
#if os(macOS)
        _credentialHost = State(initialValue: resolvedCredentialHost(endpoint: connection.endpoint, override: ""))
#endif
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Name", text: $name)
                    TextField("Endpoint", text: $endpoint)
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
#endif
                }
                Section {
                    SecureField("New token (leave blank to keep existing)", text: $token)
                        .textContentType(.password)
                } header: {
                    Text("Authentication")
                } footer: {
                    Text("Leave blank to keep the existing token.")
                }
#if os(macOS)
                GitCredentialHelperSection(
                    endpoint: endpoint,
                    host: $credentialHost,
                    status: credentialStatus,
                    isChecking: checkingCredential,
                    onCheck: { Task { await checkGitCredential(fillToken: false) } },
                    onUse: { Task { await checkGitCredential(fillToken: true) } }
                )
#endif
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Account")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = connection
                        updated.name     = name.trimmingCharacters(in: .whitespaces)
                        updated.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        store.update(updated, token: token.isEmpty ? nil : token)
                        isPresented = false
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
#if os(macOS)
        .frame(width: 420, height: 300)
#endif
    }

#if os(macOS)
    private func checkGitCredential(fillToken: Bool) async {
        checkingCredential = true
        credentialStatus = .checking
        let host = resolvedCredentialHost(endpoint: endpoint, override: credentialHost)
        let result = await GitCredentialHelper.lookup(host: host)
        checkingCredential = false

        switch result {
        case .success(let credential):
            credentialHost = credential.host
            if fillToken {
                token = credential.password
                credentialStatus = .found("Loaded credential for \(credential.host). Save to update this account token.")
            } else {
                credentialStatus = .found("Credential helper returned a password for \(credential.host).")
            }
        case .failure(let message):
            credentialStatus = .failed(message)
        }
    }
#endif
}

#if os(macOS)
private enum GitCredentialHelperStatus: Equatable {
    case idle
    case checking
    case found(String)
    case failed(String)

    var message: String {
        switch self {
        case .idle:
            return "Use the local Git credential helper as a token source for this account."
        case .checking:
            return "Checking git credential helper..."
        case .found(let message), .failed(let message):
            return message
        }
    }

    var systemImage: String {
        switch self {
        case .idle:
            return "key"
        case .checking:
            return "arrow.triangle.2.circlepath"
        case .found:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .idle, .checking:
            return .secondary
        case .found:
            return .green
        case .failed:
            return .orange
        }
    }
}

private struct GitCredentialHelperSection: View {
    let endpoint: String
    @Binding var host: String
    let status: GitCredentialHelperStatus
    let isChecking: Bool
    let onCheck: () -> Void
    let onUse: () -> Void

    var body: some View {
        Section {
            TextField("Credential host", text: $host, prompt: Text(defaultHostPrompt))
                .autocorrectionDisabled()
            HStack(spacing: 8) {
                Button("Check Helper", action: onCheck)
                    .disabled(isChecking)
                Button("Use Git Credential", action: onUse)
                    .disabled(isChecking)
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Label(status.message, systemImage: status.systemImage)
                .font(.caption)
                .foregroundStyle(status.tint)
        } header: {
            Text("Git Credential Helper")
        } footer: {
            Text("Hermit calls git-credential-osxkeychain directly (bypassing /usr/bin/git which is incompatible with the App Sandbox). Leave the host blank to derive it from the endpoint.")
        }
    }

    private var defaultHostPrompt: String {
        resolvedCredentialHost(endpoint: endpoint, override: "")
    }
}

private struct GitCredential {
    let host: String
    let username: String
    let password: String
}

private enum GitCredentialLookupResult {
    case success(GitCredential)
    case failure(String)
}

/// Reads Git credentials without going through `/usr/bin/git`.
///
/// `/usr/bin/git` links `libxcselect.dylib` (Xcode developer directory
/// selector) which errors immediately inside the App Sandbox.
///
/// Strategy:
///  1. `git-credential-osxkeychain get` — handles credentials stored by
///     `git config --global credential.helper osxkeychain` (internet passwords).
///  2. Direct `SecItemCopyMatching` for `gh:<host>` generic passwords — handles
///     credentials stored by `gh auth login`.  The gh CLI creates these items
///     with an open ACL so no system confirmation dialog appears.
private enum GitCredentialHelper {

    private static let helperCandidates: [String] = [
        "/Library/Developer/CommandLineTools/usr/libexec/git-core/git-credential-osxkeychain",
        "/Applications/Xcode.app/Contents/Developer/usr/libexec/git-core/git-credential-osxkeychain",
    ]

    static func lookup(host: String) async -> GitCredentialLookupResult {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            return .failure("Enter an endpoint or credential host first.")
        }

        // Normalise api.github.com → github.com
        let lookupHost: String
        if trimmedHost == "api.github.com" {
            lookupHost = "github.com"
        } else if trimmedHost.hasPrefix("api.") {
            lookupHost = String(trimmedHost.dropFirst(4))
        } else {
            lookupHost = trimmedHost
        }

        // 1. osxkeychain (internet passwords — git credential store)
        if let helperPath = helperCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }), let cred = await osxKeychainLookup(helperPath: helperPath, host: lookupHost) {
            return .success(cred)
        }

        // 2. gh CLI generic password — service "gh:<host>"
        if let cred = ghCliKeychainLookup(host: lookupHost) {
            return .success(cred)
        }

        return .failure("No credential found for \(lookupHost). Sign in with `gh auth login` or store a token via `git credential approve`.")
    }

    // MARK: - osxkeychain subprocess

    private static func osxKeychainLookup(helperPath: String, host: String) async -> GitCredential? {
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helperPath)
            process.arguments = ["get"]

            let stdin  = Pipe()
            let stdout = Pipe()
            process.standardInput  = stdin
            process.standardOutput = stdout
            process.standardError  = FileHandle.nullDevice

            do {
                try process.run()
                stdin.fileHandleForWriting.write(
                    Data("protocol=https\nhost=\(host)\n\n".utf8))
                try? stdin.fileHandleForWriting.close()
                process.waitUntilExit()

                guard process.terminationStatus == 0 else { return nil }

                let out = String(data: stdout.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                var kv: [String: String] = [:]
                for line in out.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    kv[String(parts[0])] = String(parts[1])
                }
                guard let password = kv["password"], !password.isEmpty else { return nil }
                return GitCredential(host: host, username: kv["username"] ?? "", password: password)
            } catch {
                return nil
            }
        }.value
    }

    // MARK: - gh CLI Keychain (generic password, service "gh:<host>")

    private static func ghCliKeychainLookup(host: String) -> GitCredential? {
        let query: [CFString: Any] = [
            kSecClass:              kSecClassGenericPassword,
            kSecAttrService:        "gh:\(host)",
            kSecReturnAttributes:   true,
            kSecReturnData:         true,
            kSecMatchLimit:         kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let dict     = item as? [CFString: Any],
              let data     = dict[kSecValueData] as? Data,
              let raw      = String(data: data, encoding: .utf8),
              !raw.isEmpty
        else { return nil }

        // The gh CLI stores secrets via go-keyring which base64-encodes the
        // value and prefixes it with "go-keyring-base64:".  Decode it so we
        // get the actual token, not the encoded wrapper.
        let password = decodeGoKeyring(raw)
        guard !password.isEmpty else { return nil }

        let username = (dict[kSecAttrAccount] as? String) ?? ""
        return GitCredential(host: host, username: username, password: password)
    }

    /// Strips the `go-keyring-base64:` prefix used by the gh CLI's keyring
    /// backend and base64-decodes the remainder.  Returns the input unchanged
    /// if the prefix is absent (plain-text storage from older gh versions).
    private static func decodeGoKeyring(_ raw: String) -> String {
        let prefix = "go-keyring-base64:"
        guard raw.hasPrefix(prefix) else { return raw }
        let encoded = String(raw.dropFirst(prefix.count))
        guard let data = Data(base64Encoded: encoded),
              let decoded = String(data: data, encoding: .utf8)
        else { return raw }
        return decoded
    }
}

private func resolvedCredentialHost(endpoint: String, override: String) -> String {
    let trimmedOverride = override.trimmingCharacters(in: .whitespacesAndNewlines)
    if !trimmedOverride.isEmpty {
        return trimmedOverride
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    let trimmedEndpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmedEndpoint), let host = url.host else {
        return trimmedEndpoint
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
    return host
}
#endif

// MARK: - Repository tab

private struct RepositorySettingsTab: View {
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var repoStore    = RepositoryStore.shared
    @State private var showAddSheet   = false
    @State private var editTarget:    Repository? = nil
    @State private var deleteTarget:  Repository? = nil
    @State private var validating:    UUID?        = nil   // repo ID currently being validated
    @State private var validationError: String?    = nil   // error message to show
    @State private var errorRepo:     Repository?  = nil   // repo that failed, offered for edit
    @State private var selection:    Set<UUID>   = []

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ──────────────────────────────────────────────────
            HStack {
                Spacer()
                Button { showAddSheet = true } label: {
                    Label("Add Repository", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .padding([.top, .trailing, .bottom], 8)
            }
            Divider()

            // ── Table ─────────────────────────────────────────────────────
            Table(repoStore.repositories, selection: $selection) {
                TableColumn("Account") { repo in
                    let acct = accountStore.connections.first { $0.id == repo.accountID }
                    HStack(spacing: 6) {
                        Text(acct?.name ?? "—")
                            .foregroundStyle(acct == nil ? .secondary : .primary)
                    }
                }
                .width(min: 120, ideal: 160)

                TableColumn("Owner") { repo in
                    Text(repo.owner)
                }

                TableColumn("Repository") { repo in
                    Text(repo.name)
                }

                TableColumn("Last synced") { repo in
                    RepositoryLastSyncedText(date: repo.lastSyncedAt)
                }
                .width(min: 110, ideal: 140)

                TableColumn("Actions") { repo in
                    Menu {
                        Button("Set Active") {
                            Task { await validateAndActivate(repo) }
                        }
                        .disabled(validating != nil)
                        Divider()
                        Button("Edit…") { editTarget = repo }
                        Button("Delete", role: .destructive) { deleteTarget = repo }
                    } label: {
                        if validating == repo.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "ellipsis.circle")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .width(60)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddRepoSheet(isPresented: $showAddSheet)
        }
        .sheet(item: $editTarget) { repo in
            EditRepoSheet(repo: repo, isPresented: Binding(
                get: { editTarget != nil },
                set: { if !$0 { editTarget = nil } }
            ))
        }
        .sheet(item: $errorRepo) { repo in
            EditRepoSheet(repo: repo, isPresented: Binding(
                get: { errorRepo != nil },
                set: { if !$0 { errorRepo = nil } }
            ))
        }
        .alert("Cannot activate repository", isPresented: Binding(
            get: { validationError != nil },
            set: { if !$0 { validationError = nil } }
        )) {
            Button("Edit Repository") {
                editTarget = errorRepo
                validationError = nil
            }
            Button("Cancel", role: .cancel) {
                validationError = nil
                errorRepo = nil
            }
        } message: {
            Text(validationError ?? "")
        }
        .confirmationDialog(
            "Delete \"\(deleteTarget?.fullName ?? "")\"?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let r = deleteTarget { repoStore.remove(r) }
                deleteTarget = nil
            }
        }
    }

    // MARK: - Validation

    private func validateAndActivate(_ repo: Repository) async {
        // Pre-flight: account + token must exist before we touch anything.
        guard let account = accountStore.connections.first(where: { $0.id == repo.accountID }) else {
            errorRepo = repo
            validationError = "No account found for this repository. Edit the repository and select a valid account."
            return
        }
        guard let token = AccountStore.shared.token(for: account), !token.isEmpty else {
            errorRepo = repo
            validationError = "No PAT configured for account \"\(account.name)\". Edit the account and add a token."
            return
        }
        guard !AppState.shared.serverBaseURL.isEmpty else {
            errorRepo = repo
            validationError = "No server running. Start the app before switching repositories."
            return
        }

        validating = repo.id

        // All repos are always registered with the server simultaneously.
        // Just verify the repo is reachable — no restart needed.
        let error = await waitForRepo(repo, token: token)

        validating = nil

        if let error {
            errorRepo = repo
            validationError = error
        } else {
            // Move this repo to the front so makeAPIClient() picks it up as active,
            // then update AppState so iPadRootView's onChange triggers a fresh load.
            RepositoryStore.shared.setActive(repo)
            RepositoryStore.shared.markSynced(repo)
            AppState.shared.docsPath = repo.docsPath
            AppState.shared.rfcLabel = repo.rfcLabel
            AppState.shared.repoOwner = repo.owner
            AppState.shared.repoName  = repo.name
        }
    }

    /// Polls the server (up to 10 s) until the repo appears in its registered list.
    /// Returns nil on success or an error string on failure.
    private func waitForRepo(_ repo: Repository, token: String) async -> String? {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            // Wait briefly between polls — server needs ~300 ms to restart.
            try? await Task.sleep(nanoseconds: 500_000_000)

            let serverURL = AppState.shared.serverBaseURL
            guard !serverURL.isEmpty,
                  let base = URL(string: serverURL) else { continue }

            var req = URLRequest(url: base.appendingPathComponent("api/v1/repositories"))
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.timeoutInterval = 3

            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { continue }

            struct Item: Decodable { let owner: String; let name: String }
            struct Page: Decodable { let items: [Item] }
            guard let page = try? JSONDecoder().decode(Page.self, from: data) else { continue }

            if page.items.contains(where: {
                $0.owner.lowercased() == repo.owner.lowercased() &&
                $0.name.lowercased()  == repo.name.lowercased()
            }) {
                return nil  // success
            }
        }
        return "\(repo.fullName) did not appear on the server after restart. Check the owner and repository name are correct."
    }
}

private struct RepositoryLastSyncedText: View {
    let date: Date?

    var body: some View {
        Text(label)
            .foregroundStyle(date == nil ? .secondary : .primary)
            .lineLimit(1)
            .help(helpText)
    }

    private var label: String {
        guard let date else { return "Never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Synced \(formatter.localizedString(for: date, relativeTo: Date()))"
    }

    private var helpText: String {
        guard let date else { return "This repository has not synced successfully yet." }
        return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

// MARK: - Add repository sheet

private struct AddRepoSheet: View {
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var repoStore    = RepositoryStore.shared
    @Binding var isPresented: Bool

    @State private var selectedAccountID: UUID? = nil
    @State private var owner    = ""
    @State private var name     = ""
    @State private var docsPath = ""
    @State private var rfcLabel = ""
    @State private var isSaving = false

    var canSave: Bool {
        selectedAccountID != nil &&
        !owner.trimmingCharacters(in: .whitespaces).isEmpty &&
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if accountStore.connections.isEmpty {
                        Text("No accounts configured — add one in the Account tab first.")
                            .foregroundStyle(.secondary)
                    } else {
                        Picker("Account", selection: $selectedAccountID) {
                            Text("Select…").tag(Optional<UUID>.none)
                            ForEach(accountStore.connections) { conn in
                                Text(conn.name).tag(Optional(conn.id))
                            }
                        }
                    }
                }
                Section("Repository") {
                    TextField("Owner", text: $owner, prompt: Text("org-or-user"))
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    TextField("Name", text: $name, prompt: Text("repository-name"))
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                }
                Section("Advanced (optional)") {
                    TextField("Docs path", text: $docsPath, prompt: Text("docs-cms/rfcs"))
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    TextField("RFC label", text: $rfcLabel, prompt: Text(""))
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Add Repository")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await saveRepository() }
                    }
                    .disabled(!canSave)
                }
            }
            .onAppear {
                if selectedAccountID == nil {
                    selectedAccountID = accountStore.connections.first?.id
                }
            }
        }
#if os(macOS)
        .frame(width: 480, height: 380)
#endif
    }

    private func saveRepository() async {
        guard let aid = selectedAccountID else { return }
        isSaving = true
        defer { isSaving = false }

        var repo = Repository(
            accountID: aid,
            owner: owner.trimmingCharacters(in: .whitespaces),
            name: name.trimmingCharacters(in: .whitespaces),
            docsPath: docsPath.isEmpty ? "docs-cms/rfcs" : docsPath.trimmingCharacters(in: .whitespaces),
            rfcLabel: rfcLabel.isEmpty ? "" : rfcLabel.trimmingCharacters(in: .whitespaces)
        )
        let registeredServerID = await registerWithRunningServer(repo)
        if let serverID = registeredServerID {
            repo.serverID = serverID
            repo.lastSyncedAt = Date()
        }
        repoStore.add(repo, requiresRestart: registeredServerID == nil)
        isPresented = false
    }

    private func registerWithRunningServer(_ repo: Repository) async -> String? {
        guard let account = accountStore.connections.first(where: { $0.id == repo.accountID }),
              let token = accountStore.token(for: account), !token.isEmpty,
              !AppState.shared.serverBaseURL.isEmpty,
              let base = URL(string: AppState.shared.serverBaseURL) else {
            return nil
        }

        var req = URLRequest(url: base.appendingPathComponent("api/v1/repositories"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        let payload: [String: String] = [
            "owner": repo.owner,
            "name": repo.name,
            "base_url": resolvedAPIBase(for: account.endpoint),
            "personal_access_token": token,
            "docs_path_policy": repo.docsPath,
            "rfc_label": repo.rfcLabel
        ]
        req.httpBody = try? JSONEncoder().encode(payload)

        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { return nil }
        if http.statusCode == 409 {
            return await findServerRepositoryID(for: repo, token: token, base: base)
        }
        guard (200..<300).contains(http.statusCode) else { return nil }
        struct CreatedRepository: Decodable { let id: String }
        return try? JSONDecoder().decode(CreatedRepository.self, from: data).id
    }

    private func findServerRepositoryID(for repo: Repository, token: String, base: URL) async -> String? {
        var req = URLRequest(url: base.appendingPathComponent("api/v1/repositories"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 5
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        struct Item: Decodable { let id: String; let owner: String; let name: String }
        struct Page: Decodable { let items: [Item] }
        guard let page = try? JSONDecoder().decode(Page.self, from: data) else { return nil }
        return page.items.first {
            $0.owner.caseInsensitiveCompare(repo.owner) == .orderedSame &&
            $0.name.caseInsensitiveCompare(repo.name) == .orderedSame
        }?.id
    }

    private func resolvedAPIBase(for rawEndpoint: String) -> String {
        let trimmed = rawEndpoint.trimmingCharacters(in: .init(charactersIn: "/"))
        guard let host = URL(string: trimmed)?.host else { return trimmed }
        if host == "github.com" || host == "api.github.com" { return trimmed }
        if trimmed.hasSuffix("/api/v3") { return trimmed }
        if trimmed.hasSuffix("/api/v1") { return trimmed }
        return trimmed + "/api/v1"
    }
}

// MARK: - Edit repository sheet

private struct EditRepoSheet: View {
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var repoStore    = RepositoryStore.shared
    let repo: Repository
    @Binding var isPresented: Bool

    @State private var selectedAccountID: UUID
    @State private var owner:    String
    @State private var name:     String
    @State private var docsPath: String
    @State private var rfcLabel: String

    init(repo: Repository, isPresented: Binding<Bool>) {
        self.repo    = repo
        _isPresented = isPresented
        _selectedAccountID = State(initialValue: repo.accountID)
        _owner    = State(initialValue: repo.owner)
        _name     = State(initialValue: repo.name)
        _docsPath = State(initialValue: repo.docsPath)
        _rfcLabel = State(initialValue: repo.rfcLabel)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    Picker("Account", selection: $selectedAccountID) {
                        ForEach(accountStore.connections) { conn in
                            Text(conn.name).tag(conn.id)
                        }
                    }
                }
                Section("Repository") {
                    TextField("Owner", text: $owner)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                }
                Section("Advanced") {
                    TextField("Docs path", text: $docsPath)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    TextField("RFC label", text: $rfcLabel)
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Repository")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updated = repo
                        updated.accountID = selectedAccountID
                        updated.owner     = owner.trimmingCharacters(in: .whitespaces)
                        updated.name      = name.trimmingCharacters(in: .whitespaces)
                        updated.docsPath  = docsPath.trimmingCharacters(in: .whitespaces)
                        updated.rfcLabel  = rfcLabel.trimmingCharacters(in: .whitespaces)
                        repoStore.update(updated)
                        isPresented = false
                    }
                    .disabled(
                        owner.trimmingCharacters(in: .whitespaces).isEmpty ||
                        name.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
        }
#if os(macOS)
        .frame(width: 480, height: 380)
#endif
    }
}

// MARK: - Server tab (hermit-3wh / hermit-ogz / hermit-jmt)

private struct ServerSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var cacheReadTTLSeconds = ConfigStore.shared.cacheReadTTLSeconds
    @State private var cacheJitterSeconds = ConfigStore.shared.cacheJitterSeconds

    var body: some View {
        Form {
            Section("Mode") {
                modePicker
            }

            cacheRefreshSection

            switch appState.serverMode {
#if os(macOS)
            case .embeddedLocal:
                embeddedSection
#endif
            case .localNetwork:
                localNetworkSection
            case .remote:
                remoteSection
            default:
                EmptyView()
            }
        }
        .formStyle(.grouped)
        .onChange(of: cacheReadTTLSeconds) { _, value in
            ConfigStore.shared.cacheReadTTLSeconds = value
            NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
        }
        .onChange(of: cacheJitterSeconds) { _, value in
            ConfigStore.shared.cacheJitterSeconds = value
            NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
        }
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("Connectivity", selection: $appState.serverMode) {
#if os(macOS)
            Text("Embedded (this Mac)").tag(ServerMode.embeddedLocal)
#endif
            Text("Local Network").tag(ServerMode.localNetwork)
            Text("Remote").tag(ServerMode.remote(url: appState.remoteURL))
        }
        .pickerStyle(.segmented)
        .onChange(of: appState.serverMode) { _, new in
            ConfigStore.shared.serverMode = new
            applyModeChange(new)
        }
    }

    private var cacheRefreshSection: some View {
        Section {
            Stepper(value: $cacheReadTTLSeconds, in: 30...3600, step: 30) {
                LabeledContent("Read refresh interval") {
                    Text(durationLabel(cacheReadTTLSeconds))
                        .foregroundStyle(.secondary)
                }
            }
            Stepper(value: $cacheJitterSeconds, in: 0...600, step: 15) {
                LabeledContent("Jitter window") {
                    Text(durationLabel(cacheJitterSeconds))
                        .foregroundStyle(.secondary)
                }
            }
            Button("Reset Cache Timing") {
                cacheReadTTLSeconds = 180
                cacheJitterSeconds = 60
            }
        } header: {
            Text("Cache Refresh")
        } footer: {
            Text("Defaults are 3 minutes plus up to 1 minute of stable per-repository jitter. Changes apply after the embedded server restarts.")
        }
    }

    private func durationLabel(_ seconds: Int) -> String {
        if seconds == 0 { return "Off" }
        if seconds % 60 == 0 {
            let minutes = seconds / 60
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        return "\(seconds) seconds"
    }

    private func applyModeChange(_ mode: ServerMode) {
        switch mode {
#if os(macOS)
        case .embeddedLocal:
            if let port = EmbeddedServerManager.shared.port {
                let url = "http://127.0.0.1:\(port)"
                appState.serverBaseURL = url
                ConfigStore.shared.serverBaseURL = url
            }
#endif
        case .localNetwork:
            // serverBaseURL will be set when user selects a discovered server
            break
        case .remote(let url):
            appState.serverBaseURL = url
            ConfigStore.shared.serverBaseURL = url
        default:
            break
        }
    }

    // MARK: - Embedded section (macOS only)

#if os(macOS)
    @ViewBuilder
    private var embeddedSection: some View {
        Section("Embedded Server") {
            if let port = EmbeddedServerManager.shared.port {
                LabeledContent("Status") {
                    Label("Running on port \(port)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                LabeledContent("URL") {
                    Text("http://127.0.0.1:\(port)")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else if let error = EmbeddedServerManager.shared.errorMessage {
                LabeledContent("Status") {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            } else {
                LabeledContent("Status") {
                    ProgressView("Starting…")
                        .controlSize(.small)
                }
            }

            RepositoryLocationRow()
        }

        Section("Paired Devices") {
            PairedDevicesSection()
        }
    }
#endif

    // MARK: - Local Network section (hermit-ogz)

    @ViewBuilder
    private var localNetworkSection: some View {
        LocalNetworkSection()
    }

    // MARK: - Remote section (hermit-jmt)

    @ViewBuilder
    private var remoteSection: some View {
        RemoteServerSection()
    }
}

// MARK: - Local Network section

private struct LocalNetworkSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var discovery = ServerDiscoveryService()

    var body: some View {
        Group {
        Section("Local Network") {
            if discovery.servers.isEmpty {
                HStack(spacing: 8) {
                    if discovery.isScanning {
                        ProgressView().controlSize(.small)
                        Text("Scanning…").foregroundStyle(.secondary)
                    } else {
                        Text("No servers found").foregroundStyle(.secondary)
                    }
                }
            } else {
                ForEach(discovery.servers) { server in
                    Button {
                        selectServer(server)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(server.displayName).fontWeight(.medium)
                                Text(server.baseURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if appState.serverBaseURL == server.baseURL {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
#if os(iOS)
        Section("Pairing") {
            PairingBrowserSection()
        }
#endif
        } // Group
        .onAppear { discovery.start() }
        .onDisappear { discovery.stop() }
    }

    private func selectServer(_ server: DiscoveredServer) {
        appState.serverBaseURL = server.baseURL
        appState.serverMode    = .localNetwork
        ConfigStore.shared.serverBaseURL = server.baseURL
        ConfigStore.shared.serverMode    = .localNetwork
    }
}

// MARK: - Remote server section (hermit-jmt)

private struct RemoteServerSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var urlDraft: String = ""
    @State private var validationState: ValidationState = .idle

    enum ValidationState: Equatable {
        case idle
        case checking
        case ok
        case failed(String)
    }

    var body: some View {
        Section("Remote Server") {
            TextField("Server URL", text: $urlDraft, prompt: Text("https://hermit.example.com"))
                .autocorrectionDisabled()
#if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
#endif
                .onAppear {
                    if case .remote(let url) = appState.serverMode { urlDraft = url }
                }

            HStack {
                Button("Validate Connection") {
                    Task { await validate() }
                }
                .disabled(urlDraft.isEmpty || validationState == .checking)

                switch validationState {
                case .idle:    EmptyView()
                case .checking: ProgressView().controlSize(.small)
                case .ok:
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failed(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
            }
        }
    }

    private var isChecking: Bool {
        if case .checking = validationState { return true }
        return false
    }

    private func validate() async {
        validationState = .checking
        let base = urlDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/api/v1/health") else {
            validationState = .failed("Invalid URL")
            return
        }
        do {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("Bearer \(appState.pat)", forHTTPHeaderField: "Authorization")
            let (_, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                validationState = .failed("Server returned error")
                return
            }
            // Success — persist
            appState.serverBaseURL = base
            appState.serverMode    = .remote(url: base)
            ConfigStore.shared.serverBaseURL = base
            ConfigStore.shared.serverMode    = .remote(url: base)
            validationState = .ok
        } catch {
            validationState = .failed(error.localizedDescription)
        }
    }
}

// MARK: - Repository location row (macOS, sandbox bookmark)

#if os(macOS)
private struct RepositoryLocationRow: View {
    @State private var bookmarkPath: String? = nil
    @State private var errorMessage: String? = nil

    var body: some View {
        Group {
            LabeledContent("Repository") {
                HStack(spacing: 8) {
                    if let path = bookmarkPath {
                        Text((path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("Not set")
                            .foregroundStyle(.tertiary)
                    }
                    Button("Change…") { pickFolder() }
                        .buttonStyle(.borderless)
                }
            }
            if let err = errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
        .onAppear {
            if let url = BookmarkStore.shared.resolve() {
                bookmarkPath = url.path
                BookmarkStore.shared.stopAccessing()
            }
        }
    }

    private func pickFolder() {
        Task { @MainActor in
            do {
                let config = try GiteaAutoConfig.promptAndDetect()
                // resolvedFrom is the path to hermit.yaml; strip two components to get repo root
                let repoRoot = ((config.resolvedFrom as NSString)
                    .deletingLastPathComponent   // drops "hermit.yaml"
                    as NSString)
                    .deletingLastPathComponent   // drops "config/"
                bookmarkPath = (repoRoot as NSString).abbreviatingWithTildeInPath
                errorMessage = nil
                // hermit-9ds: no live server restart — post notification so SettingsView
                // shows the "quit and relaunch" banner.
                NotificationCenter.default.post(name: .hermitRestartRequired, object: nil)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
#endif

// MARK: - Paired devices section (macOS, hermit-1ow)

#if os(macOS)
private struct PairedDevicesSection: View {
    @StateObject private var store = PairedTokenStore.shared
    @StateObject private var advertiser = PairingAdvertiser()
    @State private var showAdvertising = false

    var body: some View {
        if store.pairedDevices.isEmpty {
            Text("No paired devices").foregroundStyle(.secondary)
        } else {
            ForEach(Array(store.pairedDevices.keys), id: \.self) { name in
                HStack {
                    Label(name, systemImage: "ipad")
                    Spacer()
                    Button("Revoke", role: .destructive) {
                        store.revoke(peerName: name)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                }
            }
        }

        Button(showAdvertising ? "Stop Advertising" : "Pair New Device…") {
            if showAdvertising {
                advertiser.stop()
                showAdvertising = false
            } else {
                advertiser.start()
                showAdvertising = true
            }
        }

        if showAdvertising {
            if let invite = advertiser.pendingInvitation {
                HStack {
                    Image(systemName: "ipad.badge.plus")
                    Text("\(invite.peerName) wants to connect")
                    Spacer()
                    Button("Accept") { invite.accept() }.buttonStyle(.borderedProminent)
                    Button("Decline", role: .destructive) { invite.decline() }
                }
                .padding(.vertical, 4)
            } else if !advertiser.pairingStatus.isEmpty {
                Text(advertiser.pairingStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif

// MARK: - Pairing browser section (iOS, hermit-1ow)

#if os(iOS)
private struct PairingBrowserSection: View {
    @EnvironmentObject private var browser: PairingBrowser

    var body: some View {
        if browser.isPaired {
            Label("Paired", systemImage: "checkmark.shield.fill")
                .foregroundStyle(.green)
        } else {
            if !browser.discoveredMacs.isEmpty {
                ForEach(browser.discoveredMacs, id: \.displayName) { peer in
                    Button("Pair with \(peer.displayName)…") { browser.invite(peer: peer) }
                }
            } else {
                Text("Scanning for Macs…").foregroundStyle(.secondary)
            }

            if !browser.pairingStatus.isEmpty {
                Text(browser.pairingStatus).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
#endif

// MARK: - AI tab

private struct AISettingsTab: View {
    @State private var openAIKey: String = KeychainHelper.shared.openAIKey ?? ""
    @State private var provider: String = ConfigStore.shared.aiProvider ?? "apple"

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $provider) {
                    Text("Apple Intelligence (on-device)").tag("apple")
                    Text("OpenAI (GPT-4o)").tag("openai")
                }
                .onChange(of: provider) { _, new in
                    ConfigStore.shared.aiProvider = new
                }
            }
            if provider == "openai" {
                Section("OpenAI") {
                    SecureField("API Key", text: $openAIKey)
                        .onSubmit { KeychainHelper.shared.openAIKey = openAIKey.isEmpty ? nil : openAIKey }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AppState remote URL helper

private extension AppState {
    /// Extracts the URL string from a .remote mode, or "" otherwise.
    var remoteURL: String {
        if case .remote(let url) = serverMode { return url }
        return ""
    }
}
