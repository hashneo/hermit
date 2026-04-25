import SwiftUI

/// macOS Settings window — Account, AI, Notifications tabs.
/// Full implementation tracked by hermit-ye7.
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.circle") }
            AISettingsTab()
                .tabItem { Label("AI", systemImage: "sparkles") }
        }
        .frame(width: 460, height: 320)
    }
}

// MARK: - Account tab

private struct AccountSettingsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var showResetConfirm = false

    var body: some View {
        Form {
            Section("GitHub") {
                LabeledContent("Authentication") {
                    if appState.isAuthenticated {
                        Label("Connected", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Not connected", systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }
                if appState.isAuthenticated {
                    Button("Remove Token…", role: .destructive) {
                        showResetConfirm = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove GitHub token?",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                KeychainHelper.shared.pat = nil
                appState.isAuthenticated = false
            }
        } message: {
            Text("You will need to enter a new token to use Hermit.")
        }
    }
}

// MARK: - AI tab

private struct AISettingsTab: View {
    @State private var openAIKey: String = KeychainHelper.shared.openAIKey ?? ""
    @State private var provider: String = KeychainHelper.shared.aiProvider ?? "apple"

    var body: some View {
        Form {
            Section("AI Provider") {
                Picker("Provider", selection: $provider) {
                    Text("Apple Intelligence (on-device)").tag("apple")
                    Text("OpenAI (GPT-4o)").tag("openai")
                }
                .onChange(of: provider) { _, new in
                    KeychainHelper.shared.aiProvider = new
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
