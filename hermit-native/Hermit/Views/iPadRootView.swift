import SwiftUI

// MARK: - hermit-3dc: NavigationSplitView root layout (iPad)
// hermit-80m: Post-publish RFC list refresh and new RFC highlight
// hermit-l00: RFCStore migrated to HermitClientProtocol

@MainActor
final class RFCStore: ObservableObject {
    @Published var rfcs: [RFC] = []
    @Published var isLoading = false
    @Published var errorMessage: String? = nil
    @Published var newlyPublishedID: String? = nil  // hermit-80m: highlight after publish

    private var client: (any HermitClientProtocol)?
    private var loadTask: Task<Void, Never>?
    private var cacheKey: String = ""   // owner/name — used to namespace the cache
    // docsPath retained for the resolvePRPath fallback that needs the path prefix
    private var docsPath: String = "docs-cms/rfcs"

    func configure(client: any HermitClientProtocol, docsPath: String, cacheKey: String = "") {
        self.client   = client
        self.docsPath = docsPath
        if !cacheKey.isEmpty { self.cacheKey = cacheKey }
        // Warm the list from the persisted cache so the UI is populated
        // immediately while the network refresh runs in the background.
        if rfcs.isEmpty { rfcs = Self.loadCache(key: self.cacheKey) }
    }

    func load() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        do {
            let (mainFiles, prs, _) = try await client.discoverRFCs()
            var result: [RFC] = mainFiles.map {
                RFC(id: $0.id, title: $0.name,
                    path: $0.path, sha: $0.sha, source: .mainBranch,
                    lifecycleStatus: $0.lifecycleStatus, htmlURL: $0.htmlURL)
            }
            // Apply the same deduplication + filtering as the Mac native menu:
            // one primary RFC per PR, genuine RFC files only, non-terminal status preferred.
            for pr in primaryPRDocuments(from: prs) {
                result.append(RFC(id: pr.catalogID,
                                  title: pr.prTitle.isEmpty ? pr.title : pr.prTitle,
                                  path: pr.documentPath,
                                  sha: pr.headSHA,
                                  source: .pullRequest(pr),
                                  lifecycleStatus: pr.lifecycleStatus, htmlURL: pr.htmlURL))
            }
            rfcs = result.sorted {
                let aIsPR = if case .pullRequest = $0.source { true } else { false }
                let bIsPR = if case .pullRequest = $1.source { true } else { false }
                if aIsPR != bIsPR { return aIsPR }
                return $0.title < $1.title
            }
            // Persist the fresh list so the next launch renders instantly.
            Self.saveCache(rfcs, key: cacheKey)
        } catch is CancellationError {
            // Task was cancelled by a concurrent reload (e.g. pull-to-refresh
            // over a background retry).  Silently exit — the new load will
            // provide fresh results without surfacing a spurious error.
            isLoading = false
            return
        } catch {
            let nsErr = error as NSError
            if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                // URLSession cancelled because the Swift Task was cancelled.
                isLoading = false
                return
            }
            if case HermitAPIError.httpError(let code, _) = error, code == 401 {
#if os(iOS)
                ConfigStore.shared.localNetworkToken = nil
                AppState.shared.localNetworkToken    = ""
                NotificationCenter.default.post(name: .hermitResetPairing, object: nil)
#endif
                errorMessage = "Pairing revoked — please pair again."
            } else if isOfflineError(error) {
                errorMessage = "Mac appears to be offline.\nMake sure Hermit is running on your Mac."
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    /// Cancels any in-flight load and starts a fresh one with retry.
    func reload() {
        loadTask?.cancel()
        loadTask = Task { await loadWithRetry() }
    }

    /// Cancels any in-flight background load, then performs a single load
    /// and awaits its completion.  Used by pull-to-refresh so the refreshable
    /// indicator stays visible until the request finishes and then dismisses
    /// cleanly — no contention with a background retry loop.
    func refreshNow() async {
        loadTask?.cancel()
        loadTask = nil
        await load()
    }

    /// Loads with exponential backoff on offline errors. Respects task cancellation.
    func loadWithRetry() async {
        let delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]
        for (attempt, delay) in delays.enumerated() {
            guard !Task.isCancelled else { return }
            await load()
            // Stop retrying if load succeeded or it's a non-network error.
            if errorMessage == nil { return }
            guard let msg = errorMessage, msg.contains("offline") else { return }
            // Don't wait after the last attempt.
            if attempt < delays.count - 1 {
                errorMessage = nil       // clear while retrying so UI shows loader
                isLoading = true
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Returns the RFC .md path for a PR: prefers the file the PR actually changed,
    /// falling back to the first .md file on the head branch.
    private func resolvePRPath(client: any HermitClientProtocol, pr: RFCPullRequest) async -> String {
        do {
            let changed = try await client.listPRChangedFiles(prNumber: pr.number, docsPath: docsPath)
            if let path = changed.first { return path }
            let files = try await client.listFilesOnRef(docsPath: docsPath, ref: pr.headRef)
            return files.first ?? ""
        } catch {
            return ""
        }
    }

    /// hermit-80m: refresh after publish and surface the new RFC
    func refreshAfterPublish(prNumber: Int) async {
        await load()
        newlyPublishedID = rfcs.first {
            if case .pullRequest(let pr) = $0.source { return pr.number == prNumber }
            return false
        }?.id
    }

    private func titleFromFilename(_ name: String) -> String {
        name
            .replacingOccurrences(of: ".md", with: "")
            .replacingOccurrences(of: "-", with: " ")
             .capitalized
    }

    // MARK: - Persistent RFC cache (survives app launches)

    /// Persists the RFC list to UserDefaults keyed by repo so the next launch
    /// renders the stale list immediately while a background refresh runs.
    private static func cacheDefaultsKey(_ key: String) -> String {
        "hermit.ipad.rfcCache.\(key)"
    }

    private static func saveCache(_ rfcs: [RFC], key: String) {
        guard !key.isEmpty, !rfcs.isEmpty else { return }
        let encodable = rfcs.compactMap { rfc -> [String: Any]? in
            var d: [String: Any] = [
                "id": rfc.id, "title": rfc.title, "path": rfc.path,
                "sha": rfc.sha, "htmlURL": rfc.htmlURL,
            ]
            if let s = rfc.lifecycleStatus { d["lifecycleStatus"] = s }
            switch rfc.source {
            case .mainBranch:
                d["sourceType"] = "mainBranch"
            case .pullRequest(let pr):
                d["sourceType"] = "pullRequest"
                d["prNumber"] = pr.number; d["prTitle"] = pr.prTitle
                d["headSHA"] = pr.headSHA; d["headRef"] = pr.headRef
                d["htmlURL"] = pr.htmlURL; d["documentPath"] = pr.documentPath
                d["documentType"] = pr.documentType
            }
            return d
        }
        if let data = try? JSONSerialization.data(withJSONObject: encodable) {
            UserDefaults.standard.set(data, forKey: cacheDefaultsKey(key))
        }
    }

    private static func loadCache(key: String) -> [RFC] {
        guard !key.isEmpty,
              let data = UserDefaults.standard.data(forKey: cacheDefaultsKey(key)),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { d -> RFC? in
            guard let id    = d["id"]    as? String,
                  let title = d["title"] as? String,
                  let path  = d["path"]  as? String,
                  let sha   = d["sha"]   as? String,
                  let html  = d["htmlURL"] as? String,
                  let type  = d["sourceType"] as? String
            else { return nil }
            let lcs = d["lifecycleStatus"] as? String
            let source: RFC.RFCSource
            if type == "pullRequest",
               let num  = d["prNumber"] as? Int,
               let pt   = d["prTitle"]  as? String,
               let hSHA = d["headSHA"]  as? String,
               let hRef = d["headRef"]  as? String,
               let docPath = d["documentPath"] as? String,
               let docType = d["documentType"] as? String {
                let pr = RFCPullRequest(
                    id: num, number: num, title: pt, prTitle: pt,
                    prState: "open", prMerged: false, body: "",
                    headSHA: hSHA, headRef: hRef, htmlURL: html, state: "open",
                    draft: false, mergeable: nil, mergeableState: nil,
                    documentType: docType, documentPath: docPath,
                    lifecycleStatus: lcs, catalogID: "\(num)",
                    labels: [], changedFiles: 0, additions: 0, deletions: 0,
                    issueCommentCount: 0, reviewCommentCount: 0)
                source = .pullRequest(pr)
            } else {
                source = .mainBranch
            }
            return RFC(id: id, title: title, path: path, sha: sha,
                       source: source, lifecycleStatus: lcs, htmlURL: html)
        }
    }
}

/// Returns true when the error is a network-level failure meaning the server
/// is unreachable — timeout, connection refused, no route to host, etc.
/// These are shown as "Mac appears to be offline" rather than a raw URL error.
private func isOfflineError(_ error: Error) -> Bool {
    let nsError = error as NSError
    guard nsError.domain == NSURLErrorDomain else { return false }
    switch nsError.code {
    case NSURLErrorTimedOut,
         NSURLErrorCannotConnectToHost,
         NSURLErrorNetworkConnectionLost,
         NSURLErrorNotConnectedToInternet,
         NSURLErrorCannotFindHost,
         NSURLErrorDNSLookupFailed,
         NSURLErrorResourceUnavailable:
        return true
    default:
        return false
    }
}

// MARK: - hermit-3dc: iPadRootView — iOS only

#if os(iOS)
struct iPadRootView: View {
    @EnvironmentObject private var appState: AppState
#if os(iOS)
    @EnvironmentObject private var pairingBrowser: PairingBrowser
#endif
    @StateObject private var store = RFCStore()
    @StateObject private var commentStore = CommentStore()
    @ObservedObject private var repoStore = RepositoryStore.shared
    // hermit-olq: selectedRFC and selectedLine promoted to AppState for NSUserActivity access
    @State private var showSettings = false
    @State private var showRFCPicker = false   // portrait: RFC menu popover
    @State private var showThread = false       // portrait: thread sheet
#if os(iOS)
    @State private var isLandscape: Bool = UIDevice.current.orientation.isLandscape
#else
    @State private var isLandscape: Bool = false
#endif

    var body: some View {
        Group {
            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
#if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let o = UIDevice.current.orientation
            // Only flip on unambiguous landscape/portrait — ignore faceUp/faceDown/unknown
            if o.isLandscape { isLandscape = true }
            else if o.isPortrait { isLandscape = false }
        }
#endif
        .task {
            guard let client = appState.makeAPIClient() else {
                store.errorMessage = "No API client — check pairing or configuration."
                return
            }
            store.configure(client: client, docsPath: appState.docsPath, cacheKey: "(appState.repoOwner)/(appState.repoName)")
            store.reload()
        }
        .onChange(of: appState.serverBaseURL) { _, newURL in
            guard !newURL.isEmpty else { return }
            // Cancel any in-flight load before reconfiguring — prevents stacked
            // retry chains when the Mac restarts and the URL changes rapidly.
            if let client = appState.makeAPIClient() {
                store.configure(client: client, docsPath: appState.docsPath, cacheKey: "(appState.repoOwner)/(appState.repoName)")
            }
            store.reload()
        }
        .onChange(of: appState.localNetworkToken) { _, _ in
            // Token arrives after URL in some flows (e.g. re-pair after reinstall)
            if let client = appState.makeAPIClient() {
                store.configure(client: client, docsPath: appState.docsPath, cacheKey: "(appState.repoOwner)/(appState.repoName)")
                store.reload()
            }
        }
        .safeAreaInset(edge: .bottom) {
#if os(iOS)
            ConnectionStatusBar(appState: appState, pairingBrowser: pairingBrowser)
#endif
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(appState)
                    .navigationTitle("Settings")
#if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
#endif
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
        }
        // hermit-z9j: Donate Handoff activity whenever the selected RFC changes (iPadOS)
        .userActivity(HermitActivity.handoff) { activity in
            guard let rfc = appState.selectedRFC else {
                activity.isEligibleForHandoff = false
                return
            }
            activity.isEligibleForHandoff = true
            activity.title = rfc.title
            activity.userInfo = HermitActivity.userInfo(for: rfc, selectedLine: appState.selectedLine)
        }
        // hermit-z9j: Continue a Handoff activity arriving from another device (iPadOS)
        .onContinueUserActivity(HermitActivity.handoff) { activity in
            guard let rfcID = activity.userInfo?[HermitActivity.keyRFCID] as? String else { return }
            let line = activity.userInfo?[HermitActivity.keySelectedLine] as? Int
            // Store the pending navigation; RFCStore may not be loaded yet
            appState.pendingHandoffRFCID = rfcID
            appState.pendingHandoffLine  = line
        }
        // hermit-z9j: Navigate to pending Handoff RFC once the store has loaded
        .onChange(of: store.rfcs) { _, rfcs in
            // Handoff continuation
            if let rfcID = appState.pendingHandoffRFCID,
               let rfc = rfcs.first(where: { $0.id == rfcID }) {
                appState.selectedRFC          = rfc
                appState.selectedLine         = appState.pendingHandoffLine
                appState.pendingHandoffRFCID  = nil
                appState.pendingHandoffLine   = nil
            }
            // hermit-txn: deep link navigation
            if let path = appState.pendingDeepLinkPath,
               let rfc = rfcs.first(where: { $0.path == path }) {
                appState.selectedRFC         = rfc
                appState.selectedLine        = nil
                appState.pendingDeepLinkPath = nil
            }
        }
        // hermit-myr: donate to Spotlight / Siri whenever the viewed RFC changes (iPadOS)
        // hermit-iwq: persist last-viewed RFC for scene restoration on next launch
        .onChange(of: appState.selectedRFC) { _, rfc in
            appState.persistLastViewedRFC(rfc)
#if canImport(CoreSpotlight)
            if let rfc { SpotlightDonor.shared.donate(rfc: rfc) }
#endif
        }
    }

    // MARK: - Landscape: two-column split (list | detail+thread)

    private var landscapeLayout: some View {
        NavigationSplitView {
            RFCListView(rfcs: store.rfcs,
                        selectedRFC: $appState.selectedRFC,
                        onRefresh: { await store.refreshNow() },
                        suppressEmptyState: store.errorMessage != nil,
                        isLoading: store.isLoading)
            .navigationTitle("Hermit")
            .overlay { listOverlay }
            .toolbar { listToolbarItems }
        } detail: {
            detailView(showInlineThread: false)
        }
    }

    // MARK: - Portrait: full-screen detail, RFC picked from toolbar menu

    private var portraitLayout: some View {
        NavigationStack {
            detailView(showInlineThread: false)
                .navigationTitle(appState.selectedRFC?.title ?? "Hermit")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // RFC picker — left side, uses popover for full-width control
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showRFCPicker = true
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "list.bullet.rectangle")
                                Text(appState.selectedRFC?.title ?? "Select RFC")
                                    .lineLimit(1)
                                    .font(.subheadline)
                                Image(systemName: "chevron.down")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .popover(isPresented: $showRFCPicker, arrowEdge: .top) {
                            RFCPickerPopover(
                                rfcs: store.rfcs,
                                isLoading: store.isLoading,
                                selectedRFC: $appState.selectedRFC,
                                isPresented: $showRFCPicker,
                                onRefresh: { store.reload() }
                            )
                            .environmentObject(appState)
                        }
                    }
                    // Repo switcher — right side
                    ToolbarItem(placement: .topBarTrailing) {
                        repoSwitcherMenu
                    }
                    // Other trailing items
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        if store.isLoading { ProgressView().controlSize(.small) }
                        // Thread button — only for PR RFCs
                        if let rfc = appState.selectedRFC, case .pullRequest(let pr) = rfc.source {
                            Button {
                                showThread = true
                            } label: {
                                Image(systemName: "bubble.left.and.bubble.right")
                            }
                            .sheet(isPresented: $showThread) {
                                NavigationStack {
                                    ThreadPanelView(prNumber: pr.number, selectedLine: appState.selectedLine, selectedLineEnd: appState.selectedLineEnd)
                                        .environmentObject(commentStore)
                                        .navigationTitle("Comments")
                                        .navigationBarTitleDisplayMode(.inline)
                                        .toolbar {
                                            ToolbarItem(placement: .topBarTrailing) {
                                                Button("Done") { showThread = false }
                                            }
                                        }
                                }
                            }
                        }
                        Button { showSettings = true } label: {
                            Image(systemName: "gear")
                        }
                    }
                }
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private var listOverlay: some View {
        // Only show the full error overlay when there's no stale data to display.
        // When cached RFCs are visible, the error would obscure them — the toolbar
        // spinner already signals that a refresh is in progress or failed.
        if let err = store.errorMessage, store.rfcs.isEmpty {
            ContentUnavailableView {
                Label("Could not load RFCs", systemImage: "wifi.exclamationmark")
            } description: {
                Text(err)
            } actions: {
                Button("Try Again") {
                    Task {
                        if let client = appState.makeAPIClient() {
                            store.configure(client: client, docsPath: appState.docsPath, cacheKey: "\(appState.repoOwner)/\(appState.repoName)")
                            await store.refreshNow()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        // "No RFCs" empty state is handled by RFCListView directly.
    }

    @ToolbarContentBuilder
    private var listToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if store.isLoading { ProgressView().controlSize(.small) }
        }
        ToolbarItem(placement: .principal) {
            repoSwitcherMenu
        }
        ToolbarItem(placement: .automatic) {
            Button { showSettings = true } label: {
                Image(systemName: "gear")
            }
        }
    }

    private func rfcIcon(_ rfc: RFC) -> String {
        if case .pullRequest = rfc.source { return "arrow.triangle.pull" }
        return "doc.text"
    }

    /// Switches the active repository and reloads the RFC list.
    private func switchRepo(_ repo: Repository) {
        RepositoryStore.shared.setActive(repo)
        guard let client = appState.makeAPIClient() else { return }
        store.configure(client: client, docsPath: repo.docsPath)
        appState.selectedRFC = nil
        store.reload()
    }

    /// A Menu that lists all repos and lets the user switch between them.
    @ViewBuilder
    private var repoSwitcherMenu: some View {
        let repos = repoStore.repositories
        let active = repos.first
        Menu {
            ForEach(repos) { repo in
                Button {
                    switchRepo(repo)
                } label: {
                    if repo.id == active?.id {
                        Label(repo.fullName, systemImage: "checkmark")
                    } else {
                        Text(repo.fullName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(active?.fullName ?? "No Repository")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .lineLimit(1)
                if repos.count > 1 {
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(repos.count <= 1)
    }

    // MARK: - Detail view (shared; showInlineThread controls landscape thread panel)

    @ViewBuilder
    private func detailView(showInlineThread: Bool) -> some View {
        if let rfc = appState.selectedRFC {
            VStack(spacing: 0) {
                RFCDetailView(rfc: rfc, commentStore: commentStore, onLineTapped: { line, lineEnd in
                    appState.selectedLine = line
                    appState.selectedLineEnd = lineEnd
                }, onMerged: {
                    appState.selectedRFC = nil
                    store.reload()
                })
                if showInlineThread, case .pullRequest(let pr) = rfc.source {
                    Divider()
                    ThreadPanelView(prNumber: pr.number, selectedLine: appState.selectedLine, selectedLineEnd: appState.selectedLineEnd)
                        .environmentObject(commentStore)
                        .frame(maxHeight: 280)
                }
            }
        } else {
            ContentUnavailableView("Select an RFC", systemImage: "doc.text")
        }
    }
}

// MARK: - Connection status bar

#endif // os(iOS) — iPadRootView

#if os(iOS)
private struct ConnectionStatusBar: View {
    @ObservedObject var appState: AppState
    @ObservedObject var pairingBrowser: PairingBrowser

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if !appState.serverBaseURL.isEmpty {
                Text(appState.serverBaseURL)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusColor: Color {
        if pairingBrowser.isPaired { return .green }
        if appState.serverBaseURL.isEmpty { return .red }
        return .orange
    }

    private var statusText: String {
        if pairingBrowser.isPaired {
            return appState.serverBaseURL.isEmpty ? "Paired — reconnecting…" : "Connected"
        }
        if appState.serverBaseURL.isEmpty {
            return pairingBrowser.discoveredMacs.isEmpty ? "Searching…" : "Mac found — tap gear to pair"
        }
        return "Connected — not paired"
    }
}

// MARK: - RFC Picker Popover (portrait mode)

private struct RFCPickerPopover: View {
    let rfcs: [RFC]
    let isLoading: Bool
    @Binding var selectedRFC: RFC?
    @Binding var isPresented: Bool
    let onRefresh: () -> Void

    @State private var searchText = ""

    private var filtered: [RFC] {
        guard !searchText.isEmpty else { return rfcs }
        return rfcs.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    private var prRFCs: [RFC] {
        filtered.filter { if case .pullRequest = $0.source { true } else { false } }
    }

    private var mainRFCs: [RFC] {
        filtered.filter { if case .mainBranch = $0.source { true } else { false } }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading RFCs…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if rfcs.isEmpty {
                    ContentUnavailableView("No RFCs", systemImage: "doc.text")
                } else {
                    List(selection: Binding(
                        get: { selectedRFC },
                        set: { rfc in
                            if let rfc {
                                selectedRFC = rfc
                                isPresented = false
                            }
                        }
                    )) {
                        if !prRFCs.isEmpty {
                            Section("In Review") {
                                ForEach(prRFCs) { rfc in
                                    Label(rfc.title, systemImage: "arrow.triangle.pull")
                                        .tag(rfc)
                                }
                            }
                        }
                        ForEach(RFCStatusGroup.group(mainRFCs).filter { !$0.rfcs.isEmpty }, id: \.header) { group in
                            Section(group.header) {
                                ForEach(group.rfcs) { rfc in
                                    Label(rfc.title, systemImage: group.systemImage)
                                        .tag(rfc)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("RFCs")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search RFCs")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onRefresh()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .frame(minWidth: 360, minHeight: 480)
    }
}

#endif
