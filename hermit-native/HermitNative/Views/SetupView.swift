import SwiftUI

/// First-run onboarding screen.
/// Prompts the user to enter a GitHub Personal Access Token, validates it
/// against the GitHub API, and stores it in the Keychain on success.
struct SetupView: View {
    @EnvironmentObject private var appState: AppState

    @State private var pat: String = ""
    @State private var isValidating = false
    @State private var errorMessage: String? = nil
    @FocusState private var patFieldFocused: Bool

    var body: some View {
        VStack(spacing: 24) {
            // Header
            VStack(spacing: 8) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                Text("Welcome to Hermit")
                    .font(.title2).bold()
                Text("Enter a GitHub Personal Access Token to get started.\nThe token needs **repo** and **read:user** scopes.")
                    .multilineTextAlignment(.center)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            // PAT input
            VStack(alignment: .leading, spacing: 6) {
                Text("Personal Access Token")
                    .font(.caption).bold()
                    .foregroundStyle(.secondary)
                SecureField("ghp_…", text: $pat)
                    .textContentType(.password)
                    .focused($patFieldFocused)
#if os(macOS)
                    .textFieldStyle(.roundedBorder)
#endif
                    .autocorrectionDisabled()
                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            // Validate button
            Button(action: validate) {
                if isValidating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text("Connect to GitHub")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pat.trimmingCharacters(in: .whitespaces).isEmpty || isValidating)

            // Help link
            Link("How to create a PAT →",
                 destination: URL(string: "https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens")!)
                .font(.caption)
        }
        .padding(32)
#if os(macOS)
        .frame(width: 380)
#endif
        .onAppear { patFieldFocused = true }
    }

    // MARK: - Validation

    private func validate() {
        let token = pat.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return }
        isValidating = true
        errorMessage = nil

        Task {
            do {
                try await GitHubAuthValidator.validate(pat: token)
                KeychainHelper.shared.pat = token
                await MainActor.run {
                    appState.isAuthenticated = true
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isValidating = false
                }
            }
        }
    }
}

// MARK: - GitHub PAT validator

/// Validates a PAT by hitting GET /user and checking for a 200 response.
enum GitHubAuthValidator {
    enum ValidationError: LocalizedError {
        case invalidToken
        case networkError(Error)
        case unexpectedResponse(Int)

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return "Token is invalid or lacks required scopes (repo, read:user)."
            case .networkError(let underlying):
                return "Network error: \(underlying.localizedDescription)"
            case .unexpectedResponse(let code):
                return "Unexpected response from GitHub (HTTP \(code))."
            }
        }
    }

    static func validate(pat: String) async throws {
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(pat)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

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
        case 200:
            return
        case 401, 403:
            throw ValidationError.invalidToken
        default:
            throw ValidationError.unexpectedResponse(http.statusCode)
        }
    }
}

// Preview available in Xcode canvas only.
// #Preview { SetupView().environmentObject(AppState()) }
