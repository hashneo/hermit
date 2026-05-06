import SwiftUI

// MARK: - MenuBarContentView
// Native .menu style — renders as real NSMenu items.
// Each repo gets its own submenu that loads RFCs lazily when first opened.

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
#if os(macOS)
    @ObservedObject private var serverMgr  = EmbeddedServerManager.shared
    @ObservedObject private var repoStore  = RepositoryStore.shared
    @ObservedObject private var advertiser = PairingAdvertiser.shared
#endif

#if os(macOS)
    var body: some View {
        // ── Pairing invitation ─────────────────────────────────────────
        if let invite = advertiser.pendingInvitation {
            Text("\(invite.peerName) wants to pair")
            Button("Allow") { invite.accept()  }
            Button("Deny")  { invite.decline() }
            Divider()
        }

        // ── Server status ──────────────────────────────────────────────
        if let port = serverMgr.port {
            Text("Server running · port \(port)")
        } else if serverMgr.errorMessage != nil {
            Text("Server error — check Settings")
        } else {
            Text("Server starting…")
        }

        Divider()

        // ── Per-repo submenus ──────────────────────────────────────────
        if repoStore.repositories.isEmpty {
            Text("No repositories configured")
        } else {
            ForEach(repoStore.repositories) { repo in
                RepoSubmenu(repo: repo, appState: appState, serverPort: serverMgr.port)
            }
        }

        Divider()

        // ── Actions ────────────────────────────────────────────────────
        Button("Settings…") {
            SettingsWindowManager.shared.open()
        }
        .keyboardShortcut(",")

        Button("Refresh All") {
            RepoRFCCache.shared.invalidateAll()
        }

        Divider()

        Button("Quit Hermit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
#else
    var body: some View { EmptyView() }
#endif
}

// MARK: - Per-repo submenu

/// A `Menu` item whose RFC list is loaded lazily on first appearance.
/// Subsequent opens use the cache and are instant.
#if os(macOS)
private struct RepoSubmenu: View {
    let repo: Repository
    let appState: AppState
    let serverPort: Int?

    @StateObject private var loader = RepoRFCLoader()

    var body: some View {
        Menu(repo.fullName) {
            repoMenuContent
        }
        .task(id: serverPort) {
            guard serverPort != nil else { return }
            await loader.loadIfNeeded(repo: repo, appState: appState)
        }
    }

    @ViewBuilder
    private var repoMenuContent: some View {
        switch loader.state {
        case .idle, .loading:
            Text("Loading…")

        case .loaded(let sections):
            if sections.mainBranch.isEmpty && sections.pullRequests.isEmpty {
                Text("No RFCs")
            } else {
                if !sections.pullRequests.isEmpty {
                    Text("In Review")
                    ForEach(sections.pullRequests) { rfc in
                        Button {
                            open(rfc)
                        } label: {
                            Label(rfc.title, systemImage: "arrow.triangle.pull")
                        }
                    }
                }
                if !sections.mainBranch.isEmpty {
                    if !sections.pullRequests.isEmpty { Divider() }
                    let grouped = RFCStatusGroup.group(sections.mainBranch)
                    ForEach(grouped, id: \.header) { group in
                        if !group.rfcs.isEmpty {
                            Text(group.header)
                            ForEach(group.rfcs) { rfc in
                                Button { open(rfc) } label: {
                                    Label(rfc.title, systemImage: group.systemImage)
                                }
                            }
                        }
                    }
                }
            }

        case .failed(let msg):
            Text("Failed to load")
            Text(msg).foregroundStyle(.secondary)
        }

        Divider()
        Button("Refresh") {
            Task { await loader.reload(repo: repo, appState: appState) }
        }
    }

    private func open(_ rfc: RFC) {
        RecentRFCStore.shared.record(rfc, repoID: repo.id)
        RFCViewerWindowManager.shared.open(rfc: rfc, repo: repo, appState: appState)
    }
}

// MARK: - Status grouping

private struct RFCStatusGroup {
    let header: String
    let systemImage: String
    let rfcs: [RFC]

    /// Ordered groups: Implemented → Accepted → Draft → Superseded → Rejected → Unknown
    static func group(_ rfcs: [RFC]) -> [RFCStatusGroup] {
        func pick(_ statuses: [String]) -> [RFC] {
            rfcs.filter { statuses.contains($0.lifecycleStatus ?? "unknown") }
        }
        return [
            RFCStatusGroup(header: "Accepted",      systemImage: "checkmark.circle",              rfcs: pick(["accepted"])),
            RFCStatusGroup(header: "Draft",         systemImage: "pencil.circle",                 rfcs: pick(["draft"])),
            RFCStatusGroup(header: "Implemented",   systemImage: "checkmark.seal.fill",           rfcs: pick(["implemented"])),
            RFCStatusGroup(header: "Superseded",    systemImage: "arrow.triangle.2.circlepath",   rfcs: pick(["superseded"])),
            RFCStatusGroup(header: "Rejected",      systemImage: "xmark.circle",                  rfcs: pick(["rejected"])),
            RFCStatusGroup(header: "Other",         systemImage: "doc.text",                      rfcs: pick(["unknown"])),
        ]
    }
}

// MARK: - Per-repo RFC loader

/// Loads RFCs for a single repository. Results are cached in RepoRFCCache
/// so reopening the submenu is instant. Only one in-flight load at a time.
@MainActor
final class RepoRFCLoader: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded(RFCSections)
        case failed(String)
    }

    struct RFCSections {
        let mainBranch:   [RFC]
        let pullRequests: [RFC]
    }

    @Published private(set) var state: State = .idle
    private var loadTask: Task<Void, Never>? = nil

    func loadIfNeeded(repo: Repository, appState: AppState) async {
        // Return immediately if we have a cached result.
        if let cached = RepoRFCCache.shared.sections(for: repo.id) {
            state = .loaded(cached)
            return
        }
        await load(repo: repo, appState: appState)
    }

    func reload(repo: Repository, appState: AppState) async {
        RepoRFCCache.shared.invalidate(repo.id)
        await load(repo: repo, appState: appState)
    }

    private func load(repo: Repository, appState: AppState) async {
        loadTask?.cancel()
        state = .loading

        loadTask = Task {
            guard let client = appState.makeAPIClient(for: repo) else {
                state = .failed("No API client")
                return
            }
            do {
                let (mainFiles, prs) = try await client.discoverRFCs()
                let mainRFCs = mainFiles.map {
                    RFC(id: $0.id, title: $0.name, path: $0.path, sha: $0.sha,
                        source: .mainBranch, lifecycleStatus: $0.lifecycleStatus, htmlURL: $0.htmlURL)
                }.sorted { $0.title < $1.title }
                let prRFCs = prs.map {
                    RFC(id: "pr-\($0.id)", title: $0.title, path: $0.headRef, sha: $0.headSHA,
                        source: .pullRequest($0), lifecycleStatus: nil, htmlURL: $0.htmlURL)
                }.sorted { $0.title < $1.title }

                let sections = RFCLoader.RFCSections(mainBranch: mainRFCs, pullRequests: prRFCs)
                RepoRFCCache.shared.store(sections, for: repo.id)
                if !Task.isCancelled { state = .loaded(sections) }
            } catch {
                if !Task.isCancelled { state = .failed(error.localizedDescription) }
            }
        }
        await loadTask?.value
    }
}

// Type alias so RepoRFCLoader.RFCSections is accessible from RepoSubmenu
private typealias RFCLoader = RepoRFCLoader

// MARK: - RFC cache

/// Simple in-memory cache keyed by repository UUID.
/// Invalidated on server restart or explicit refresh.
@MainActor
final class RepoRFCCache {
    static let shared = RepoRFCCache()
    private var cache: [UUID: RepoRFCLoader.RFCSections] = [:]

    func sections(for id: UUID) -> RepoRFCLoader.RFCSections? { cache[id] }
    func store(_ s: RepoRFCLoader.RFCSections, for id: UUID) { cache[id] = s }
    func invalidate(_ id: UUID) { cache.removeValue(forKey: id) }
    func invalidateAll() { cache.removeAll() }
}
#endif
