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

// MARK: - MultiRepoRFCLoader

/// Loads RFCs for every registered repository concurrently.
/// Observed by MenuBarRFCListView to populate per-repo sections.
#if os(macOS)
@MainActor
final class MultiRepoRFCLoader: ObservableObject {
    struct RepoRFCs: Identifiable {
        let repo: Repository
        let rfcs: [RFC]
        var id: UUID { repo.id }
    }

    @Published private(set) var sections:   [RepoRFCs] = []
    @Published private(set) var isLoading:  Bool       = false
    @Published private(set) var errorByRepo: [UUID: String] = [:]

    func load(appState: AppState) async {
        let repos = RepositoryStore.shared.repositories
        guard !repos.isEmpty else { return }
        isLoading = true
        errorByRepo = [:]

        var results: [RepoRFCs] = []
        await withTaskGroup(of: (Repository, [RFC], String?).self) { group in
            for repo in repos {
                group.addTask {
                    guard let client = await appState.makeAPIClient(for: repo) else {
                        return (repo, [], "No API client")
                    }
                    do {
                        let (mainRFCs, prs) = try await client.discoverRFCs()
                        var rfcs: [RFC] = mainRFCs.map {
                            RFC(id: $0.id, title: $0.name, path: $0.path, sha: $0.sha, source: .mainBranch)
                        }
                        for pr in prs {
                            rfcs.append(RFC(id: "pr-\(pr.id)", title: pr.title,
                                            path: pr.headRef, sha: pr.headSHA,
                                            source: .pullRequest(pr)))
                        }
                        return (repo, rfcs.sorted { $0.title < $1.title }, nil)
                    } catch {
                        return (repo, [], error.localizedDescription)
                    }
                }
            }
            for await (repo, rfcs, err) in group {
                results.append(RepoRFCs(repo: repo, rfcs: rfcs))
                if let err { errorByRepo[repo.id] = err }
            }
        }
        // Preserve original repo order.
        sections = repos.compactMap { repo in results.first { $0.repo.id == repo.id } }
        isLoading = false
    }
}

// MARK: - MenuBarRFCListView

struct MenuBarRFCListView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var advertiser   = PairingAdvertiser.shared
    @ObservedObject private var recentStore  = RecentRFCStore.shared
    @ObservedObject private var repoStore    = RepositoryStore.shared
    @ObservedObject private var serverMgr    = EmbeddedServerManager.shared
    @StateObject   private var loader        = MultiRepoRFCLoader()
    @State private var searchText = ""

    /// Key that triggers a reload when the server restarts or repos change.
    private var loadKey: String {
        let port  = serverMgr.port.map(String.init) ?? "down"
        let repos = repoStore.repositories.map(\.id.uuidString).joined(separator: ",")
        return "\(port)-\(repos)"
    }

    /// All RFCs across all repos, flattened — used for search results.
    private var allRFCs: [(rfc: RFC, repo: Repository)] {
        loader.sections.flatMap { s in s.rfcs.map { ($0, s.repo) } }
    }

    private var filteredAll: [(rfc: RFC, repo: Repository)] {
        guard !searchText.isEmpty else { return [] }
        return allRFCs.filter { $0.rfc.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Pending pairing invitation ────────────────────────────────
            if let invite = advertiser.pendingInvitation {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "ipad")
                            .foregroundStyle(Color.accentColor)
                        Text("\(invite.peerName) wants to pair")
                            .font(.subheadline).fontWeight(.medium)
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Button("Deny")  { invite.decline() }.buttonStyle(.bordered).tint(.red)
                        Button("Allow") { invite.accept()  }.buttonStyle(.borderedProminent).tint(.green)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(12)
                .background(Color.accentColor.opacity(0.08))
                Divider()
            }

            // ── Toolbar ───────────────────────────────────────────────────
            HStack {
                Text("Hermit").font(.headline)
                Spacer()
                if loader.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await loader.load(appState: appState) } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.plain).help("Refresh")
                }
                Button { SettingsWindowManager.shared.open() } label: {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain).help("Settings")
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()

            // ── Search ────────────────────────────────────────────────────
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search RFCs…", text: $searchText).textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            // ── Content ───────────────────────────────────────────────────
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !searchText.isEmpty {
                        // ── Search results (flat) ─────────────────────────
                        if filteredAll.isEmpty {
                            Text("No results")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(filteredAll, id: \.rfc.id) { pair in
                                MenuBarRFCRow(rfc: pair.rfc) { open(pair.rfc, repo: pair.repo) }
                                Divider().padding(.leading, 12)
                            }
                        }
                    } else {
                        // ── Recents ───────────────────────────────────────
                        if !recentStore.recents.isEmpty {
                            MenuBarSectionHeader(title: "Recent")
                            ForEach(recentStore.recents) { entry in
                                MenuBarRecentRow(entry: entry) {
                                    openRecent(entry)
                                }
                                Divider().padding(.leading, 12)
                            }
                            Divider().padding(.vertical, 2)
                        }

                        // ── Per-repo sections ──────────────────────────────
                        if loader.sections.isEmpty && !loader.isLoading {
                            Text("No repositories configured")
                                .font(.caption).foregroundStyle(.secondary)
                                .padding()
                                .frame(maxWidth: .infinity)
                        } else {
                            ForEach(loader.sections) { section in
                                MenuBarRepoSection(
                                    section: section,
                                    error: loader.errorByRepo[section.repo.id],
                                    onOpen: { open($0, repo: section.repo) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 320, height: 460)
        .task(id: loadKey) {
            guard serverMgr.port != nil else { return }
            await loader.load(appState: appState)
        }
    }

    // MARK: - Actions

    private func open(_ rfc: RFC, repo: Repository) {
        NSApplication.shared.keyWindow?.close()
        RecentRFCStore.shared.record(rfc, repoID: repo.id)
        RFCViewerWindowManager.shared.open(rfc: rfc, appState: appState)
    }

    private func openRecent(_ entry: RecentRFCEntry) {
        // Find the RFC in the loaded sections; fall back to a synthetic RFC if not yet loaded.
        if let pair = allRFCs.first(where: { $0.rfc.id == entry.id }) {
            open(pair.rfc, repo: pair.repo)
        } else if let repo = repoStore.repositories.first(where: { $0.id == entry.repoID })
                           ?? repoStore.repositories.first {
            // Construct a minimal RFC so the viewer can open it.
            let rfc = RFC(id: entry.id, title: entry.title, path: entry.path,
                          sha: entry.id, source: .mainBranch)
            open(rfc, repo: repo)
        }
    }
}

// MARK: - Collapsible repo section

private struct MenuBarRepoSection: View {
    let section: MultiRepoRFCLoader.RepoRFCs
    var error: String? = nil
    let onOpen: (RFC) -> Void

    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // ── Repo header row (click to expand/collapse) ─────────────
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    Text("\(section.repo.owner)/\(section.repo.name)")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if error != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .help(error ?? "")
                    }
                    Spacer()
                    Text(isExpanded ? "" : "\(section.rfcs.count)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
            }
            .buttonStyle(.plain)

            // ── RFC rows (shown when expanded) ─────────────────────────
            if isExpanded {
                if section.rfcs.isEmpty {
                    Text(error != nil ? "Failed to load" : "No RFCs")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 28).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(section.rfcs) { rfc in
                        MenuBarRFCRow(rfc: rfc, indented: true) { onOpen(rfc) }
                        Divider().padding(.leading, 28)
                    }
                }
            }

            Divider().padding(.top, 4)
        }
    }
}

// MARK: - Section header (retained for search/recents use)

private struct MenuBarSectionHeader: View {
    let title: String
    var error: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if error != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .help(error ?? "")
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 2)
    }
}

// MARK: - Recent row

private struct MenuBarRecentRow: View {
    let entry: RecentRFCEntry
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - RFC row

private struct MenuBarRFCRow: View {
    let rfc: RFC
    var indented: Bool = false
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(rfc.title)
                        .font(.subheadline).lineLimit(1).foregroundStyle(.primary)
                    Text(statusLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "arrow.up.forward.square")
                    .font(.caption).foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.leading, indented ? 28 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var statusColor: Color {
        switch rfc.source {
        case .mainBranch:            return .green
        case .pullRequest(let pr):   return pr.draft ? .gray : .orange
        }
    }

    private var statusLabel: String {
        switch rfc.source {
        case .mainBranch:            return "Published"
        case .pullRequest(let pr):   return pr.draft ? "Draft PR #\(pr.number)" : "In Review · PR #\(pr.number)"
        }
    }
}
#endif
