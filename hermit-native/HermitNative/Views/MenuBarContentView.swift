import SwiftUI

/// macOS menu bar popover — compact RFC list.
/// Selecting an RFC opens a full standalone window via RFCViewerWindowManager.
struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
#if os(macOS)
        if appState.isAuthenticated {
            MenuBarRFCListView()
        } else if appState.needsPATOnly {
            MenuBarPATPromptView()
        } else {
            SetupView()
        }
#endif
    }
}

// MARK: - AppState convenience

extension AppState {
    /// True when server URL, owner, and repo are all configured but the PAT is absent.
    /// Used by MenuBarContentView to show the focused PAT-only prompt instead of full SetupView.
    var needsPATOnly: Bool {
        !serverBaseURL.isEmpty && !repoOwner.isEmpty && !repoName.isEmpty && pat.isEmpty
    }
}

// MARK: - PAT-only prompt

#if os(macOS)
struct MenuBarPATPromptView: View {
    @EnvironmentObject private var appState: AppState

    @State private var pat: String = ""
    @State private var isValidating = false
    @State private var errorMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Enter your Gitea PAT")
                    .font(.headline)
                Text("Everything else is configured. Paste your Gitea personal access token to connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("\(appState.repoOwner)/\(appState.repoName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appState.serverBaseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SecureField("Personal access token", text: $pat)
                .textFieldStyle(.roundedBorder)

            if let err = errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button(action: connect) {
                if isValidating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(pat.isEmpty || isValidating)
        }
        .padding(16)
        .frame(width: 300)
    }

    private func connect() {
        isValidating = true
        errorMessage = nil
        let serverURL = appState.serverBaseURL
        let enteredPAT = pat

        Task {
            do {
                try await HermitServerValidator.validate(serverURL: serverURL, pat: enteredPAT)
                // Write the PAT into the first account (Keychain in release, UserDefaults in debug).
                if let conn = AccountStore.shared.connections.first {
                    AccountStore.shared.update(conn, token: enteredPAT)
                }
                await MainActor.run {
                    appState.pat = enteredPAT
                    appState.isAuthenticated = true
                    isValidating = false
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
#endif

#if os(macOS)
struct MenuBarRFCListView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var advertiser = PairingAdvertiser.shared
    @StateObject private var store = RFCStore()
    @State private var searchText = ""

    var filtered: [RFC] {
        guard !searchText.isEmpty else { return store.rfcs }
        return store.rfcs.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Pending pairing invitation ─────────────────────────────────
            if let invite = advertiser.pendingInvitation {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "ipad")
                            .foregroundStyle(Color.accentColor)
                        Text("\(invite.peerName) wants to pair")
                            .font(.subheadline)
                            .fontWeight(.medium)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button("Deny") { invite.decline() }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        Button("Allow") { invite.accept() }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }

            // ── Toolbar ───────────────────────────────────────────────────
            HStack {
                Text("Hermit")
                    .font(.headline)
                Spacer()
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await store.load() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
                Button {
                    SettingsWindowManager.shared.open()
                } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // ── Search ────────────────────────────────────────────────────
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search RFCs…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // ── List ──────────────────────────────────────────────────────
            if store.rfcs.isEmpty && !store.isLoading {
                if let err = store.errorMessage {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                        .multilineTextAlignment(.center)
                } else {
                    Text("No RFCs found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { rfc in
                            MenuBarRFCRow(rfc: rfc) {
                                NSApplication.shared.keyWindow?.close()
                                RFCViewerWindowManager.shared.open(rfc: rfc, appState: appState)
                            }
                            Divider().padding(.leading, 12)
                        }
                    }
                }
            }
        }
        .frame(width: 300, height: 420)
        .task(id: appState.serverBaseURL) {
            guard !appState.serverBaseURL.isEmpty else { return }
            if let client = appState.makeAPIClient() {
                store.configure(client: client, docsPath: appState.docsPath)
            }
            await store.load()
        }
        // hermit-z9j/txn: open RFC window when a Handoff or deep-link arrives
        .onChange(of: store.rfcs) { _, rfcs in
            // Handoff continuation
            if let rfcID = appState.pendingHandoffRFCID,
               let rfc = rfcs.first(where: { $0.id == rfcID }) {
                appState.pendingHandoffRFCID = nil
                appState.pendingHandoffLine  = nil
                RFCViewerWindowManager.shared.open(rfc: rfc, appState: appState)
            }
            // hermit-txn: deep link
            if let path = appState.pendingDeepLinkPath,
               let rfc = rfcs.first(where: { $0.path == path }) {
                appState.pendingDeepLinkPath = nil
                RFCViewerWindowManager.shared.open(rfc: rfc, appState: appState)
            }
        }
    }
}

private struct MenuBarRFCRow: View {
    let rfc: RFC
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 2) {
                    Text(rfc.title)
                        .font(.subheadline)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Text(statusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var statusColor: Color {
        switch rfc.source {
        case .mainBranch:        return .green
        case .pullRequest(let pr): return pr.draft ? .gray : .orange
        }
    }

    private var statusLabel: String {
        switch rfc.source {
        case .mainBranch:          return "Published"
        case .pullRequest(let pr): return pr.draft ? "Draft PR #\(pr.number)" : "In Review · PR #\(pr.number)"
        }
    }
}
#endif
