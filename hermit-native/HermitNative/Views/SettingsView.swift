import SwiftUI
import Network

// MARK: - SettingsView
// hermit-3wh: Server settings tab (macOS — mode selector, Bonjour list stub, remote URL)
// hermit-ogz: Server selection UI in iPad SettingsView
// hermit-jmt: Remote URL configuration and health-check validation

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.circle") }
            RepositorySettingsTab()
                .tabItem { Label("Repository", systemImage: "arrow.triangle.branch") }
            ServerSettingsTab()
                .tabItem { Label("Server", systemImage: "server.rack") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
#if os(macOS)
        .frame(width: 600, height: 560)
#endif
    }
}

// MARK: - Account tab

private struct AccountSettingsTab: View {
    @StateObject private var store = AccountStore.shared
    @State private var showAddSheet  = false
    @State private var editTarget: Connection? = nil
    @State private var revokeTarget: Connection? = nil
    @State private var selection: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            // ── Toolbar ──────────────────────────────────────────────────
            HStack {
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
                        if store.activeID == conn.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.accentColor)
                                .help("Active connection")
                        }
                        Text(conn.name)
                            .fontWeight(store.activeID == conn.id ? .semibold : .regular)
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
                .width(110)

                TableColumn("Actions") { conn in
                    HStack(spacing: 4) {
                        Menu {
                            Button("Set Active") { store.setActive(conn) }
                            Divider()
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
        .task {
            for conn in store.connections { await store.probe(conn) }
        }
    }
}

// MARK: - Connection state indicator

private struct ConnectionStateView: View {
    @StateObject private var store = AccountStore.shared
    let connection: Connection

    var body: some View {
        let connected = store.isConnected(connection)
        Label(
            connected ? "Connected" : "Disconnected",
            systemImage: connected ? "checkmark.circle.fill" : "xmark.circle.fill"
        )
        .foregroundStyle(connected ? .green : .secondary)
        .font(.subheadline)
    }
}

// MARK: - Add account sheet

private struct AddAccountSheet: View {
    @StateObject private var store = AccountStore.shared
    @Binding var isPresented: Bool

    @State private var name     = ""
    @State private var endpoint = ""
    @State private var token    = ""

    var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !endpoint.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("e.g. HashiCorp Gitea"))
                    TextField("Endpoint", text: $endpoint, prompt: Text("https://gitea.example.com"))
                        .autocorrectionDisabled()
#if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
#endif
                } header: {
                    Text("Connection")
                }
                Section("Authentication") {
                    SecureField("Personal Access Token", text: $token)
                        .textContentType(.password)
                }
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
                        store.add(
                            name: name.trimmingCharacters(in: .whitespaces),
                            endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                            token: token
                        )
                        isPresented = false
                    }
                    .disabled(!canSave)
                }
            }
        }
#if os(macOS)
        .frame(width: 420, height: 280)
#endif
    }
}

// MARK: - Edit account sheet

private struct EditAccountSheet: View {
    @StateObject private var store = AccountStore.shared
    let connection: Connection
    @Binding var isPresented: Bool

    @State private var name: String
    @State private var endpoint: String
    @State private var token: String = ""

    init(connection: Connection, isPresented: Binding<Bool>) {
        self.connection = connection
        _isPresented = isPresented
        _name     = State(initialValue: connection.name)
        _endpoint = State(initialValue: connection.endpoint)
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
}

// MARK: - Repository tab

private struct RepositorySettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = AccountStore.shared

    var body: some View {
        Table([repoRow]) {
            TableColumn("Account") { _ in
                Text(store.active?.name ?? "—")
                    .foregroundStyle(store.active == nil ? .secondary : .primary)
            }
            TableColumn("Owner") { _ in
                Text(appState.repoOwner.isEmpty ? "—" : appState.repoOwner)
                    .foregroundStyle(appState.repoOwner.isEmpty ? .secondary : .primary)
            }
            TableColumn("Repository") { _ in
                Text(appState.repoName.isEmpty ? "—" : appState.repoName)
                    .foregroundStyle(appState.repoName.isEmpty ? .secondary : .primary)
            }
            TableColumn("Actions") { _ in
                Button("Edit…") { /* handled by sheet below */ }
                    .buttonStyle(.borderless)
            }
            .width(60)
        }
        .overlay {
            // Tap anywhere on the single row opens the edit sheet — simpler than
            // threading a binding through the TableColumn closure.
            RepoEditOverlay()
                .environmentObject(appState)
        }
    }

    // The Table API requires Identifiable rows; use a trivial wrapper.
    private var repoRow: RepoRow { RepoRow() }
}

private struct RepoRow: Identifiable { let id = UUID() }

// MARK: - Repo edit overlay (sits over the table, opens sheet on row tap)

private struct RepoEditOverlay: View {
    @EnvironmentObject private var appState: AppState
    @State private var showSheet = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { showSheet = true }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { showSheet = true } label: {
                        Label("Edit Repository", systemImage: "pencil")
                    }
                }
            }
            .sheet(isPresented: $showSheet) {
                EditRepoSheet(isPresented: $showSheet)
                    .environmentObject(appState)
            }
    }
}

// MARK: - Edit repo sheet

private struct EditRepoSheet: View {
    @EnvironmentObject private var appState: AppState
    @Binding var isPresented: Bool

    @State private var ownerDraft = ""
    @State private var repoDraft  = ""
    @State private var docsDraft  = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Repository") {
                    TextField("Owner", text: $ownerDraft, prompt: Text("org-or-user"))
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                    TextField("Name", text: $repoDraft, prompt: Text("repository-name"))
                        .autocorrectionDisabled()
#if os(iOS)
                        .textInputAutocapitalization(.never)
#endif
                }
                Section("Docs Path (optional)") {
                    TextField("Path", text: $docsDraft, prompt: Text("docs-cms/rfcs"))
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
                        let o = ownerDraft.trimmingCharacters(in: .whitespaces)
                        let r = repoDraft.trimmingCharacters(in: .whitespaces)
                        let d = docsDraft.trimmingCharacters(in: .whitespaces)
                        guard !o.isEmpty, !r.isEmpty else { return }
                        appState.repoOwner = o
                        appState.repoName  = r
                        ConfigStore.shared.repoOwner = o
                        ConfigStore.shared.repoName  = r
                        if !d.isEmpty { ConfigStore.shared.docsPath = d }
                        isPresented = false
                    }
                    .disabled(
                        ownerDraft.trimmingCharacters(in: .whitespaces).isEmpty ||
                        repoDraft.trimmingCharacters(in: .whitespaces).isEmpty
                    )
                }
            }
            .onAppear {
                ownerDraft = appState.repoOwner
                repoDraft  = appState.repoName
                docsDraft  = ConfigStore.shared.docsPath ?? ""
            }
        }
#if os(macOS)
        .frame(width: 420, height: 280)
#endif
    }
}

// MARK: - Server tab (hermit-3wh / hermit-ogz / hermit-jmt)

private struct ServerSettingsTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Form {
            Section("Mode") {
                modePicker
            }

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
                EmbeddedServerManager.shared.restart()
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
