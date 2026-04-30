import SwiftUI

/// First-run onboarding screen.
///
/// Collects the Hermit server URL, GitHub PAT, and repository details.
/// If non-secret config is already present in ConfigStore (e.g. after
/// `make dev NO_KEYCHAIN=1`), pre-fills the fields and collapses the form
/// to show only the PAT entry.
struct SetupView: View {
    @EnvironmentObject private var appState: AppState

    @State private var serverURL:  String = ""
    @State private var owner:      String = ""
    @State private var repo:       String = ""
    @State private var docsPath:   String = "docs-cms/rfcs"
    @State private var pat:        String = ""
    @State private var isWorking   = false
    @State private var statusMessage: StatusMessage? = nil
    @State private var showSettings = false
    @FocusState private var patFieldFocused: Bool

    /// True when all non-PAT fields are already filled from ConfigStore.
    private var isPATOnly: Bool {
        !serverURL.isEmpty && !owner.isEmpty && !repo.isEmpty
    }

    var body: some View {
        NavigationStack {
            setupBody
#if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
                .sheet(isPresented: $showSettings) {
                    NavigationStack {
                        SettingsView()
                            .environmentObject(appState)
                            .navigationTitle("Settings")
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Done") { showSettings = false }
                                }
                            }
                    }
                }
#endif
        }
        .onAppear { prefill() }
    }

    // MARK: - Pre-fill from ConfigStore

    private func prefill() {
        let cs = ConfigStore.shared
        if serverURL.isEmpty { serverURL = cs.serverBaseURL ?? cs.baseURL ?? "" }
        if owner.isEmpty     { owner     = cs.repoOwner ?? "" }
        if repo.isEmpty      { repo      = cs.repoName  ?? "" }
        if docsPath == "docs-cms/rfcs" || docsPath.isEmpty {
            docsPath = cs.docsPath ?? "docs-cms/rfcs"
        }
        // Auto-focus the PAT field when everything else is ready.
        if isPATOnly { patFieldFocused = true }
    }

    private var setupBody: some View {
        VStack(spacing: 24) {
            // ── Header ────────────────────────────────────────────────────
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Welcome to Hermit")
                    .font(.title2).bold()
                Text(isPATOnly
                     ? "Enter your personal access token to connect."
                     : "Connect to a Hermit server to start reviewing RFCs.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // ── Form ──────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                if isPATOnly {
                    // Summarise the pre-filled config so the user can verify it.
                    VStack(alignment: .leading, spacing: 4) {
                        configSummaryRow(label: "Server", value: serverURL)
                        configSummaryRow(label: "Repo",   value: "\(owner)/\(repo)")
                        configSummaryRow(label: "Docs",   value: docsPath)
                        Button("Change…") {
                            // Clear pre-fill so full form re-appears.
                            serverURL = ""; owner = ""; repo = ""
                        }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    field("Hermit Server URL",
                          placeholder: "http://localhost:8765 or https://hermit.example.com",
                          text: $serverURL)

                    HStack(spacing: 8) {
                        field("Owner", placeholder: "org-or-user", text: $owner)
                        field("Repo",  placeholder: "my-repo",     text: $repo)
                    }
                    field("Docs Path", placeholder: "docs-cms/rfcs", text: $docsPath)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Personal Access Token")
                        .font(.caption).bold().foregroundStyle(.secondary)
                    SecureField("token…", text: $pat)
                        .textContentType(.password)
                        .focused($patFieldFocused)
#if os(macOS)
                        .textFieldStyle(.roundedBorder)
#endif
                        .autocorrectionDisabled()
                }
            }

            // ── Status message ────────────────────────────────────────────
            if let msg = statusMessage {
                Label(msg.text, systemImage: msg.isError ? "xmark.circle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(msg.isError ? Color.red : Color.green)
            }

            // ── Connect button ────────────────────────────────────────────
            Button(action: connect) {
                if isWorking {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect").frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(serverURL.isEmpty || pat.isEmpty || owner.isEmpty || repo.isEmpty || isWorking)
        }
        .padding(32)
#if os(macOS)
        .frame(width: 420)
#endif
    }   // end setupBody

    @ViewBuilder
    private func configSummaryRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":")
                .font(.caption).bold().foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }

    // MARK: - Connect

    private func connect() {
        let url    = serverURL.trimmingCharacters(in: .whitespaces)
        let token  = pat.trimmingCharacters(in: .whitespaces)
        let ownerT = owner.trimmingCharacters(in: .whitespaces)
        let repoT  = repo.trimmingCharacters(in: .whitespaces)
        let docs   = docsPath.trimmingCharacters(in: .whitespaces)
        guard !url.isEmpty, !token.isEmpty, !ownerT.isEmpty, !repoT.isEmpty else { return }

        isWorking = true
        statusMessage = nil

        Task {
            do {
                try await HermitServerValidator.validate(serverURL: url, pat: token)
                // Store non-secret config in UserDefaults, PAT in Keychain.
                let repoConfig = ConfigStore.RepoConfig(
                    baseURL:  url,
                    owner:    ownerT,
                    repo:     repoT,
                    docsPath: docs.isEmpty ? "docs-cms/rfcs" : docs,
                    rfcLabel: "hermit:rfc-ready"
                )
                ConfigStore.shared.apply(repoConfig)
                ConfigStore.shared.serverBaseURL = url
                ConfigStore.shared.serverMode    = .embeddedLocal
                // Find an existing connection for this endpoint or create a new one.
                let store = AccountStore.shared
                if let existing = store.connections.first(where: { $0.endpoint == url }) {
                    store.update(existing, token: token)
                } else {
                    store.add(name: url, endpoint: url, token: token)
                }
                await MainActor.run {
                    appState.applyConfig()
                }
            } catch {
                await MainActor.run {
                    statusMessage = StatusMessage(text: error.localizedDescription, isError: true)
                    isWorking = false
                }
            }
        }
    }

    // MARK: - Field builder

    @ViewBuilder
    private func field(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).bold().foregroundStyle(.secondary)
            TextField(placeholder, text: text)
                .autocorrectionDisabled()
#if os(macOS)
                .textFieldStyle(.roundedBorder)
#endif
        }
    }

    struct StatusMessage {
        let text: String
        let isError: Bool
    }
}

// MARK: - Hermit server validator

/// Validates connectivity to the Hermit server by hitting GET /health.
enum HermitServerValidator {
    enum ValidationError: LocalizedError {
        case invalidURL
        case unauthorized
        case networkError(Error)
        case unexpectedResponse(Int)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL."
            case .unauthorized:
                return "Token rejected by server (HTTP 401). Check your GitHub PAT."
            case .networkError(let e):
                return "Could not reach server: \(e.localizedDescription)"
            case .unexpectedResponse(let code):
                return "Unexpected response from server (HTTP \(code))."
            }
        }
    }

    static func validate(serverURL: String, pat: String) async throws {
        let base = serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/health") else {
            throw ValidationError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 10

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw ValidationError.networkError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ValidationError.unexpectedResponse(-1)
        }
        switch http.statusCode {
        case 200:      return
        case 401, 403: throw ValidationError.unauthorized
        default:       throw ValidationError.unexpectedResponse(http.statusCode)
        }
    }
}
