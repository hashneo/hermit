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
    // docsPath retained for the resolvePRPath fallback that needs the path prefix
    private var docsPath: String = "docs-cms/rfcs"

    func configure(client: any HermitClientProtocol, docsPath: String) {
        self.client   = client
        self.docsPath = docsPath
    }

    func load() async {
        guard let client else { return }
        isLoading = true
        errorMessage = nil
        do {
            let (mainFiles, prs) = try await client.discoverRFCs()
            var result: [RFC] = mainFiles.map {
                RFC(id: $0.id, title: $0.name,
                    path: $0.path, sha: $0.sha, source: .mainBranch)
            }
            for pr in prs {
                result.append(RFC(id: "pr-\(pr.id)", title: pr.title,
                                  path: pr.headRef,   // unused for PR RFCs — fetchPRRFCContent uses prNumber
                                  sha: pr.headSHA,
                                  source: .pullRequest(pr)))
            }
            rfcs = result.sorted { $0.title < $1.title }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
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
}

struct iPadRootView: View {
    @EnvironmentObject private var appState: AppState
#if os(iOS)
    @EnvironmentObject private var pairingBrowser: PairingBrowser
#endif
    @StateObject private var store = RFCStore()
    @StateObject private var commentStore = CommentStore()
    // hermit-olq: selectedRFC and selectedLine promoted to AppState for NSUserActivity access
    @State private var showSettings = false
    @State private var showRFCPicker = false   // portrait: RFC menu popover
    @State private var showThread = false       // portrait: thread sheet
    @State private var isLandscape: Bool = UIDevice.current.orientation.isLandscape

    var body: some View {
        Group {
            if isLandscape {
                landscapeLayout
            } else {
                portraitLayout
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            let o = UIDevice.current.orientation
            // Only flip on unambiguous landscape/portrait — ignore faceUp/faceDown/unknown
            if o.isLandscape { isLandscape = true }
            else if o.isPortrait { isLandscape = false }
        }
        .task {
            guard let client = appState.makeAPIClient() else {
                store.errorMessage = "No API client — check pairing or configuration."
                return
            }
            store.configure(client: client, docsPath: appState.docsPath)
            await store.load()
        }
        .onChange(of: appState.serverBaseURL) { _, _ in
            if let client = appState.makeAPIClient() {
                store.configure(client: client, docsPath: appState.docsPath)
                Task { await store.load() }
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
    }

    // MARK: - Landscape: two-column split (list | detail+thread)

    private var landscapeLayout: some View {
        NavigationSplitView {
            RFCListView(rfcs: store.rfcs, selectedRFC: $appState.selectedRFC) {
                await store.load()
            }
            .navigationTitle("Hermit")
            .overlay { listOverlay }
            .toolbar { listToolbarItems }
        } detail: {
            detailView(showInlineThread: true)
        }
    }

    // MARK: - Portrait: full-screen detail, RFC picked from toolbar menu

    private var portraitLayout: some View {
        NavigationStack {
            detailView(showInlineThread: false)
                .navigationTitle(appState.selectedRFC?.title ?? "Hermit")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    // RFC picker — left side
                    ToolbarItem(placement: .topBarLeading) {
                        Menu {
                            if store.isLoading {
                                Label("Loading…", systemImage: "arrow.clockwise")
                            } else if store.rfcs.isEmpty {
                                Label("No RFCs found", systemImage: "doc.text")
                            } else {
                                ForEach(store.rfcs) { rfc in
                                    Button {
                                        appState.selectedRFC = rfc
                                        appState.selectedLine = nil
                                    } label: {
                                        Label(rfc.title, systemImage: rfcIcon(rfc))
                                    }
                                }
                            }
                            Divider()
                            Button { Task { await store.load() } } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                        } label: {
                            Label("RFCs", systemImage: "list.bullet.rectangle")
                        }
                    }
                    // Right side
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
                                    ThreadPanelView(prNumber: pr.number, selectedLine: appState.selectedLine)
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
        if let err = store.errorMessage {
            ContentUnavailableView("Could not load RFCs",
                systemImage: "exclamationmark.triangle",
                description: Text(err))
        } else if store.rfcs.isEmpty && !store.isLoading {
            ContentUnavailableView("No RFCs", systemImage: "doc.text")
        }
    }

    @ToolbarContentBuilder
    private var listToolbarItems: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if store.isLoading { ProgressView().controlSize(.small) }
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

    // MARK: - Detail view (shared; showInlineThread controls landscape thread panel)

    @ViewBuilder
    private func detailView(showInlineThread: Bool) -> some View {
        if let rfc = appState.selectedRFC {
            VStack(spacing: 0) {
                RFCDetailView(rfc: rfc, commentStore: commentStore, onLineTapped: { line in
                    appState.selectedLine = line
                })
                if showInlineThread, case .pullRequest(let pr) = rfc.source {
                    Divider()
                    ThreadPanelView(prNumber: pr.number, selectedLine: appState.selectedLine)
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
        if appState.serverBaseURL.isEmpty { return .red }
        if !appState.localNetworkToken.isEmpty { return .green }
        return .orange
    }

    private var statusText: String {
        if appState.serverBaseURL.isEmpty {
            return pairingBrowser.discoveredMacs.isEmpty ? "Searching…" : "Mac found — not paired"
        }
        if appState.localNetworkToken.isEmpty { return "Connected — not paired" }
        return "Connected"
    }
}
#endif
