import SwiftUI

/// First-run onboarding screen.
/// Offers two paths:
///  1. Auto-configure from the local Hermit repo (Gitea dev instance).
///  2. Manual PAT entry for GitHub.com or any compatible host.
struct SetupView: View {
    @EnvironmentObject private var appState: AppState

    @State private var mode: Mode = .autoDetecting
    @State private var manualBaseURL: String = "https://api.github.com"
    @State private var manualOwner: String = ""
    @State private var manualRepo: String = ""
    @State private var manualDocsPath: String = "docs-cms/rfcs"
    @State private var manualPAT: String = ""
    @State private var isWorking = false
    @State private var statusMessage: StatusMessage? = nil
    @FocusState private var patFieldFocused: Bool

    enum Mode: Equatable {
        case autoDetecting
        case autoReady(GiteaAutoConfig.DetectedConfig)
        case manual
    }

    var body: some View {
        VStack(spacing: 24) {
            // ── Header ────────────────────────────────────────────────────
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Welcome to Hermit")
                    .font(.title2).bold()
                Text("Connect to a Gitea or GitHub repository of RFCs.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // ── Auto-config banner ────────────────────────────────────────
            if case .autoReady(let detected) = mode {
                AutoConfigBanner(detected: detected) {
                    apply(detected)
                }
            }

            // ── Manual form ───────────────────────────────────────────────
            if case .manual = mode {
                ManualConfigForm(
                    baseURL:   $manualBaseURL,
                    owner:     $manualOwner,
                    repo:      $manualRepo,
                    docsPath:  $manualDocsPath,
                    pat:       $manualPAT,
                    focused:   $patFieldFocused
                )
            }

            // ── Status message ────────────────────────────────────────────
            if let msg = statusMessage {
                Label(msg.text, systemImage: msg.isError ? "xmark.circle" : "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(msg.isError ? Color.red : Color.green)
            }

            // ── Actions ───────────────────────────────────────────────────
            VStack(spacing: 10) {
                if case .manual = mode {
                    Button(action: validateManual) {
                        label("Connect", isWorking: isWorking)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(manualPAT.isEmpty || manualOwner.isEmpty || manualRepo.isEmpty || isWorking)
                }

                if case .autoReady = mode {} else {
                    Button(action: { withAnimation { mode = .manual } }) {
                        Text(mode == .manual ? "↩ Back to auto-detect" : "Configure manually →")
                            .font(.subheadline)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                }
            }
        }
        .padding(32)
#if os(macOS)
        .frame(width: 420)
#endif
        .task { await autoDetect() }
    }

    // MARK: - Auto-detect

    private func autoDetect() async {
        do {
            let detected = try GiteaAutoConfig.detect()
#if DEBUG
            // In debug builds skip the banner and connect immediately —
            // no Keychain write, no network validation round-trip.
            await MainActor.run {
                appState.apply(detected)
            }
#else
            await MainActor.run {
                mode = .autoReady(detected)
            }
#endif
        } catch {
            // Not on a dev machine with Gitea — fall through to manual
            await MainActor.run {
                mode = .manual
            }
        }
    }

    // MARK: - Apply auto config (release path — writes to Keychain)

    private func apply(_ detected: GiteaAutoConfig.DetectedConfig) {
        isWorking = true
        statusMessage = nil
        Task {
            do {
                try await GitHubAuthValidator.validate(
                    baseURL: detected.baseURL,
                    pat:     detected.pat
                )
                KeychainHelper.shared.apply(detected.toRepoConfig())
                await MainActor.run {
                    appState.applyKeychain()
                }
            } catch {
                await MainActor.run {
                    statusMessage = StatusMessage(text: error.localizedDescription, isError: true)
                    isWorking = false
                }
            }
        }
    }

    // MARK: - Manual validation

    private func validateManual() {
        let token   = manualPAT.trimmingCharacters(in: .whitespaces)
        let baseURL = manualBaseURL.trimmingCharacters(in: .whitespaces)
        let owner   = manualOwner.trimmingCharacters(in: .whitespaces)
        let repo    = manualRepo.trimmingCharacters(in: .whitespaces)
        let docs    = manualDocsPath.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty, !baseURL.isEmpty, !owner.isEmpty, !repo.isEmpty else { return }

        isWorking = true
        statusMessage = nil

        Task {
            do {
                try await GitHubAuthValidator.validate(baseURL: baseURL, pat: token)
                let config = KeychainHelper.RepoConfig(
                    baseURL:  baseURL,
                    pat:      token,
                    owner:    owner,
                    repo:     repo,
                    docsPath: docs.isEmpty ? "docs-cms/rfcs" : docs,
                    rfcLabel: "hermit:rfc-ready"
                )
                KeychainHelper.shared.apply(config)
                await MainActor.run {
                    appState.applyKeychain()
                }
            } catch {
                await MainActor.run {
                    statusMessage = StatusMessage(text: error.localizedDescription, isError: true)
                    isWorking = false
                }
            }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func label(_ text: String, isWorking: Bool) -> some View {
        if isWorking {
            ProgressView().controlSize(.small)
        } else {
            Text(text).frame(maxWidth: .infinity)
        }
    }

    struct StatusMessage {
        let text: String
        let isError: Bool
    }
}

// MARK: - Auto-config banner

private struct AutoConfigBanner: View {
    let detected: GiteaAutoConfig.DetectedConfig
    let onConnect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Local Gitea instance detected", systemImage: "checkmark.seal.fill")
                .font(.subheadline).bold()
                .foregroundStyle(.green)

            VStack(alignment: .leading, spacing: 4) {
                row("API", detected.baseURL)
                row("Repo", "\(detected.owner)/\(detected.repo)")
                row("Docs path", detected.docsPath)
                row("Token", String(detected.pat.prefix(8)) + "••••••••")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Button(action: onConnect) {
                Text("Connect to Local Gitea")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.green.opacity(0.25), lineWidth: 1))
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("\(label):").bold().frame(width: 65, alignment: .leading)
            Text(value).foregroundStyle(.primary)
        }
    }
}

// MARK: - Manual config form

private struct ManualConfigForm: View {
    @Binding var baseURL: String
    @Binding var owner: String
    @Binding var repo: String
    @Binding var docsPath: String
    @Binding var pat: String
    var focused: FocusState<Bool>.Binding

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            field("API Base URL",  placeholder: "https://api.github.com",  text: $baseURL)
            HStack(spacing: 8) {
                field("Owner", placeholder: "org-or-user", text: $owner)
                field("Repo",  placeholder: "my-repo",     text: $repo)
            }
            field("Docs Path", placeholder: "docs-cms/rfcs", text: $docsPath)
            VStack(alignment: .leading, spacing: 4) {
                Text("Personal Access Token").font(.caption).bold().foregroundStyle(.secondary)
                SecureField("token…", text: $pat)
                    .textContentType(.password)
                    .focused(focused)
#if os(macOS)
                    .textFieldStyle(.roundedBorder)
#endif
                    .autocorrectionDisabled()
            }
        }
    }

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
}

// MARK: - Auth validator (base-URL-aware)

enum GitHubAuthValidator {
    enum ValidationError: LocalizedError {
        case invalidToken
        case networkError(Error)
        case unexpectedResponse(Int)

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return "Token is invalid or lacks required scopes."
            case .networkError(let e):
                return "Network error: \(e.localizedDescription)"
            case .unexpectedResponse(let code):
                return "Unexpected response from server (HTTP \(code))."
            }
        }
    }

    /// Validates a token by calling GET /user on the given base URL.
    /// Works for both GitHub.com (https://api.github.com) and
    /// Gitea (http://localhost:3000/api/v1).
    static func validate(baseURL: String, pat: String) async throws {
        let base = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: "\(base)/user") else {
            throw ValidationError.unexpectedResponse(-1)
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

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
        case 401, 403: throw ValidationError.invalidToken
        default:       throw ValidationError.unexpectedResponse(http.statusCode)
        }
    }
}
