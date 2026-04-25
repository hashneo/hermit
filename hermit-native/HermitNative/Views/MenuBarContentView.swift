import SwiftUI

/// macOS menu bar popover — compact RFC list.
/// Selecting an RFC opens a full standalone window via RFCViewerWindowManager.
struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.isAuthenticated {
            MenuBarRFCListView()
        } else {
            SetupView()
        }
    }
}

#if os(macOS)
struct MenuBarRFCListView: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var store = RFCStore()
    @State private var searchText = ""

    var filtered: [RFC] {
        guard !searchText.isEmpty else { return store.rfcs }
        return store.rfcs.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
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
                                // Close the menu bar popover first, then open the window
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
        .task {
            if let client = appState.makeAPIClient() {
                store.configure(client: client, config: GitHubAPIClient.Config(
                    baseURL:  appState.baseURL,
                    owner:    appState.repoOwner,
                    repo:     appState.repoName,
                    docsPath: appState.docsPath,
                    rfcLabel: appState.rfcLabel,
                    pat:      appState.pat
                ))
            }
            await store.load()
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
