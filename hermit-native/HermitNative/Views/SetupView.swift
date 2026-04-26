import SwiftUI

/// First-run onboarding screen.
///
/// Collects the Hermit server URL, GitHub PAT, and repository details.
/// All GitHub interactions go through the Hermit Go backend — no direct
/// GitHub API calls are made from the native client.
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
                Text("Connect to a Hermit server to start reviewing RFCs.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // ── Form ──────────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 12) {
                field("Hermit Server URL",
                      placeholder: "http://localhost:8765 or https://hermit.example.com",
                      text: $serverURL)

                HStack(spacing: 8) {
                    field("Owner", placeholder: "org-or-user", text: $owner)
                    field("Repo",  placeholder: "my-repo",     text: $repo)
                }
                field("Docs Path", placeholder: "docs-cms/rfcs", text: $docsPath)

                VStack(alignment: .leading, spacing: 4) {
                    Text("GitHub Personal Access Token")
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
                KeychainHelper.shared.pat = token
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
