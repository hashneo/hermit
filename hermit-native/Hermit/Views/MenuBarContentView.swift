import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - MenuBarContentView

struct MenuBarContentView: View {
    @EnvironmentObject private var appState: AppState
#if os(macOS)
    private let initialAnchorScreenX: CGFloat?
    private let managesWindowPresentation: Bool
    private let allowsDetach: Bool
    private let onOpenReview: () -> Void
    private let onDetach: () -> Void
    private let onClose: () -> Void
    @ObservedObject private var serverMgr = EmbeddedServerManager.shared
    @ObservedObject private var repoStore = RepositoryStore.shared
    @ObservedObject private var accountStore = AccountStore.shared
    @ObservedObject private var advertiser = PairingAdvertiser.shared
    @StateObject private var serverRepoStore = ServerRepositoryMenuStore()
    @StateObject private var dashboardStore = MenuBarDashboardStore()
    @State private var selectedRepoID: UUID? = nil
    @State private var repoSort: RepoSortOption = .reviewCount
    @State private var repoFilter: RepoFilterOption = .all
    @State private var selectedView: MenuBarPrimaryView = .dashboard
    @State private var menuAnchor = MenuBarBubbleAnchor.capture()
    @State private var pointerX = MenuBarBubbleWindowController.fallbackPointerX

    init(
        anchorScreenX: CGFloat? = nil,
        managesWindowPresentation: Bool = true,
        allowsDetach: Bool = true,
        openToSettings: Bool = false,
        onOpenReview: @escaping () -> Void = {},
        onDetach: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.initialAnchorScreenX = anchorScreenX
        self.managesWindowPresentation = managesWindowPresentation
        self.allowsDetach = allowsDetach
        self.onOpenReview = onOpenReview
        self.onDetach = onDetach
        self.onClose = onClose
        _selectedView = State(initialValue: openToSettings ? .settings : .dashboard)
        _menuAnchor = State(initialValue: MenuBarBubbleAnchor.capture(anchorScreenX))
        _pointerX = State(initialValue: managesWindowPresentation ? MenuBarBubbleWindowController.fallbackPointerX : 280)
    }
#else
    init() {}
#endif

#if os(macOS)
    var body: some View {
        rootContent
            .onAppear {
                menuAnchor = MenuBarBubbleAnchor.capture(initialAnchorScreenX)
                serverRepoStore.start(portProvider: { serverMgr.port }, accountIDProvider: { accountStore.connections.first?.id })
                Task {
                    await refreshAll(force: false)
                }
            }
            .onChange(of: serverMgr.port) { _, port in
                Task {
                    await refreshAll(force: true, portOverride: port)
                }
            }
            .onChange(of: repoIdentitySignature) { _, _ in
                if let selectedRepoID, !displayedRepos.contains(where: { $0.id == selectedRepoID }) {
                    self.selectedRepoID = nil
                }
                Task { await refreshDashboard(force: false) }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        if managesWindowPresentation {
            menuContent
                .frame(width: renderMode.contentSize.width, height: renderMode.contentSize.height)
                .padding(.top, MenuBarSpeechBubbleShape.pointerHeight)
                .background {
                    MenuBarBubbleWindowAccessor(
                        contentSize: renderMode.contentSize,
                        anchor: menuAnchor,
                        pointerX: $pointerX
                    )
                }
                .background {
                    MenuBarSpeechBubbleShape(pointerX: pointerX)
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .shadow(color: .black.opacity(0.20), radius: 18, x: 0, y: 8)
                }
                .overlay {
                    MenuBarSpeechBubbleShape(pointerX: pointerX)
                        .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                }
                .clipShape(MenuBarSpeechBubbleShape(pointerX: pointerX))
                .animation(.snappy(duration: 0.22), value: renderMode)
        } else {
            menuContent
                .frame(minWidth: MenuBarRenderMode.normal.contentSize.width, minHeight: MenuBarRenderMode.normal.contentSize.height)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var menuContent: some View {
        VStack(spacing: 0) {
            header

            if let invite = advertiser.pendingInvitation {
                PairingInviteBanner(invite: invite)
                    .padding(16)
                Divider()
            }

            content

            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Hermit")
                        .font(.title2.weight(.semibold))
                }

                Spacer()

                headerControls
            }

            if renderMode == .compact {
                viewPicker
            }

            if let issue = serverRepoStore.issue {
                IssueBanner(issue: issue, compact: true, onRetry: {
                    Task { await refreshAll(force: true) }
                }, onSettings: {
                    selectedView = .settings
                })
            }
        }
        .padding(16)
    }

    private var viewPicker: some View {
        Picker("View", selection: $selectedView) {
            Label("Dashboard", systemImage: "rectangle.grid.2x2").tag(MenuBarPrimaryView.dashboard)
            Label("Monitor", systemImage: "waveform.path.ecg").tag(MenuBarPrimaryView.monitoring)
            Label("Settings", systemImage: "gearshape").tag(MenuBarPrimaryView.settings)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: renderMode == .compact ? 280 : 300)
    }

    @ViewBuilder
    private var headerControls: some View {
        if renderMode == .compact {
            HStack(spacing: 8) {
                Button {
                    Task { await refreshAll(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh")
                .buttonStyle(.bordered)
                .disabled(selectedView != .dashboard)

                if allowsDetach {
                    Button(action: onDetach) {
                        Label("Detach", systemImage: "rectangle.on.rectangle")
                    }
                    .labelStyle(.iconOnly)
                    .help("Detach to floating window")
                    .buttonStyle(.bordered)
                }

                Button {
                    NewRFCWindowManager.shared.open(appState: appState)
                } label: {
                    Label("New RFC", systemImage: "plus")
                }
                .labelStyle(.iconOnly)
                .help("New RFC")
                .buttonStyle(.borderedProminent)
            }
        } else {
            HStack(spacing: 8) {
                viewPicker

                Button {
                    Task { await refreshAll(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(selectedView != .dashboard)

                if allowsDetach {
                    Button(action: onDetach) {
                        Label("Detach", systemImage: "rectangle.on.rectangle")
                    }
                    .buttonStyle(.bordered)
                    .help("Detach to floating window")
                }

                Button {
                    NewRFCWindowManager.shared.open(appState: appState)
                } label: {
                    Label("New RFC", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedView {
        case .dashboard:
            if renderMode == .compact {
                compactDashboardContent
            } else {
                dashboardContent
            }
        case .monitoring:
            MonitoringTabView(
                repositories: displayedRepos,
                serverPort: serverMgr.port,
                serverIssue: serverRepoStore.issue,
                repositoryStats: serverRepoStore.stats,
                dashboardStats: dashboardStore.stats,
                states: dashboardStore.statesSnapshot
            )
        case .settings:
            SettingsView(embedded: true)
                .environmentObject(appState)
        }
    }

    @ViewBuilder
    private var compactDashboardContent: some View {
        if displayedRepos.isEmpty {
            ContentUnavailableView(
                "No repositories configured",
                systemImage: "shippingbox",
                description: Text("Add a repository in Settings to populate the Hermit popout.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CompactAllRepositoriesSummary(
                        repoCount: displayedRepos.count,
                        loadedCount: loadedRepositoryCount,
                        pendingReviewCount: aggregatePendingReviewCount,
                        openPRCount: aggregateOpenPRCount,
                        publishedCount: aggregatePublishedCount,
                        prStateSummaries: aggregatePRStateSummaries,
                        prStatsFreshness: aggregatePRStatsFreshness,
                        serverStatusText: serverStatusText,
                        serverStatusColor: serverStatusColor
                    )

                    CompactReviewQueue(
                        groups: pendingPRGroups,
                        totalCount: aggregatePendingReviewCount,
                        onOpen: { group in open(group.primaryRFC, in: group.repo) }
                    )
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
    }

    @ViewBuilder
    private var dashboardContent: some View {
        if displayedRepos.isEmpty {
            ContentUnavailableView(
                "No repositories configured",
                systemImage: "shippingbox",
                description: Text("Add a repository in Settings to populate the Hermit popout.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(spacing: 0) {
                repoColumn
                Divider()
                detailColumn
            }
        }
    }

    private var repoColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Repositories")
                        .font(.headline)
                    Spacer()
                    Text("\(displayedRepos.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 1)

                RepositoryTopRail(
                    isSelected: selectedRepoID == nil,
                    sort: $repoSort,
                    filter: $repoFilter,
                    onSelect: { selectedRepoID = nil }
                )

                ExpandedDashboardSidebarStats(
                    pendingReviewCount: aggregatePendingReviewCount,
                    openPRCount: aggregateOpenPRCount,
                    prStateSummaries: aggregatePRStateSummaries
                )

                ForEach(filteredOrderedRepos) { repo in
                    RepoFilterRow(
                        repo: repo,
                        state: dashboardStore.state(for: repo.id),
                        isSelected: repo.id == selectedRepoID,
                        isActive: repo.id == repoStore.repositories.first?.id,
                        onSelect: { selectedRepoID = repo.id }
                    )
                }
            }
            .padding(14)
        }
        .frame(width: 300)
    }

    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if selectedRepoID == nil {
                    AllRepositoriesSection(
                        repoCount: displayedRepos.count,
                        loadedCount: loadedRepositoryCount,
                        prStatsFreshness: aggregatePRStatsFreshness
                    )
                    PRReviewSection(
                        title: "Review queue",
                        groups: pendingPRGroups,
                        emptyText: "No pull requests currently contain reviewable docs-cms documents.",
                        showsRepository: true,
                        onOpen: { group in open(group.primaryRFC, in: group.repo) }
                    )
                } else if let repo = selectedRepo {
                    SelectedRepoSection(
                        repo: repo,
                        state: dashboardStore.state(for: repo.id),
                        isActive: repo.id == repoStore.repositories.first?.id,
                        onActivate: { activate(repo) },
                        onRefresh: { Task { await dashboardStore.reload(repo: repo, appState: appState) } },
                        onOpenSettings: { selectedView = .settings },
                        onOpenPR: { rfc in open(rfc, in: repo) },
                        onOpen: { rfc in open(rfc, in: repo) }
                    )
                }
            }
            .padding(16)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()

            Button("Close Dashboard") {
                onClose()
            }
            .keyboardShortcut("q")
        }
        .padding(16)
    }

    private var displayedRepos: [Repository] {
        serverRepoStore.repositories.isEmpty ? repoStore.repositories : serverRepoStore.repositories
    }

    private var renderMode: MenuBarRenderMode {
        if !managesWindowPresentation { return .normal }
        if selectedView != .dashboard { return .normal }
        if selectedRepoID != nil { return .normal }
        if advertiser.pendingInvitation != nil { return .normal }
        if serverRepoStore.issue != nil { return .normal }
        return .compact
    }

    private var orderedRepos: [Repository] {
        displayedRepos.sorted { lhs, rhs in
            switch repoSort {
            case .reviewCount:
                break
            case .name:
                return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
            case .defaultFirst:
                let lhsIsActive = lhs.id == repoStore.repositories.first?.id
                let rhsIsActive = rhs.id == repoStore.repositories.first?.id
                if lhsIsActive != rhsIsActive { return lhsIsActive }
                return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
            }

            let lhsReviewCount = dashboardStore.state(for: lhs.id)?.pullRequests.count ?? 0
            let rhsReviewCount = dashboardStore.state(for: rhs.id)?.pullRequests.count ?? 0
            if lhsReviewCount != rhsReviewCount { return lhsReviewCount > rhsReviewCount }

            let lhsIsActive = lhs.id == repoStore.repositories.first?.id
            let rhsIsActive = rhs.id == repoStore.repositories.first?.id
            if lhsIsActive != rhsIsActive { return lhsIsActive }

            return lhs.fullName.localizedCaseInsensitiveCompare(rhs.fullName) == .orderedAscending
        }
    }

    private var filteredOrderedRepos: [Repository] {
        orderedRepos.filter { repo in
            let state = dashboardStore.state(for: repo.id)
            switch repoFilter {
            case .all:
                return true
            case .pendingReview:
                return (state?.pendingReviewCount ?? 0) > 0
            case .needsAttention:
                return state?.issue != nil
            }
        }
    }

    private var repoIdentitySignature: String {
        displayedRepos.map { repo in
            repo.serverID ?? "\(repo.owner.lowercased())/\(repo.name.lowercased())"
        }
        .joined(separator: ",")
    }

    private var selectedRepo: Repository? {
        if let selectedRepoID,
           let repo = displayedRepos.first(where: { $0.id == selectedRepoID }) {
            return repo
        }
        return nil
    }

    private var pendingRFCItems: [PendingRFCItem] {
        let repos = selectedRepo.map { [$0] } ?? displayedRepos
        return repos.flatMap { repo -> [PendingRFCItem] in
            guard let state = dashboardStore.state(for: repo.id) else { return [] }
            return state.pullRequests.map { PendingRFCItem(repo: repo, rfc: $0) }
        }
        .sorted { lhs, rhs in
            let lhsPR = lhs.prNumber ?? 0
            let rhsPR = rhs.prNumber ?? 0
            if lhsPR != rhsPR { return lhsPR > rhsPR }
            return lhs.rfc.title < rhs.rfc.title
        }
    }

    private var pendingPRGroups: [PendingPRGroup] {
        let grouped = Dictionary(grouping: pendingRFCItems) { item in
            "\(item.repo.id.uuidString)-\(item.prNumber ?? 0)"
        }
        return grouped.values.compactMap { items in
            guard let first = items.first, first.prNumber != nil else { return nil }
            return PendingPRGroup(repo: first.repo, items: items)
        }
        .sorted { lhs, rhs in
            if lhs.pr.number != rhs.pr.number { return lhs.pr.number > rhs.pr.number }
            return lhs.repo.fullName < rhs.repo.fullName
        }
    }

    private var repositoryReviewBuckets: [RepositoryReviewBucket] {
        displayedRepos.map { repo in
            RepositoryReviewBucket(repo: repo, state: dashboardStore.state(for: repo.id))
        }
        .sorted { lhs, rhs in
            let lhsHasDocs = lhs.documentCount > 0
            let rhsHasDocs = rhs.documentCount > 0
            if lhsHasDocs != rhsHasDocs { return lhsHasDocs }
            if lhs.documentCount != rhs.documentCount { return lhs.documentCount > rhs.documentCount }
            let lhsHasPRs = lhs.prCount > 0
            let rhsHasPRs = rhs.prCount > 0
            if lhsHasPRs != rhsHasPRs { return lhsHasPRs }
            if lhs.prCount != rhs.prCount { return lhs.prCount > rhs.prCount }
            if lhs.isLoading != rhs.isLoading { return rhs.isLoading }
            return lhs.repo.fullName.localizedCaseInsensitiveCompare(rhs.repo.fullName) == .orderedAscending
        }
    }

    private var aggregatePRStateSummaries: [PRStateSummary] {
        var counts = PRStateCounts.empty
        for repo in displayedRepos {
            counts.add(dashboardStore.state(for: repo.id)?.prStateCounts ?? .empty)
        }
        return PRStateSummary.summarize(counts)
    }

    private var aggregatePRStatsFreshness: PRStatsFreshness {
        let states = displayedRepos.compactMap { dashboardStore.state(for: $0.id) }
        let loadedStates = states.filter { $0.prStatsLoadedAt != nil && !$0.isLoading && $0.issue == nil }
        let failedStates = states.filter { $0.issue != nil }
        let authFailureCount = failedStates.filter { state in
            guard let issue = state.issue else { return false }
            return isRepositoryAuthenticationIssue(issue)
        }.count
        let pendingRepositoryCount = max(displayedRepos.count - loadedStates.count - failedStates.count, 0)
        let newestLoadedAt = loadedStates.compactMap(\.prStatsLoadedAt).max()
        let isLoading = pendingRepositoryCount > 0 || states.contains { $0.isLoading }
        return PRStatsFreshness(
            loadedRepositoryCount: loadedStates.count,
            totalRepositoryCount: displayedRepos.count,
            failedRepositoryCount: failedStates.count,
            authFailureCount: authFailureCount,
            pendingRepositoryCount: pendingRepositoryCount,
            newestLoadedAt: newestLoadedAt,
            isLoading: isLoading
        )
    }

    private var aggregatePendingReviewCount: Int {
        displayedRepos.reduce(0) { total, repo in
            total + (dashboardStore.state(for: repo.id)?.pendingReviewCount ?? 0)
        }
    }

    private var aggregateOpenPRCount: Int {
        displayedRepos.reduce(0) { total, repo in
            total + (dashboardStore.state(for: repo.id)?.openPRCount ?? 0)
        }
    }

    private var aggregatePublishedCount: Int {
        displayedRepos.reduce(0) { total, repo in
            total + (dashboardStore.state(for: repo.id)?.mainBranch.count ?? 0)
        }
    }

    private var loadedRepositoryCount: Int {
        displayedRepos.filter { repo in
            guard let state = dashboardStore.state(for: repo.id) else { return false }
            return state.prStatsLoadedAt != nil || state.issue != nil
        }.count
    }

    private var serverStatusText: String {
        if let port = serverMgr.port {
            return "Embedded server running on port \(port)"
        }
        if serverMgr.errorMessage != nil {
            return "Embedded server needs attention"
        }
        return "Embedded server starting…"
    }

    private var serverStatusColor: Color {
        if serverMgr.port != nil { return .green }
        if serverMgr.errorMessage != nil { return .orange }
        return .secondary
    }

    private func refreshDashboard(force: Bool) async {
        await dashboardStore.refresh(repos: displayedRepos, appState: appState, force: force)
    }

    private func refreshAll(force: Bool, portOverride: Int? = nil) async {
        let port = portOverride ?? serverMgr.port
        let accountID = accountStore.connections.first?.id
        await serverRepoStore.refresh(port: port, accountID: accountID)
        await refreshDashboard(force: force)
    }

    private func activate(_ repo: Repository) {
        RepositoryStore.shared.setActive(repo)
        selectedRepoID = repo.id
    }

    private func open(_ rfc: RFC, in repo: Repository) {
        RecentRFCStore.shared.record(rfc, repoID: repo.id)
        RFCViewerWindowManager.shared.open(rfc: rfc, repo: repo, appState: appState)
        onOpenReview()
    }

#else
    var body: some View { EmptyView() }
#endif
}

private struct MenuBarSpeechBubbleShape: InsettableShape {
    static let pointerHeight: CGFloat = 16

    private static let pointerWidth: CGFloat = 42
    private static let cornerRadius: CGFloat = 24

    var pointerX: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let bounds = rect.insetBy(dx: insetAmount, dy: insetAmount)
        let bodyRect = CGRect(
            x: bounds.minX,
            y: bounds.minY + Self.pointerHeight,
            width: bounds.width,
            height: max(0, bounds.height - Self.pointerHeight)
        )
        let radius = min(Self.cornerRadius, bodyRect.width / 2, bodyRect.height / 2)
        let halfPointer = Self.pointerWidth / 2
        let pointerCenterX = min(
            max(bodyRect.minX + pointerX, bodyRect.minX + radius + halfPointer),
            bodyRect.maxX - radius - halfPointer
        )

        var path = Path()
        path.move(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: pointerCenterX - halfPointer, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: pointerCenterX, y: bounds.minY))
        path.addLine(to: CGPoint(x: pointerCenterX + halfPointer, y: bodyRect.minY))
        path.addLine(to: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY))
        path.addArc(
            center: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.minY + radius),
            radius: radius,
            startAngle: .degrees(-90),
            endAngle: .degrees(0),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY - radius))
        path.addArc(
            center: CGPoint(x: bodyRect.maxX - radius, y: bodyRect.maxY - radius),
            radius: radius,
            startAngle: .degrees(0),
            endAngle: .degrees(90),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY))
        path.addArc(
            center: CGPoint(x: bodyRect.minX + radius, y: bodyRect.maxY - radius),
            radius: radius,
            startAngle: .degrees(90),
            endAngle: .degrees(180),
            clockwise: false
        )
        path.addLine(to: CGPoint(x: bodyRect.minX, y: bodyRect.minY + radius))
        path.addArc(
            center: CGPoint(x: bodyRect.minX + radius, y: bodyRect.minY + radius),
            radius: radius,
            startAngle: .degrees(180),
            endAngle: .degrees(270),
            clockwise: false
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> MenuBarSpeechBubbleShape {
        var shape = self
        shape.insetAmount += amount
        return shape
    }
}

#if os(macOS)
private struct MenuBarBubbleAnchor: Equatable {
    let screenX: CGFloat

    static func capture(_ preferredScreenX: CGFloat? = nil) -> MenuBarBubbleAnchor {
        MenuBarBubbleAnchor(screenX: preferredScreenX ?? NSEvent.mouseLocation.x)
    }
}

private struct MenuBarBubbleWindowAccessor: NSViewRepresentable {
    let contentSize: CGSize
    let anchor: MenuBarBubbleAnchor
    @Binding var pointerX: CGFloat

    final class Coordinator {
        var hasAnimatedOpening = false
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.postsFrameChangedNotifications = true
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            MenuBarBubbleWindowController.configure(
                window,
                contentSize: contentSize,
                anchor: anchor,
                pointerX: $pointerX,
                animateOpening: !context.coordinator.hasAnimatedOpening
            )
            context.coordinator.hasAnimatedOpening = true
        }
    }
}

private enum MenuBarBubbleWindowController {
    static let fallbackPointerX: CGFloat = 54

    private static let screenPadding: CGFloat = 8

    @MainActor
    static func configure(
        _ window: NSWindow,
        contentSize: CGSize,
        anchor: MenuBarBubbleAnchor,
        pointerX: Binding<CGFloat>,
        animateOpening: Bool
    ) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.remove([.titled, .closable, .miniaturizable, .resizable])
        window.collectionBehavior.insert(.transient)

        guard let screen = window.screen ?? NSScreen.screens.first else { return }
        let desiredSize = NSSize(
            width: contentSize.width,
            height: contentSize.height + MenuBarSpeechBubbleShape.pointerHeight
        )
        let constrainedOriginX = min(
            max(anchor.screenX - desiredSize.width / 2, screen.visibleFrame.minX + screenPadding),
            screen.visibleFrame.maxX - desiredSize.width - screenPadding
        )
        let originY = screen.visibleFrame.maxY - desiredSize.height - screenPadding
        let frame = NSRect(
            x: constrainedOriginX,
            y: max(originY, screen.visibleFrame.minY + screenPadding),
            width: desiredSize.width,
            height: desiredSize.height
        )

        if animateOpening {
            animateWindowOpen(window, to: frame)
        } else if !nearlyEqual(window.frame, frame) {
            window.setFrame(frame, display: true, animate: false)
        }

        let nextPointerX = anchor.screenX - frame.minX
        if abs(pointerX.wrappedValue - nextPointerX) > 0.5 {
            pointerX.wrappedValue = nextPointerX
        }
    }

    private static func animateWindowOpen(_ window: NSWindow, to frame: NSRect) {
        let startFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y + 10,
            width: frame.width,
            height: frame.height
        )
        window.alphaValue = 0
        window.setFrame(startFrame, display: true, animate: false)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
            window.animator().setFrame(frame, display: true)
        }
    }

    private static func nearlyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
            abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
            abs(lhs.size.width - rhs.size.width) < 0.5 &&
            abs(lhs.size.height - rhs.size.height) < 0.5
    }
}
#endif // os(macOS)

// MARK: - Repo Dashboard Views

#if os(macOS)
private enum MenuBarPrimaryView {
    case dashboard
    case monitoring
    case settings
}

private enum MenuBarRenderMode {
    case compact
    case normal

    var contentSize: CGSize {
        switch self {
        case .compact:
            return CGSize(width: 560, height: 470)
        case .normal:
            return CGSize(width: 780, height: 580)
        }
    }
}

private enum RepoSortOption: String, CaseIterable, Identifiable {
    case reviewCount = "Review count"
    case name = "Name"
    case defaultFirst = "Default first"

    var id: String { rawValue }
}

private enum RepoFilterOption: String, CaseIterable, Identifiable {
    case all = "All"
    case pendingReview = "Pending review"
    case needsAttention = "Needs attention"

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .all:
            return "All"
        case .pendingReview:
            return "Pending"
        case .needsAttention:
            return "Attention"
        }
    }
}

private struct CompactAllRepositoriesSummary: View {
    let repoCount: Int
    let loadedCount: Int
    let pendingReviewCount: Int
    let openPRCount: Int
    let publishedCount: Int
    let prStateSummaries: [PRStateSummary]
    let prStatsFreshness: PRStatsFreshness
    let serverStatusText: String
    let serverStatusColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Review workflow")
                    .font(.headline)
                Spacer()
                StatusCapsule(title: "\(loadedCount)/\(repoCount) loaded", systemImage: "shippingbox", tint: .secondary)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(pendingReviewCount)")
                    .font(.title.weight(.semibold))
                    .monospacedDigit()
                Text(pendingReviewCount == 1 ? "document waiting for review" : "documents waiting for review")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(serverStatusColor)
                    .frame(width: 8, height: 8)
                Text(serverStatusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                CountBadge(value: openPRCount, label: "open PRs", tint: .blue)
                CountBadge(value: publishedCount, label: "published", tint: .secondary)
            }

            PRStateSummaryStrip(summaries: prStateSummaries)
            PRStatsFreshnessRow(freshness: prStatsFreshness)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CompactReviewQueue: View {
    let groups: [PendingPRGroup]
    let totalCount: Int
    let onOpen: (PendingPRGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Docs review queue")
                    .font(.headline)
                Spacer()
                Text("\(totalCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if groups.isEmpty {
                Text("No pull requests currently contain reviewable docs-cms documents.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(groups) { group in
                        PRReviewSummaryRow(group: group, showsRepository: true, onOpen: onOpen)
                    }
                }
            }
        }
    }
}

private struct PairingInviteBanner: View {
    let invite: PairingAdvertiser.PendingInvitation

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing request")
                    .font(.headline)
                Text("\(invite.peerName) wants to pair with this Mac.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Deny") { invite.decline() }
            Button("Allow") { invite.accept() }
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RepositoryTopRail: View {
    private static let rowHeight: CGFloat = 44

    let isSelected: Bool
    @Binding var sort: RepoSortOption
    @Binding var filter: RepoFilterOption
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                Label("All", systemImage: "tray.full")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                HStack(spacing: 4) {
                    Menu {
                        Picker("Sort", selection: $sort) {
                            ForEach(RepoSortOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                            .font(.caption2)
                    }
                    .menuStyle(.borderlessButton)

                    Menu {
                        Picker("Filter", selection: $filter) {
                            ForEach(RepoFilterOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    } label: {
                        Label(filter.shortTitle, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.caption2)
                    }
                    .menuStyle(.borderlessButton)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.secondary.opacity(0.12) : Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.24) : Color.secondary.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(height: Self.rowHeight)
    }
}

private struct ExpandedDashboardSidebarStats: View {
    let pendingReviewCount: Int
    let openPRCount: Int
    let prStateSummaries: [PRStateSummary]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                SidebarMetricCard(
                    title: "Docs",
                    value: pendingReviewCount,
                    detail: "waiting",
                    attention: pendingReviewCount > 0
                )
                SidebarMetricCard(
                    title: "PRs",
                    value: openPRCount,
                    detail: "open",
                    attention: prStateSummaries.contains { $0.descriptor.sortOrder < PRStateDescriptor.readyAggregate.sortOrder }
                )
            }
        }
    }
}

private struct SidebarMetricCard: View {
    let title: String
    let value: Int
    let detail: String
    var attention = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text("\(value)")
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            if attention {
                Rectangle()
                    .fill(Color.orange.opacity(0.75))
                    .frame(width: 3)
            }
        }
    }
}

private struct RepoFilterRow: View {
    private static let rowHeight: CGFloat = 54

    let repo: Repository
    let state: MenuBarDashboardStore.RepoState?
    let isSelected: Bool
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.fullName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(repo.fullName)
                        .layoutPriority(1)

                    Text(summaryText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .layoutPriority(1)

                Spacer(minLength: 6)

                if state?.isLoading == true {
                    ProgressView()
                        .controlSize(.small)
                        .help("Refreshing repository RFCs")
                }

                if isActive {
                    Text("Default")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.24) : Color.secondary.opacity(0.10), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .frame(height: Self.rowHeight)
        .help(helpText)
    }

    private var summaryText: String {
        if let issue = state?.issue {
            return issue.repositoryRowSummary
        }
        if state?.isLoading == true && state?.allRFCs.isEmpty != false {
            return "Loading..."
        }
        return "\(state?.pendingReviewCount ?? 0) docs · \(state?.openPRCount ?? 0) PRs"
    }

    private var background: Color {
        if isSelected {
            return Color.secondary.opacity(0.12)
        }
        return Color.secondary.opacity(0.04)
    }

    private var helpText: String {
        guard let issue = state?.issue else { return repo.fullName }
        return issue.helpText
    }
}

private struct RepoSyncIndicator: View {
    let isLoading: Bool

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .help("Refreshing repository RFCs")
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.clear)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: 18, height: 18)
    }
}

private struct CountBadge: View {
    let value: Int
    let label: String
    let tint: Color

    var body: some View {
        Text("\(value) \(label)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(0.10))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

private struct RepoMetricBadge: View {
    let systemImage: String
    let title: String
    let value: Int
    let tint: Color
    var help: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage)
                .font(.caption2.weight(.semibold))
            Text(title)
                .font(.caption2.weight(.semibold))
            Text("\(value)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, 5)
        .frame(height: 18)
        .background(tint.opacity(0.10))
        .foregroundStyle(tint)
        .clipShape(Capsule())
        .help(help ?? "")
    }
}

private struct StatusCapsule: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12))
            .foregroundStyle(tint)
            .clipShape(Capsule())
    }
}

private struct PendingRFCItem: Identifiable {
    let repo: Repository
    let rfc: RFC

    var id: String { "\(repo.id.uuidString)-\(rfc.id)" }

    var prNumber: Int? {
        if case .pullRequest(let pr) = rfc.source { return pr.number }
        return nil
    }

    var documentTypeDisplay: String {
        guard case .pullRequest(let pr) = rfc.source else { return "Doc" }
        return displayName(forDocumentType: pr.documentType)
    }
}

private struct PendingPRGroup: Identifiable {
    let repo: Repository
    let items: [PendingRFCItem]

    var id: String { "\(repo.id.uuidString)-\(pr.number)" }
    var primaryRFC: RFC { items.first?.rfc ?? RFC(id: "", title: "", path: "", sha: "", source: .pullRequest(pr), lifecycleStatus: nil, htmlURL: "") }

    var pr: RFCPullRequest {
        for item in items {
            if case .pullRequest(let pr) = item.rfc.source {
                return pr
            }
        }
        return RFCPullRequest(
            id: 0, number: 0, title: "", prTitle: "",
            prState: "open", prMerged: false, body: "",
            headSHA: "", headRef: "", htmlURL: "", state: "",
            draft: false, mergeable: nil, mergeableState: nil,
            documentType: "rfc", documentPath: "", lifecycleStatus: nil, catalogID: "",
            labels: [], changedFiles: 0,
            additions: 0, deletions: 0,
            issueCommentCount: 0, reviewCommentCount: 0
        )
    }

    var documentCount: Int { items.count }

    var documentTypeCounts: [(label: String, count: Int)] {
        let counts = Dictionary(grouping: items, by: { $0.documentTypeDisplay }).mapValues(\.count)
        return counts.keys.sorted { lhs, rhs in
            let lhsOrder = documentTypeDisplaySortOrder(lhs)
            let rhsOrder = documentTypeDisplaySortOrder(rhs)
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs < rhs
        }.map { label in
            (label: label, count: counts[label] ?? 0)
        }
    }

    static func groups(for repo: Repository, rfcs: [RFC]) -> [PendingPRGroup] {
        let items = rfcs.map { PendingRFCItem(repo: repo, rfc: $0) }
        let grouped = Dictionary(grouping: items) { $0.prNumber ?? 0 }
        return grouped.values.compactMap { items in
            guard items.first?.prNumber != nil else { return nil }
            return PendingPRGroup(repo: repo, items: items)
        }
        .sorted { lhs, rhs in lhs.pr.number > rhs.pr.number }
    }
}

private struct RepositoryReviewBucket: Identifiable {
    let repo: Repository
    let state: MenuBarDashboardStore.RepoState?

    var id: UUID { repo.id }
    var groups: [PendingPRGroup] {
        PendingPRGroup.groups(for: repo, rfcs: state?.pullRequests ?? [])
    }
    var documentCount: Int { state?.pendingReviewCount ?? groups.reduce(0) { $0 + $1.documentCount } }
    var prCount: Int { state?.openPRCount ?? groups.count }
    var isLoading: Bool { state?.isLoading ?? true }
    var issue: MenuBarIssue? { state?.issue }
}

private struct CompactRepositoryReviewBuckets: View {
    let buckets: [RepositoryReviewBucket]
    let totalRepositoryCount: Int
    let totalPRCount: Int
    let onSelectRepo: (Repository) -> Void
    let onOpen: (PendingPRGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Repository review buckets")
                    .font(.headline)
                Spacer()
                Text("\(totalPRCount) PRs")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if buckets.isEmpty {
                Text("No repositories are configured.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(buckets) { bucket in
                        CompactRepositoryReviewBucketRow(
                            bucket: bucket,
                            onSelectRepo: onSelectRepo,
                            onOpen: onOpen
                        )
                    }
                }

                if totalRepositoryCount > buckets.count {
                    Text("\(totalRepositoryCount - buckets.count) more repositories")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

private struct CompactRepositoryReviewBucketRow: View {
    let bucket: RepositoryReviewBucket
    let onSelectRepo: (Repository) -> Void
    let onOpen: (PendingPRGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onSelectRepo(bucket.repo)
            } label: {
                RepositoryBucketHeader(bucket: bucket, compact: true)
            }
            .buttonStyle(.plain)

            if let issue = bucket.issue {
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.repositoryRowSummary)
                        .font(.caption)
                        .foregroundStyle(issue.tint)
                        .lineLimit(2)
                    if let url = issue.actionURL {
                        Link(issue.actionLabel, destination: url)
                            .font(.caption.weight(.semibold))
                            .tint(issue.tint)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
                .help(issue.helpText)
            } else if bucket.groups.isEmpty {
                Text(bucket.isLoading ? "Calculating from cached basis..." : "No review documents waiting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)
            } else {
                ForEach(bucket.groups.prefix(2)) { group in
                    PRReviewSummaryRow(group: group, onOpen: onOpen)
                }
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RepositoryReviewBucketsSection: View {
    let buckets: [RepositoryReviewBucket]
    let totalPRCount: Int
    let totalDocumentCount: Int
    let emptyText: String
    let onSelectRepo: (Repository) -> Void
    let onOpen: (PendingPRGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Repositories with review work")
                    .font(.headline)
                Spacer()
                Text("\(visibleBuckets.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if visibleBuckets.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(visibleBuckets) { bucket in
                        RepositoryReviewBucketCard(
                            bucket: bucket,
                            onSelectRepo: onSelectRepo,
                            onOpen: onOpen
                        )
                    }
                }
            }
        }
    }

    private var visibleBuckets: [RepositoryReviewBucket] {
        buckets.filter { bucket in
            bucket.documentCount > 0 || bucket.issue != nil
        }
    }
}

private struct RepositoryReviewBucketCard: View {
    let bucket: RepositoryReviewBucket
    let onSelectRepo: (Repository) -> Void
    let onOpen: (PendingPRGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                onSelectRepo(bucket.repo)
            } label: {
                RepositoryBucketHeader(bucket: bucket, compact: false)
            }
            .buttonStyle(.plain)

            if let issue = bucket.issue {
                Label(issue.repositoryRowSummary, systemImage: issue.systemImage)
                    .font(.caption)
                    .foregroundStyle(issue.tint)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(issue.tint.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .lineLimit(2)
                    .help(issue.helpText)
            } else if bucket.groups.isEmpty {
                Text(bucket.isLoading ? "Calculating this repository from the cached basis..." : "No review documents waiting in this repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                VStack(spacing: 6) {
                    ForEach(bucket.groups) { group in
                        PRReviewSummaryRow(group: group, onOpen: onOpen)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.10), lineWidth: 1)
        )
    }
}

private struct RepositoryBucketHeader: View {
    let bucket: RepositoryReviewBucket
    var compact = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bucket.repo.fullName)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(bucket.repo.fullName)
                Text(bucket.repo.docsPath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            if bucket.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .help("Refreshing from source of truth")
            }
            Text("\(bucket.documentCount) docs · \(bucket.prCount) PRs")
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

private struct RepositoryBucketMetric: View {
    let value: Int
    let label: String
    let systemImage: String
    let tint: Color
    var compact = false
    var trailingSystemImage: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        Group {
            if let action {
                Button(action: action) {
                    content
                }
                .buttonStyle(.plain)
                .help("Open \(label)")
            } else {
                content
            }
        }
    }

    private var content: some View {
        HStack(spacing: compact ? 4 : 6) {
            Image(systemName: systemImage)
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.bold))
            Text("\(value)")
                .font(compact ? .caption.weight(.bold) : .title3.weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.caption2.weight(.semibold))
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, compact ? 7 : 10)
        .frame(height: compact ? 24 : 34)
        .background(tint.opacity(0.12))
        .foregroundStyle(tint)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(tint.opacity(0.20), lineWidth: 1)
        )
        .accessibilityLabel("\(value) \(label)")
    }
}

@MainActor
private func repositoryPullRequestsURL(for repo: Repository) -> URL? {
    guard let connection = AccountStore.shared.connections.first(where: { $0.id == repo.accountID }) else {
        return nil
    }
    guard var components = URLComponents(string: connection.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)),
          components.scheme != nil,
          components.host != nil else {
        return nil
    }

    if components.host?.lowercased() == "api.github.com" {
        components.host = "github.com"
        components.path = ""
    } else {
        let apiSuffixes = ["/api/v3", "/api/v1"]
        for suffix in apiSuffixes where components.path.lowercased().hasSuffix(suffix) {
            components.path = String(components.path.dropLast(suffix.count))
            break
        }
    }

    components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let basePath = components.path.isEmpty ? "" : "/" + components.path
    components.path = "\(basePath)/\(repo.owner)/\(repo.name)/pulls"
    components.query = nil
    components.fragment = nil
    return components.url
}

private struct PRReviewSection: View {
    let title: String
    let groups: [PendingPRGroup]
    let emptyText: String
    var showsRepository = false
    let onOpen: (PendingPRGroup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(groups.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }

            if groups.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(groups) { group in
                        PRReviewSummaryRow(group: group, showsRepository: showsRepository, onOpen: onOpen)
                    }
                }
            }
        }
    }
}

private struct PRReviewSummaryRow: View {
    @Environment(\.openURL) private var openURL

    let group: PendingPRGroup
    var showsRepository = false
    let onOpen: (PendingPRGroup) -> Void
    @State private var isDescriptionExpanded = false

    var body: some View {
        let pr = group.pr
        let descriptor = PRStateDescriptor.describe(pr)
        let description = prDescriptionContent(pr.body)
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("#\(pr.number)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()

                    Text(prTitle(pr))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)

                    Spacer(minLength: 8)

                    PRMergeStateBadge(descriptor: descriptor)
                }

                Text(metadataText(pr))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let description {
                    PRDescriptionInlineView(
                        blocks: isDescriptionExpanded ? description.fullBlocks : description.excerptBlocks,
                        isExpanded: isDescriptionExpanded
                    )
                    .padding(.top, 2)

                    if description.canExpand {
                        Button {
                            withAnimation(.easeInOut(duration: 0.16)) {
                                isDescriptionExpanded.toggle()
                            }
                        } label: {
                            Label(
                                isDescriptionExpanded ? "Show less" : "Read full description",
                                systemImage: isDescriptionExpanded ? "chevron.up" : "chevron.down"
                            )
                            .font(.caption.weight(.medium))
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help(isDescriptionExpanded ? "Collapse PR description" : "Expand full PR description")
                    }
                }
            }
            .layoutPriority(1)

            HStack(alignment: .center, spacing: 6) {
                Menu {
                    if prChangesURL(pr) != nil {
                        Button {
                            openPRChanges(pr)
                        } label: {
                            Label("Review changes", systemImage: "doc.text.viewfinder")
                        }
                    }
                    if prURL(pr) != nil {
                        Button {
                            openPR(pr)
                        } label: {
                            Label("Open pull request", systemImage: "arrow.up.right.square")
                        }
                        Button {
                            copyPRLink(pr)
                        } label: {
                            Label("Copy PR link", systemImage: "link")
                        }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 18)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .help("Jump to review actions")

                Button {
                    onOpen(group)
                } label: {
                    Label("Review", systemImage: "arrow.right")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open review documents")
            }
            .fixedSize()
        }
        .padding(10)
        .padding(.leading, descriptor.attentionTint == nil ? 0 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.035))
        .overlay(alignment: .leading) {
            if let tint = descriptor.attentionTint {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(tint)
                    .frame(width: 3)
                    .padding(.vertical, 8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(descriptor.help)
    }

    private func prTitle(_ pr: RFCPullRequest) -> String {
        if !pr.prTitle.isEmpty { return pr.prTitle }
        if !pr.title.isEmpty { return pr.title }
        return "Pull request"
    }

    private func changedFiles(_ pr: RFCPullRequest) -> Int {
        pr.changedFiles > 0 ? pr.changedFiles : group.documentCount
    }

    private func contextText(_ pr: RFCPullRequest) -> String {
        let prefix = showsRepository ? "\(group.repo.fullName) • " : ""
        let branch = pr.headRef.isEmpty ? "unknown branch" : pr.headRef
        return "\(prefix)\(branch)"
    }

    private func metadataText(_ pr: RFCPullRequest) -> String {
        let comments = pr.issueCommentCount + pr.reviewCommentCount
        let commentText = comments == 1 ? "1 comment" : "\(comments) comments"
        return "\(contextText(pr)) · \(group.documentCount) docs · \(changedFiles(pr)) files · +\(pr.additions)/-\(pr.deletions) · \(commentText)"
    }

    private func prURL(_ pr: RFCPullRequest) -> URL? {
        URL(string: pr.htmlURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func prChangesURL(_ pr: RFCPullRequest) -> URL? {
        guard var urlString = prURL(pr)?.absoluteString else { return nil }
        urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: urlString + "/changes")
    }

    private func openPR(_ pr: RFCPullRequest) {
        guard let url = prURL(pr) else { return }
        openURL(url)
    }

    private func openPRChanges(_ pr: RFCPullRequest) {
        guard let url = prChangesURL(pr) else { return }
        openURL(url)
    }

    private func copyPRLink(_ pr: RFCPullRequest) {
        guard let urlString = prURL(pr)?.absoluteString else { return }
#if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlString, forType: .string)
#elseif os(iOS)
        UIPasteboard.general.string = urlString
#endif
    }
}

private struct PRDescriptionContent {
    let excerptBlocks: [MarkdownBlock]
    let fullBlocks: [MarkdownBlock]

    var canExpand: Bool {
        fullBlocks.count > excerptBlocks.count
    }
}

private struct PRDescriptionInlineView: View {
    let blocks: [MarkdownBlock]
    let isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 8 : 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                PRDescriptionInlineBlockView(block: block, isExpanded: isExpanded)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PRDescriptionInlineBlockView: View {
    let block: MarkdownBlock
    let isExpanded: Bool

    var body: some View {
        switch block {
        case .heading(_, let inlines, _, _):
            Text(prMarkdownAttributedString(inlines))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(isExpanded ? nil : 1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let inlines, _, _):
            Text(prMarkdownAttributedString(inlines))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        case .blockquote(let inlines, _, _):
            HStack(alignment: .top, spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 2)
                Text(prMarkdownAttributedString(inlines))
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? nil : 2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .bulletList(let items, _, _):
            compactList(items: items, ordered: false)
        case .orderedList(let items, _, _):
            compactList(items: items, ordered: true)
        case .codeBlock(let language, let code, _, _):
            let prefix = language.isEmpty ? "" : "\(language)\n"
            Text(prefix + code)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 3)
                .truncationMode(.tail)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        case .table(let headers, let rows, _, _):
            Text(compactTableText(headers: headers, rows: rows))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        case .mermaidBlock:
            Text("Mermaid diagram")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .horizontalRule:
            Divider()
        }
    }

    private func compactList(items: [MarkdownBlock.ListItem], ordered: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.prefix(isExpanded ? items.count : 2).enumerated()), id: \.offset) { index, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(ordered ? "\(index + 1)." : "•")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(width: ordered ? 18 : 10, alignment: .trailing)
                    Text(prMarkdownAttributedString(item.inlines))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 12)
            }
        }
    }
}

private func cleanPRMarkdown(_ markdown: String) -> String {
    var output: [String] = []
    var insideHTMLComment = false
    for rawLine in markdown.components(separatedBy: .newlines) {
        var line = rawLine
        if insideHTMLComment {
            if let end = line.range(of: "-->") {
                line = String(line[end.upperBound...])
                insideHTMLComment = false
            } else {
                continue
            }
        }
        while let start = line.range(of: "<!--") {
            if let end = line.range(of: "-->", range: start.upperBound..<line.endIndex) {
                line.removeSubrange(start.lowerBound..<end.upperBound)
            } else {
                line = String(line[..<start.lowerBound])
                insideHTMLComment = true
                break
            }
        }
        output.append(line)
    }
    return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func prDescriptionContent(_ markdown: String) -> PRDescriptionContent? {
    let meaningful = meaningfulPRMarkdown(markdown)
    guard !meaningful.isEmpty else { return nil }

    let blocks = MarkdownParser.parse(meaningful).filter { !isEmptyPRDescriptionBlock($0) }
    guard !blocks.isEmpty else { return nil }

    let excerpt = prDescriptionExcerptBlocks(from: blocks)
    guard !excerpt.isEmpty else { return nil }
    return PRDescriptionContent(excerptBlocks: excerpt, fullBlocks: blocks)
}

private func meaningfulPRMarkdown(_ markdown: String) -> String {
    let cleaned = cleanPRMarkdown(markdown)
    guard !cleaned.isEmpty else { return "" }

    let rawLines = cleaned.components(separatedBy: .newlines)
    let filtered = rawLines.filter { line in
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("opens a new hermit review session for ") { return false }
        if lower.hasPrefix("previous pr:") { return false }
        if lower == "<!-- hermit-review-session -->" { return false }
        return true
    }
    return filtered.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

private func prDescriptionExcerptBlocks(from blocks: [MarkdownBlock]) -> [MarkdownBlock] {
    guard let headingIndex = blocks.firstIndex(where: { block in
        if case .heading = block { return true }
        return false
    }) else {
        return Array(blocks.prefix(1))
    }

    var excerpt = [blocks[headingIndex]]
    if let textIndex = blocks[(headingIndex + 1)...].firstIndex(where: isPRDescriptionTextChunk) {
        excerpt.append(blocks[textIndex])
    }
    return excerpt
}

private func isPRDescriptionTextChunk(_ block: MarkdownBlock) -> Bool {
    switch block {
    case .paragraph, .blockquote, .bulletList, .orderedList, .codeBlock, .table:
        return !markdownBlockPlainText(block).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    case .heading, .horizontalRule, .mermaidBlock:
        return false
    }
}

private func isEmptyPRDescriptionBlock(_ block: MarkdownBlock) -> Bool {
    markdownBlockPlainText(block).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

private func compactTableText(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> String {
    let headerText = headers
        .map(markdownInlinePlainText)
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
    guard !rows.isEmpty else { return headerText }
    let firstRow = rows[0]
        .map(markdownInlinePlainText)
        .filter { !$0.isEmpty }
        .joined(separator: " | ")
    return [headerText, firstRow].filter { !$0.isEmpty }.joined(separator: "\n")
}

private func prMarkdownAttributedString(_ inlines: [MarkdownInline]) -> AttributedString {
    inlines.reduce(AttributedString()) { partialResult, inline in
        partialResult + prMarkdownAttributedString(inline)
    }
}

private func prMarkdownAttributedString(_ inline: MarkdownInline) -> AttributedString {
    switch inline {
    case .text(let string):
        return AttributedString(string)
    case .bold(let children):
        var attributed = prMarkdownAttributedString(children)
        attributed.font = .caption.bold()
        return attributed
    case .italic(let children):
        var attributed = prMarkdownAttributedString(children)
        attributed.font = .caption.italic()
        return attributed
    case .code(let string):
        var attributed = AttributedString(string)
        attributed.font = .caption.monospaced()
        attributed.backgroundColor = Color.secondary.opacity(0.10)
        return attributed
    case .link(let text, let url):
        var attributed = AttributedString(text)
        if let linkURL = URL(string: url) {
            attributed.link = linkURL
        }
        attributed.foregroundColor = .accentColor
        return attributed
    case .image(let alt, _):
        var attributed = AttributedString("[\(alt)]")
        attributed.foregroundColor = .secondary
        return attributed
    }
}

private func markdownBlockPlainText(_ block: MarkdownBlock) -> String {
    switch block {
    case .heading(_, let inlines, _, _), .paragraph(let inlines, _, _), .blockquote(let inlines, _, _):
        return markdownInlinePlainText(inlines)
    case .bulletList(let items, _, _), .orderedList(let items, _, _):
        return items.prefix(2).map { markdownInlinePlainText($0.inlines) }.joined(separator: " ")
    case .codeBlock(let language, let code, _, _):
        let prefix = language.isEmpty ? "" : "\(language): "
        return prefix + code.split(separator: "\n", omittingEmptySubsequences: false).prefix(1).joined()
    case .table(let headers, _, _, _):
        return headers.map(markdownInlinePlainText).filter { !$0.isEmpty }.joined(separator: " | ")
    case .mermaidBlock:
        return "Mermaid diagram"
    case .horizontalRule:
        return ""
    }
}

private func markdownInlinePlainText(_ inlines: [MarkdownInline]) -> String {
    inlines.map(markdownInlinePlainText).joined()
}

private func markdownInlinePlainText(_ inline: MarkdownInline) -> String {
    switch inline {
    case .text(let string), .code(let string):
        return string
    case .bold(let children), .italic(let children):
        return markdownInlinePlainText(children)
    case .link(let text, _):
        return text
    case .image(let alt, _):
        return alt
    }
}

private struct ProminentPRBadge: View {
    let pr: RFCPullRequest

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.pull")
                .font(.caption.weight(.bold))
            Text("#\(pr.number)")
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
            if !pr.htmlURL.isEmpty {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.accentColor.opacity(0.75))
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Color.accentColor.opacity(0.13))
        .foregroundStyle(Color.accentColor)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
        .help(pr.htmlURL.isEmpty ? "Pull request #\(pr.number)" : "Pull request #\(pr.number): \(pr.htmlURL)")
    }
}

private struct DocumentMixStrip: View {
    let counts: [(label: String, count: Int)]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(counts, id: \.label) { item in
                StatusBadge(title: "\(item.label) \(item.count)", systemImage: documentTypeSystemImage(item.label), tint: .secondary, compact: true)
            }
        }
    }
}

private struct PRMetricItem {
    let label: String
    let value: String
    let tint: Color
}

private struct PRMetricStrip: View {
    let items: [PRMetricItem]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(items, id: \.label) { item in
                    PRMetricTile(item: item)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ForEach(Array(items.prefix(2)), id: \.label) { item in
                        PRMetricTile(item: item)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(Array(items.dropFirst(2)), id: \.label) { item in
                        PRMetricTile(item: item)
                    }
                }
            }
        }
    }
}

private struct PRMetricTile: View {
    let item: PRMetricItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(item.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 64, alignment: .leading)
    }
}

private struct PRSummarySection: View {
    let title: String
    let items: [PendingRFCItem]
    let emptyText: String
    var showsRepository = false
    let onOpen: (PendingRFCItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(items.count)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.secondary.opacity(0.10))
                    .foregroundStyle(.secondary)
                    .clipShape(Capsule())
            }

            if items.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            onOpen(item)
                        } label: {
                            PRSummaryRow(
                                rfc: item.rfc,
                                repoName: showsRepository ? item.repo.fullName : nil
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct PRStateSummarySection: View {
    let title: String
    let items: [PendingRFCItem]
    let emptyText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Text("\(uniquePRCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if summaries.isEmpty {
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 8) {
                    ForEach(summaries) { summary in
                        HStack(spacing: 10) {
                            StatusBadge(
                                title: summary.descriptor.title,
                                systemImage: summary.descriptor.systemImage,
                                tint: summary.descriptor.tint,
                                compact: true,
                                help: summary.descriptor.help
                            )

                            Text(summary.examplesText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Spacer(minLength: 8)

                            Text("\(summary.count)")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8)
                                .frame(height: 22)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
    }

    private var summaries: [PRStateSummary] {
        PRStateSummary.summarize(items)
    }

    private var uniquePRCount: Int {
        Set(items.compactMap { item -> String? in
            guard let prNumber = item.prNumber else { return nil }
            return "\(item.repo.id.uuidString)-\(prNumber)"
        }).count
    }
}

private struct PRStateSummary: Identifiable {
    let descriptor: PRStateDescriptor
    var count = 0
    var examples: [String] = []

    var id: String { descriptor.title }

    var examplesText: String {
        guard !examples.isEmpty else { return "No repositories" }
        return examples.joined(separator: ", ")
    }

    static func summarize(_ items: [PendingRFCItem]) -> [PRStateSummary] {
        var grouped: [String: PRStateSummary] = [:]
        let uniqueItems = Dictionary(grouping: items) { item in
            "\(item.repo.id.uuidString)-\(item.prNumber ?? 0)"
        }
        .values
        .compactMap(\.first)

        for item in uniqueItems {
            guard case .pullRequest(let pr) = item.rfc.source else { continue }
            let descriptor = PRStateDescriptor.describe(pr)
            var summary = grouped[descriptor.title] ?? PRStateSummary(descriptor: descriptor)
            summary.count += 1
            if summary.examples.count < 2 {
                summary.examples.append(pr.prTitle.isEmpty ? item.rfc.title : pr.prTitle)
            }
            grouped[descriptor.title] = summary
        }

        return grouped.values.sorted {
            if $0.descriptor.sortOrder != $1.descriptor.sortOrder {
                return $0.descriptor.sortOrder < $1.descriptor.sortOrder
            }
            return $0.descriptor.title < $1.descriptor.title
        }
    }

    static func summarize(_ counts: PRStateCounts) -> [PRStateSummary] {
        [
            PRStateSummary(descriptor: .conflictedAggregate, count: counts.conflicted),
            PRStateSummary(descriptor: .failedAggregate, count: counts.failed),
            PRStateSummary(descriptor: .readyAggregate, count: counts.ready),
            PRStateSummary(descriptor: .needsReviewAggregate, count: counts.needsReview)
        ].filter { $0.count > 0 }
    }
}

private struct PRStateSummaryStrip: View {
    let summaries: [PRStateSummary]

    var body: some View {
        if !summaries.isEmpty {
            HStack(spacing: 6) {
                ForEach(summaries) { summary in
                    StatusBadge(
                        title: "\(summary.descriptor.title) \(summary.count)",
                        systemImage: summary.descriptor.systemImage,
                        tint: summary.descriptor.tint,
                        compact: true,
                        help: summary.descriptor.help
                    )
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PRStatsFreshness {
    let loadedRepositoryCount: Int
    let totalRepositoryCount: Int
    let failedRepositoryCount: Int
    let authFailureCount: Int
    let pendingRepositoryCount: Int
    let newestLoadedAt: Date?
    let isLoading: Bool

    var label: String {
        if authFailureCount > 0 {
            return "\(loadedRepositoryCount)/\(totalRepositoryCount) loaded • \(authFailureCount) need authentication"
        }
        if failedRepositoryCount > 0 {
            return "\(loadedRepositoryCount)/\(totalRepositoryCount) loaded • \(failedRepositoryCount) failed"
        }
        if loadedRepositoryCount == 0 {
            return isLoading ? "Calculating from source of truth" : "PR stats not loaded"
        }
        if isLoading {
            return "Refreshing \(pendingRepositoryCount) repos • \(loadedRepositoryCount)/\(totalRepositoryCount) loaded"
        }
        if loadedRepositoryCount < totalRepositoryCount {
            return "Partial PR stats • \(loadedRepositoryCount)/\(totalRepositoryCount) repos"
        }
        guard let newestLoadedAt else {
            return "PR stats loaded"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relativeDate = formatter.localizedString(for: newestLoadedAt, relativeTo: Date())
        return "Updated \(relativeDate)"
    }

    var tint: Color {
        if authFailureCount > 0 || failedRepositoryCount > 0 {
            return .orange
        }
        if loadedRepositoryCount == 0 || loadedRepositoryCount < totalRepositoryCount {
            return .secondary
        }
        return .green
    }

    var systemImage: String {
        if authFailureCount > 0 { return "key.slash" }
        if failedRepositoryCount > 0 { return "exclamationmark.triangle" }
        if isLoading { return "arrow.triangle.2.circlepath" }
        if loadedRepositoryCount == 0 || loadedRepositoryCount < totalRepositoryCount { return "clock" }
        return "checkmark.circle"
    }
}

private struct PRStatsFreshnessRow: View {
    let freshness: PRStatsFreshness

    var body: some View {
        Label(freshness.label, systemImage: freshness.systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(freshness.tint)
            .lineLimit(1)
    }
}

private struct AllRepositoriesSection: View {
    let repoCount: Int
    let loadedCount: Int
    let prStatsFreshness: PRStatsFreshness

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Review workflow")
                        .font(.title3.weight(.semibold))
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    private var statusText: String {
        let loaded = "\(loadedCount) of \(repoCount) repositories loaded"
        if prStatsFreshness.authFailureCount > 0 {
            let prefix = prStatsFreshness.authFailureCount > max(repoCount / 2, 0)
                ? "Most repositories need authentication"
                : "\(prStatsFreshness.authFailureCount) repositories need authentication"
            return "\(prefix) · \(loaded)"
        }
        if prStatsFreshness.failedRepositoryCount > 0 {
            return "\(loaded) · \(prStatsFreshness.failedRepositoryCount) failed"
        }
        if prStatsFreshness.isLoading {
            return "\(loaded) · refreshing \(prStatsFreshness.pendingRepositoryCount)"
        }
        if let newestLoadedAt = prStatsFreshness.newestLoadedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return "\(loaded) · updated \(formatter.localizedString(for: newestLoadedAt, relativeTo: Date()))"
        }
        return loaded
    }

}

private struct SelectedRepoSection: View {
    let repo: Repository
    let state: MenuBarDashboardStore.RepoState?
    let isActive: Bool
    let onActivate: () -> Void
    let onRefresh: () -> Void
    let onOpenSettings: () -> Void
    let onOpenPR: (RFC) -> Void
    let onOpen: (RFC) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(repo.fullName)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(repo.fullName)
                        Text(repo.docsPath)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        if isActive {
                            StatusBadge(title: "Default", tint: .green)
                        } else {
                            Button("Make Active", action: onActivate)
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                        }
                        Button("Refresh", action: onRefresh)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        if state?.isLoading == true {
                            StatusCapsule(title: "Syncing", systemImage: "arrow.triangle.2.circlepath", tint: .secondary)
                        }
                    }
                    .fixedSize()
                }

                if let state {
                    HStack(spacing: 8) {
                        CountBadge(value: state.pullRequests.count, label: "review", tint: .secondary)
                        CountBadge(value: state.mainBranch.count, label: "published", tint: .secondary)
                    }
                }
            }

            if let issue = state?.issue {
                RepositoryIssueStrip(issue: issue, onRetry: onRefresh, onSettings: onOpenSettings)
            }

            if state?.isLoading == true && state?.allRFCs.isEmpty != false {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Loading repository details…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 8)
            }

            if let state {
                PRStateSummarySection(
                    title: "PR states",
                    items: state.pullRequests.map { PendingRFCItem(repo: repo, rfc: $0) },
                    emptyText: "No pull request state data is available yet."
                )

                PRReviewSection(
                    title: "Pull requests needing review",
                    groups: PendingPRGroup.groups(for: repo, rfcs: state.pullRequests),
                    emptyText: "No pull requests currently contain reviewable docs-cms documents.",
                    onOpen: { group in onOpenPR(group.primaryRFC) }
                )

                PRSummarySection(
                    title: "Documents needing review",
                    items: state.pullRequests.map { PendingRFCItem(repo: repo, rfc: $0) },
                    emptyText: "No docs-cms documents are currently waiting for review.",
                    onOpen: { item in onOpenPR(item.rfc) }
                )

                let groups = RFCStatusGroup.group(state.mainBranch)
                ForEach(groups.filter { !$0.rfcs.isEmpty }, id: \.header) { group in
                    RFCCollectionSection(title: group.header, rfcs: group.rfcs, emptyText: "", symbol: group.systemImage, onOpen: onOpen)
                }
            }
        }
    }
}

private struct RFCCollectionSection: View {
    let title: String
    let rfcs: [RFC]
    let emptyText: String
    var symbol: String = "doc.text"
    let onOpen: (RFC) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(.headline)
                Spacer()
                Text("\(rfcs.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            if rfcs.isEmpty {
                if !emptyText.isEmpty {
                    Text(emptyText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(rfcs) { rfc in
                        Button {
                            onOpen(rfc)
                        } label: {
                            RFCSummaryRow(rfc: rfc, trailingSystemImage: "chevron.right")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct PRSummaryRow: View {
    let rfc: RFC
    var repoName: String? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProminentPRBadge(pr: pr)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    PRMergeStateBadge(pr: pr)
                }

                HStack(spacing: 6) {
                    StatusBadge(title: displayName(forDocumentType: pr.documentType), systemImage: "doc.text", tint: .secondary)
                    if let labelTitle {
                        StatusBadge(title: labelTitle, tint: .secondary)
                    }
                }

                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)

            ReviewDocumentsCallToAction(documentCount: 1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .help("Open pull request summary")
    }

    private var pr: RFCPullRequest {
        if case .pullRequest(let pr) = rfc.source { return pr }
        return RFCPullRequest(
            id: 0, number: 0, title: "", prTitle: "",
            prState: "open", prMerged: false, body: "",
            headSHA: "", headRef: "", htmlURL: "", state: "",
            draft: false, mergeable: nil, mergeableState: nil,
            documentType: "rfc", documentPath: "", lifecycleStatus: nil, catalogID: "",
            labels: [], changedFiles: 0,
            additions: 0, deletions: 0,
            issueCommentCount: 0, reviewCommentCount: 0
        )
    }

    private var title: String {
        rfc.title.isEmpty ? "RFC pull request" : rfc.title
    }

    private var labelTitle: String? {
        guard let first = pr.labels.first else { return nil }
        if let separator = first.firstIndex(of: ":") {
            return String(first[first.index(after: separator)...])
        }
        return first
    }

    private var secondaryText: String {
        let detail = pr.headRef.isEmpty ? rfc.path : pr.headRef
        let prTitle = pr.prTitle.isEmpty ? "" : " • \(pr.prTitle)"
        if let repoName {
            return "\(repoName) • \(detail)\(prTitle)"
        }
        return "\(detail)\(prTitle)"
    }
}

private func displayName(forDocumentType documentType: String) -> String {
    switch documentType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "adr":
        return "ADR"
    case "memo":
        return "Memo"
    case "prd":
        return "PRD"
    case "rfc", "":
        return "RFC"
    default:
        return documentType.replacingOccurrences(of: "-", with: " ").capitalized
    }
}

private func documentTypeDisplaySortOrder(_ label: String) -> Int {
    switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "adr":
        return 10
    case "prd":
        return 20
    case "rfc":
        return 30
    case "memo":
        return 40
    default:
        return 100
    }
}

private func documentTypeSystemImage(_ label: String) -> String {
    switch label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "adr":
        return "building.columns"
    case "memo":
        return "note.text"
    case "prd":
        return "doc.plaintext"
    case "rfc":
        return "doc.text"
    default:
        return "doc"
    }
}

private struct ReviewQueueCallToAction: View {
    let value: Int
    var help: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.bubble")
                .font(.caption2.weight(.semibold))
            Text(value > 0 ? "Open queue" : "Review")
                .font(.caption2.weight(.semibold))
            Text("\(value)")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
        }
        .padding(.horizontal, value > 0 ? 8 : 5)
        .frame(height: 18)
        .background(Color.accentColor.opacity(0.14))
        .foregroundStyle(Color.accentColor)
        .clipShape(Capsule())
        .fixedSize(horizontal: true, vertical: false)
        .help(help ?? "")
        .accessibilityLabel(value > 0 ? "Open review queue with \(value) documents" : "No documents waiting for review")
    }
}

private struct ReviewDocumentsCallToAction: View {
    let documentCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(Color.accentColor)
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(title)
    }

    private var title: String {
        documentCount == 1 ? "Review doc" : "Review \(documentCount) docs"
    }
}

private struct PRMergeStateBadge: View {
    let descriptor: PRStateDescriptor

    init(pr: RFCPullRequest) {
        descriptor = PRStateDescriptor.describe(pr)
    }

    init(descriptor: PRStateDescriptor) {
        self.descriptor = descriptor
    }

    var body: some View {
        StatusBadge(
            title: descriptor.title,
            systemImage: descriptor.systemImage,
            tint: descriptor.tint,
            compact: true,
            help: descriptor.help
        )
            .fixedSize()
    }
}

private struct PRStateDescriptor {
    let title: String
    let systemImage: String
    let tint: Color
    let help: String
    let sortOrder: Int

    var attentionTint: Color? {
        switch title {
        case "CI failed", "Conflicted":
            return .red
        case "Needs review":
            return .orange
        case "Ready to land":
            return .green
        default:
            return nil
        }
    }

    static let conflictedAggregate = aggregate(
        title: "Conflicted",
        help: "Open PRs that are not mergeable or report a conflict state.",
        sortOrder: 10
    )
    static let failedAggregate = aggregate(
        title: "CI failed",
        help: "Open PRs with failing or unstable checks.",
        sortOrder: 20
    )
    static let readyAggregate = aggregate(
        title: "Ready to land",
        help: "Open PRs that are currently mergeable.",
        sortOrder: 30
    )
    static let needsReviewAggregate = aggregate(
        title: "Needs review",
        help: "Open PRs still waiting on review or provider merge-state resolution.",
        sortOrder: 40
    )

    static func describe(_ pr: RFCPullRequest) -> PRStateDescriptor {
        let topLevelState = pr.prState.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if pr.prMerged {
            return PRStateDescriptor(
                title: "Merged",
                systemImage: "checkmark.seal.fill",
                tint: .purple,
                help: "Pull request has been merged.",
                sortOrder: 50
            )
        }
        if topLevelState == "closed" {
            return PRStateDescriptor(
                title: "Closed",
                systemImage: "xmark.circle.fill",
                tint: .secondary,
                help: "Pull request is closed.",
                sortOrder: 60
            )
        }

        let normalizedState = (pr.mergeableState ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if pr.draft {
            return descriptor(title: "Needs review", rawState: pr.mergeableState, sortOrder: 40)
        }
        if normalizedState.contains("dirty") || normalizedState.contains("conflict") {
            return descriptor(title: "Conflicted", rawState: pr.mergeableState, sortOrder: 10)
        }

        switch normalizedState {
        case "clean":
            return descriptor(title: "Ready to land", rawState: pr.mergeableState, sortOrder: 30)
        case "blocked":
            return descriptor(title: "Needs review", rawState: pr.mergeableState, sortOrder: 40)
        case "behind":
            return descriptor(title: "Needs review", rawState: pr.mergeableState, sortOrder: 40)
        case "unstable":
            return descriptor(title: "CI failed", rawState: pr.mergeableState, sortOrder: 20)
        case "has_hooks":
            return descriptor(title: "Needs review", rawState: pr.mergeableState, sortOrder: 40)
        case "unknown":
            return descriptor(title: "Needs review", rawState: pr.mergeableState, sortOrder: 40)
        default:
            if pr.mergeable == true {
                return descriptor(title: "Ready to land", rawState: pr.mergeableState, sortOrder: 30)
            }
            if pr.mergeable == false {
                return descriptor(title: "Conflicted", rawState: pr.mergeableState, sortOrder: 10)
            }
            return descriptor(title: "Needs review", rawState: pr.mergeableState, sortOrder: 40)
        }
    }

    private static func descriptor(title: String, rawState: String?, sortOrder: Int) -> PRStateDescriptor {
        let help: String
        if let rawState, !rawState.isEmpty {
            switch title {
            case "CI failed":
                help = "Checks are failing or unstable. Provider merge state: \(rawState)"
            case "Ready to land":
                help = "Pull request is mergeable. Provider merge state: \(rawState)"
            case "Needs review":
                help = "Pull request needs review or merge-state resolution. Provider merge state: \(rawState)"
            default:
                help = "Provider merge state: \(rawState)"
            }
        } else {
            help = "Provider merge state is not available yet."
        }

        return PRStateDescriptor(
            title: title,
            systemImage: systemImage(for: title),
            tint: tint(for: title),
            help: help,
            sortOrder: sortOrder
        )
    }

    private static func aggregate(title: String, help: String, sortOrder: Int) -> PRStateDescriptor {
        PRStateDescriptor(
            title: title,
            systemImage: systemImage(for: title),
            tint: tint(for: title),
            help: help,
            sortOrder: sortOrder
        )
    }

    private static func systemImage(for title: String) -> String {
        switch title {
        case "Ready to land":
            return "checkmark.circle.fill"
        case "Conflicted":
            return "exclamationmark.triangle.fill"
        case "CI failed":
            return "xmark.octagon.fill"
        case "Needs review":
            return "clock.fill"
        default:
            return "questionmark.circle"
        }
    }

    private static func tint(for title: String) -> Color {
        switch title {
        case "Ready to land":
            return .green
        case "Conflicted":
            return .red
        case "CI failed":
            return .red
        case "Needs review":
            return .orange
        default:
            return .secondary
        }
    }
}

private struct RFCSummaryRow: View {
    let rfc: RFC
    var repoName: String? = nil
    let trailingSystemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text(rfc.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)

                HStack(spacing: 6) {
                    sourceBadge
                    if let statusTitle {
                        StatusBadge(title: statusTitle, tint: statusTint)
                    }
                    if let labelTitle {
                        StatusBadge(title: labelTitle, tint: .secondary)
                    }
                }

                Text(secondaryText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: trailingSystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var sourceBadge: some View {
        switch rfc.source {
        case .mainBranch:
            StatusBadge(title: "Published", systemImage: "checkmark.circle.fill", tint: .blue)
        case .pullRequest(let pr):
            StatusBadge(title: "PR #\(pr.number)", systemImage: "arrow.triangle.pull", tint: .orange)
        }
    }

    private var statusTitle: String? {
        if case .pullRequest(let pr) = rfc.source, pr.draft {
            return "Draft"
        }
        guard let lifecycleStatus = rfc.lifecycleStatus else { return nil }
        return lifecycleStatus.replacingOccurrences(of: "-", with: " ").capitalized
    }

    private var statusTint: Color {
        switch rfc.lifecycleStatus ?? "" {
        case "accepted":
            return .green
        case "draft":
            return .orange
        case "implemented":
            return .blue
        case "superseded", "rejected":
            return .secondary
        default:
            if case .pullRequest = rfc.source { return .orange }
            return .secondary
        }
    }

    private var labelTitle: String? {
        guard case .pullRequest(let pr) = rfc.source,
              let first = pr.labels.first else { return nil }
        if let separator = first.firstIndex(of: ":") {
            return String(first[first.index(after: separator)...])
        }
        return first
    }

    private var secondaryText: String {
        let detail: String
        switch rfc.source {
        case .mainBranch:
            detail = (rfc.path as NSString).lastPathComponent
        case .pullRequest(let pr):
            detail = pr.headRef
        }

        if let repoName {
            return "\(repoName) • \(detail)"
        }
        return detail
    }
}

private struct StatusBadge: View {
    let title: String
    var systemImage: String? = nil
    let tint: Color
    var compact: Bool = false
    var help: String? = nil

    var body: some View {
        Group {
            if let systemImage {
                Label(title, systemImage: systemImage)
            } else {
                Text(title)
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, compact ? 6 : 8)
        .frame(height: compact ? 18 : 22)
        .background(tint.opacity(0.12))
        .foregroundStyle(tint)
        .clipShape(Capsule())
        .help(help ?? "")
    }
}

private struct RepositoryIssueStrip: View {
    let issue: MenuBarIssue
    let onRetry: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: issue.systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(issue.tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(displayMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                    if let url = issue.actionURL {
                        Link(destination: url) {
                            Label(issue.actionLabel, systemImage: "arrow.up.right.square")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(issue.tint)
                        .controlSize(.small)
                    }
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button("Settings", action: onSettings)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(issue.tint.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(issue.tint.opacity(0.16), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help(helpText)
    }

    private var displayTitle: String {
        issue.title
    }

    private var displayMessage: String {
        if issue.message.localizedCaseInsensitiveContains("connection refused") {
            return "Git provider is unreachable. Existing cached data remains available when present."
        }
        if issue.message.localizedCaseInsensitiveContains("docs-project.yaml") {
            return "Hermit could not read the repository docs configuration from the git provider."
        }
        return issue.message
    }

    private var helpText: String {
        issue.helpText
    }
}

private struct IssueBanner: View {
    let issue: MenuBarIssue
    var compact: Bool = false
    var onRetry: (() -> Void)? = nil
    var onSettings: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: issue.systemImage)
                    .foregroundStyle(issue.tint)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(issue.title)
                        .font(compact ? .subheadline.weight(.semibold) : .headline)
                    Text(issue.message)
                        .font(compact ? .caption : .subheadline)
                        .foregroundStyle(.secondary)
                    if let recovery = issue.recovery {
                        Text(recovery)
                            .font(compact ? .caption : .footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let url = issue.actionURL {
                        Link(issue.actionLabel, destination: url)
                            .font(compact ? .caption.weight(.semibold) : .footnote.weight(.semibold))
                            .tint(issue.tint)
                            .padding(.top, 2)
                    }
                }

                Spacer(minLength: 8)
            }

            HStack(spacing: 10) {
                if let onRetry {
                    Button("Retry", action: onRetry)
                        .buttonStyle(.bordered)
                        .controlSize(compact ? .small : .regular)
                }
                if let onSettings {
                    Button("Settings", action: onSettings)
                        .buttonStyle(.borderless)
                        .controlSize(compact ? .small : .regular)
                }
            }
        }
        .padding(compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(issue.tint.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(issue.tint.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct MonitoringTabView: View {
    let repositories: [Repository]
    let serverPort: Int?
    let serverIssue: MenuBarIssue?
    let repositoryStats: RepositorySyncStats
    let dashboardStats: DashboardSyncStats
    let states: [UUID: MenuBarDashboardStore.RepoState]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    MonitoringStatCard(title: "Connectivity", value: connectivityValue, subtitle: connectivitySubtitle, tint: connectivityTint)
                    MonitoringStatCard(title: "API calls/hr", value: "\(repositoryStats.apiCallsLastHour + dashboardStats.apiCallsLastHour)", subtitle: "Menu + RFC refreshes", tint: .blue)
                    MonitoringStatCard(title: "Refreshes", value: "\(repositoryStats.successes + dashboardStats.successes)", subtitle: "\(repositoryStats.failures + dashboardStats.failures) failures", tint: .green)
                }

                HStack(spacing: 12) {
                    MonitoringStatCard(title: "Repositories", value: "\(repositories.count)", subtitle: "\(loadedRepositoryCount) loaded", tint: .secondary)
                    MonitoringStatCard(title: "Cache hits", value: "\(dashboardStats.cacheHits)", subtitle: "Local menu cache", tint: .purple)
                    MonitoringStatCard(title: "Pending review", value: "\(pendingReviewCount)", subtitle: "\(openPRCount) open PRs", tint: .orange)
                }

                MonitoringSection(title: "Documents Seen") {
                    MonitoringMetricRow(label: "Published", value: "\(publishedCount)")
                    MonitoringMetricRow(label: "In review", value: "\(reviewCount)")
                    ForEach(statusRows, id: \.label) { row in
                        MonitoringMetricRow(label: row.label, value: "\(row.value)")
                    }
                }

                MonitoringSection(title: "Refresh Activity") {
                    MonitoringMetricRow(label: "Repository list attempts", value: "\(repositoryStats.attempts)")
                    MonitoringMetricRow(label: "Repository list failures", value: "\(repositoryStats.failures)")
                    MonitoringMetricRow(label: "RFC refresh attempts", value: "\(dashboardStats.attempts)")
                    MonitoringMetricRow(label: "RFC refresh failures", value: "\(dashboardStats.failures)")
                    MonitoringMetricRow(label: "Last repository refresh", value: repositoryStats.lastAttemptLabel)
                    MonitoringMetricRow(label: "Last RFC refresh", value: dashboardStats.lastAttemptLabel)
                }
            }
            .padding(16)
        }
    }

    private var connectivityValue: String {
        if serverPort != nil && serverIssue == nil { return "Online" }
        if serverPort != nil { return "Degraded" }
        return "Offline"
    }

    private var connectivitySubtitle: String {
        if let serverIssue { return serverIssue.shortTitle }
        if let serverPort { return "Port \(serverPort)" }
        return "Server unavailable"
    }

    private var connectivityTint: Color {
        if serverPort != nil && serverIssue == nil { return .green }
        return .orange
    }

    private var loadedRepositoryCount: Int {
        states.values.filter { !$0.allRFCs.isEmpty || $0.issue != nil }.count
    }

    private var pendingReviewCount: Int {
        states.values.reduce(0) { $0 + $1.pendingReviewCount }
    }

    private var openPRCount: Int {
        states.values.reduce(0) { $0 + $1.openPRCount }
    }

    private var publishedCount: Int {
        states.values.reduce(0) { $0 + $1.mainBranch.count }
    }

    private var reviewCount: Int {
        states.values.reduce(0) { $0 + $1.pullRequests.count }
    }

    private var statusRows: [(label: String, value: Int)] {
        var counts: [String: Int] = [:]
        for state in states.values {
            for rfc in state.mainBranch {
                let status = rfc.lifecycleStatus?.replacingOccurrences(of: "-", with: " ").capitalized ?? "Unknown"
                counts[status, default: 0] += 1
            }
        }
        return counts
            .map { ($0.key, $0.value) }
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.label < rhs.label
            }
    }
}

private struct MonitoringStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MonitoringSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                content
            }
            .background(Color.secondary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }
}

private struct MonitoringMetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}
#endif

// MARK: - Data Stores

private struct RepositorySyncStats {
    var attempts = 0
    var successes = 0
    var failures = 0
    var apiCallTimes: [Date] = []
    var lastAttemptAt: Date?

    var apiCallsLastHour: Int {
        let cutoff = Date().addingTimeInterval(-3600)
        return apiCallTimes.filter { $0 >= cutoff }.count
    }

    var lastAttemptLabel: String {
        guard let lastAttemptAt else { return "Never" }
        return lastAttemptAt.formatted(date: .omitted, time: .shortened)
    }

    mutating func recordAttempt() {
        attempts += 1
        let now = Date()
        lastAttemptAt = now
        apiCallTimes.append(now)
        prune()
    }

    mutating func recordSuccess() {
        successes += 1
    }

    mutating func recordFailure() {
        failures += 1
    }

    private mutating func prune() {
        let cutoff = Date().addingTimeInterval(-3600)
        apiCallTimes.removeAll { $0 < cutoff }
    }
}

private struct DashboardSyncStats {
    var attempts = 0
    var successes = 0
    var failures = 0
    var cacheHits = 0
    var apiCallTimes: [Date] = []
    var lastAttemptAt: Date?

    var apiCallsLastHour: Int {
        let cutoff = Date().addingTimeInterval(-3600)
        return apiCallTimes.filter { $0 >= cutoff }.count
    }

    var lastAttemptLabel: String {
        guard let lastAttemptAt else { return "Never" }
        return lastAttemptAt.formatted(date: .omitted, time: .shortened)
    }

    mutating func recordAttempt() {
        attempts += 1
        let now = Date()
        lastAttemptAt = now
        apiCallTimes.append(now)
        prune()
    }

    mutating func recordSuccess() {
        successes += 1
    }

    mutating func recordFailure() {
        failures += 1
    }

    mutating func recordCacheHit() {
        cacheHits += 1
    }

    private mutating func prune() {
        let cutoff = Date().addingTimeInterval(-3600)
        apiCallTimes.removeAll { $0 < cutoff }
    }
}

@MainActor
private final class ServerRepositoryMenuStore: ObservableObject {
    @Published private(set) var repositories: [Repository] = []
    @Published private(set) var issue: MenuBarIssue? = nil
    @Published private(set) var stats = RepositorySyncStats()

    private var task: Task<Void, Never>? = nil

    func start(portProvider: @escaping @MainActor () -> Int?, accountIDProvider: @escaping @MainActor () -> UUID?) {
        guard task == nil else { return }
        task = Task { @MainActor in
            while !Task.isCancelled {
                await refresh(port: portProvider(), accountID: accountIDProvider())
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh(port: Int?, accountID: UUID?) async {
        guard let port,
              let url = URL(string: "http://127.0.0.1:\(port)/api/v1/repositories") else { return }
        stats.recordAttempt()
        menuBarDebugLog("[ServerRepositoryMenuStore] refresh start port=\(port)")
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                stats.recordFailure()
                issue = menuIssue(
                    forHTTPStatus: (response as? HTTPURLResponse)?.statusCode,
                    message: httpErrorMessage(from: data, fallback: "The embedded server could not list repositories.")
                )
                menuBarDebugLog("[ServerRepositoryMenuStore] refresh error status")
                return
            }
            struct Item: Decodable {
                let id: String
                let owner: String
                let name: String
                let docsPath: String
                let rfcLabel: String

                private enum CodingKeys: String, CodingKey {
                    case id, owner, name
                    case docsPath = "docs_path_policy"
                    case rfcLabel = "rfc_label"
                }
            }
            struct Page: Decodable { let items: [Item] }
            let page = try JSONDecoder().decode(Page.self, from: data)
            let fallbackAccountID = accountID ?? UUID()
            let previousRepositories = repositories
            let persistedRepositories = RepositoryStore.shared.repositories
            let nextRepositories = page.items.map { item in
                let existing = previousRepositories.first(where: { repo in
                    repo.serverID == item.id ||
                    (repo.owner.caseInsensitiveCompare(item.owner) == .orderedSame &&
                     repo.name.caseInsensitiveCompare(item.name) == .orderedSame)
                }) ?? persistedRepositories.first(where: { repo in
                    repo.serverID == item.id ||
                    (repo.owner.caseInsensitiveCompare(item.owner) == .orderedSame &&
                     repo.name.caseInsensitiveCompare(item.name) == .orderedSame)
                })

                return Repository(
                    id: existing?.id ?? UUID(),
                    serverID: item.id,
                    accountID: existing?.accountID ?? fallbackAccountID,
                    owner: item.owner,
                    name: item.name,
                    docsPath: item.docsPath,
                    rfcLabel: item.rfcLabel
                )
            }
            repositories = nextRepositories
            issue = nil
            stats.recordSuccess()
            menuBarDebugLog("[ServerRepositoryMenuStore] refresh success repos=\(repoDebugSummary(nextRepositories))")
        } catch {
            stats.recordFailure()
            issue = menuIssue(for: error)
            menuBarDebugLog("[ServerRepositoryMenuStore] refresh failure error=\(error.localizedDescription)")
        }
    }
}

@MainActor
private final class MenuBarDashboardStore: ObservableObject {
    struct RepoState {
        var isLoading = false
        var mainBranch: [RFC] = []
        var pullRequests: [RFC] = []
        var pendingReviewCount = 0
        var openPRCount = 0
        var prStateCounts = PRStateCounts.empty
        var prStatsLoadedAt: Date? = nil
        var issue: MenuBarIssue? = nil

        var allRFCs: [RFC] { pullRequests + mainBranch }
        var priorityRFC: RFC? { pullRequests.first ?? mainBranch.first }
    }

    @Published private var states: [UUID: RepoState] = [:]
    @Published private(set) var stats = DashboardSyncStats()
    private var loadGenerations: [UUID: Int] = [:]

    func state(for repoID: UUID) -> RepoState? {
        states[repoID]
    }

    var statesSnapshot: [UUID: RepoState] {
        states
    }

    func refresh(repos: [Repository], appState: AppState, force: Bool) async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos {
                group.addTask { [weak self] in
                    await self?.load(repo: repo, appState: appState, force: force)
                }
            }
        }
    }

    func reload(repo: Repository, appState: AppState) async {
        RepoRFCCache.shared.invalidate(repo.id)
        await load(repo: repo, appState: appState, force: true)
    }

    private func load(repo: Repository, appState: AppState, force: Bool) async {
        if !force, let cached = RepoRFCCache.shared.sections(for: repo.id) {
            stats.recordCacheHit()
            setState(
                RepoState(
                    isLoading: true,
                    mainBranch: cached.mainBranch,
                    pullRequests: cached.pullRequests,
                    pendingReviewCount: cached.summary.pendingReviewCount,
                    openPRCount: cached.summary.openPRCount,
                    prStateCounts: cached.summary.prStateCounts,
                    prStatsLoadedAt: cached.loadedAt
                ),
                for: repo,
                reason: "cache-hit"
            )
        }

        let generation = nextGeneration(for: repo.id)
        stats.recordAttempt()
        menuBarDebugLog("[MenuBarDashboardStore] load start repo=\(repo.fullName) generation=\(generation) force=\(force)")

        var state = states[repo.id] ?? RepoState()
        state.isLoading = true
        setState(state, for: repo, reason: "load-start")

        guard let client = appState.makeAPIClient(for: repo) else {
            guard isCurrentGeneration(generation, for: repo.id) else { return }
            state.isLoading = false
            state.issue = .configuration(
                title: "Repository access is not configured",
                message: "Hermit could not build an authenticated API client for this repository.",
                recovery: "Open Settings and confirm the server URL, account, and token are still valid."
            )
            stats.recordFailure()
            setState(state, for: repo, reason: "no-api-client")
            return
        }

        do {
            let (mainFiles, prs, summary) = try await client.discoverRFCs()
            let mainRFCs = mainFiles.map {
                RFC(id: $0.id, title: $0.name, path: $0.path, sha: $0.sha,
                    source: .mainBranch, lifecycleStatus: $0.lifecycleStatus,
                    htmlURL: $0.htmlURL)
            }.sorted { $0.title < $1.title }
            // One entry per PR: filter to the primary RFC document using the
            // same deduplication logic as the native menu (documentType == "rfc",
            // rfc-NNN path, non-terminal lifecycle status, highest RFC number wins).
            let prRFCs = primaryPRDocuments(from: prs).map {
                RFC(id: $0.catalogID, title: $0.prTitle.isEmpty ? $0.title : $0.prTitle,
                    path: $0.documentPath, sha: $0.headSHA,
                    source: .pullRequest($0), lifecycleStatus: $0.lifecycleStatus,
                    htmlURL: $0.htmlURL)
            }.sorted { lhs, rhs in
                let lhsNumber = if case .pullRequest(let pr) = lhs.source { pr.number } else { 0 }
                let rhsNumber = if case .pullRequest(let pr) = rhs.source { pr.number } else { 0 }
                if lhsNumber != rhsNumber { return lhsNumber > rhsNumber }
                return lhs.title < rhs.title
            }

            guard isCurrentGeneration(generation, for: repo.id) else {
                menuBarDebugLog("[MenuBarDashboardStore] load stale-success ignored repo=\(repo.fullName) generation=\(generation)")
                return
            }
            let syncedAt = Date()
            let sections = RepoRFCLoader.RFCSections(
                mainBranch: mainRFCs,
                pullRequests: prRFCs,
                summary: summary,
                loadedAt: syncedAt
            )
            RepoRFCCache.shared.store(sections, for: repo.id)
            RepositoryStore.shared.markSynced(repo, at: syncedAt)
            stats.recordSuccess()
            setState(
                RepoState(
                    isLoading: false,
                    mainBranch: mainRFCs,
                    pullRequests: prRFCs,
                    pendingReviewCount: summary.pendingReviewCount,
                    openPRCount: summary.openPRCount,
                    prStateCounts: summary.prStateCounts,
                    prStatsLoadedAt: syncedAt
                ),
                for: repo,
                reason: "load-success"
            )
        } catch {
            guard isCurrentGeneration(generation, for: repo.id) else {
                menuBarDebugLog("[MenuBarDashboardStore] load stale-error ignored repo=\(repo.fullName) generation=\(generation) error=\(error.localizedDescription)")
                return
            }
            state.isLoading = false
            state.issue = menuIssue(for: error)
            // Propagate any SSO URL to AccountStore so the Settings account row
            // can surface the Authorize SSO link even when the /user probe
            // doesn't return an X-GitHub-SSO header.
            if let ssoURL = state.issue?.actionURL {
                AccountStore.shared.reportSSO(url: ssoURL, for: repo.accountID)
            } else {
                AccountStore.shared.clearSSO(for: repo.accountID)
            }
            stats.recordFailure()
            setState(state, for: repo, reason: "load-error")
        }
    }

    private func setState(_ newState: RepoState, for repo: Repository, reason: String) {
        let previous = states[repo.id]
        states[repo.id] = newState
        menuBarDebugLog(
            "[MenuBarDashboardStore] transition repo=\(repo.fullName) reason=\(reason) from=\(stateDebugSummary(previous)) to=\(stateDebugSummary(newState))"
        )
    }

    private func nextGeneration(for repoID: UUID) -> Int {
        let generation = (loadGenerations[repoID] ?? 0) + 1
        loadGenerations[repoID] = generation
        return generation
    }

    private func isCurrentGeneration(_ generation: Int, for repoID: UUID) -> Bool {
        loadGenerations[repoID] == generation
    }
}

private func stateDebugSummary(_ state: MenuBarDashboardStore.RepoState?) -> String {
    guard let state else { return "nil" }
    let error = state.issue?.title ?? "none"
    return "loading=\(state.isLoading),prs=\(state.pullRequests.count),main=\(state.mainBranch.count),error=\(error)"
}

private func repoDebugSummary(_ repos: [Repository]) -> String {
    repos.map { repo in
        let stableID = repo.serverID ?? repo.id.uuidString
        return "\(repo.fullName){id=\(repo.id.uuidString),serverID=\(stableID)}"
    }
    .joined(separator: ",")
}

private func menuBarDebugLog(_ message: String) {
#if DEBUG
    let line = "[\(Date())] \(message)\n"
    let logURL = URL(fileURLWithPath: "/tmp/hermit-menu-bar-debug.log")
    if let data = line.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logURL.path) {
            if let fh = try? FileHandle(forWritingTo: logURL) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            }
        } else {
            try? data.write(to: logURL)
        }
    }
#endif
}

private func menuErrorMessage(_ error: Error) -> String {
    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorCannotFindHost:
            return "DNS failure: cannot resolve host. Check VPN or network DNS."
        case NSURLErrorDNSLookupFailed:
            return "DNS lookup failed. Check VPN or network DNS."
        case NSURLErrorNotConnectedToInternet:
            return "Network offline. Check your connection."
        case NSURLErrorCannotConnectToHost:
            return "Cannot connect to host. Check VPN or server reachability."
        case NSURLErrorTimedOut:
            return "Network request timed out."
        default:
            return "Network error: \(nsError.localizedDescription)"
        }
    }
    return error.localizedDescription
}

private func conciseIssueMessage(_ message: String) -> String {
    var text = message
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    let prefixes = [
        #"^HTTP\s+\d{3}:\s*"#,
        #"^backend error:\s*"#,
        #"^repository refresh failed:\s*"#,
        #"^git integration error:\s*"#
    ]
    for prefix in prefixes {
        text = text.replacingOccurrences(of: prefix, with: "", options: [.regularExpression, .caseInsensitive])
    }

    if let jsonStart = text.firstIndex(of: "{") {
        text = String(text[..<jsonStart]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    if let statusRange = text.range(of: #":\s*\d{3}$"#, options: .regularExpression) {
        text = String(text[..<statusRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return text
}

private func httpErrorMessage(from data: Data, fallback: String) -> String {
    if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let message = object["message"] as? String,
       !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return message
    }
    if let raw = String(data: data, encoding: .utf8),
       !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return raw
    }
    return fallback
}

private struct MenuBarIssue: Equatable {
    let title: String
    let shortTitle: String
    let message: String
    let recovery: String?
    let systemImage: String
    let tint: Color
    /// Optional deep-link that lets the user resolve the issue directly —
    /// used for SAML SSO authorization, token rotation pages, etc.
    var actionURL: URL? = nil
    var actionLabel: String = "Open"

    static func configuration(title: String, message: String, recovery: String?) -> MenuBarIssue {
        MenuBarIssue(
            title: title,
            shortTitle: "Config",
            message: message,
            recovery: recovery,
            systemImage: "gearshape.2",
            tint: .orange
        )
    }

    var repositoryRowSummary: String {
        let summary = conciseIssueMessage(message)
        if !summary.isEmpty { return summary }
        return title
    }

    var helpText: String {
        if let recovery, !recovery.isEmpty {
            return "\(title): \(message)\n\(recovery)"
        }
        return "\(title): \(message)"
    }
}

private func isRepositoryAuthenticationIssue(_ issue: MenuBarIssue) -> Bool {
    let searchable = "\(issue.title) \(issue.shortTitle) \(issue.message) \(issue.recovery ?? "")".lowercased()
    return searchable.contains("auth")
        || searchable.contains("credential")
        || searchable.contains("token")
        || searchable.contains("bad credentials")
}

/// Extracts the SAML SSO authorization URL from a GitHub SAML enforcement
/// error message.  The URL appears after "visit " in the embedded GitHub JSON.
private func extractSAMLAuthURL(from message: String) -> URL? {
    guard message.localizedCaseInsensitiveContains("SAML") ||
          message.localizedCaseInsensitiveContains("sso") else { return nil }
    // The URL pattern GitHub embeds: https://github.com/.../sso?authorization_request=...
    let pattern = #"https://[^\s\\"]+authorization_request=[^\s\\"]+"#
    guard let range = message.range(of: pattern, options: .regularExpression) else { return nil }
    return URL(string: String(message[range]))
}

private func menuIssue(for error: Error) -> MenuBarIssue {
    if let apiError = error as? HermitAPIError {
        switch apiError {
        case .httpError(let statusCode, let message):
            return menuIssue(forHTTPStatus: statusCode, message: message)
        }
    }

    let nsError = error as NSError
    if nsError.domain == NSURLErrorDomain {
        switch nsError.code {
        case NSURLErrorNotConnectedToInternet:
            return MenuBarIssue(title: "Network offline", shortTitle: "Offline", message: "Hermit could not reach the server or git host.", recovery: "Reconnect to the network or VPN, then retry.", systemImage: "wifi.slash", tint: .orange)
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
            return MenuBarIssue(title: "DNS lookup failed", shortTitle: "DNS", message: "The configured host name could not be resolved.", recovery: "Check VPN, DNS, or the server URL in Settings.", systemImage: "network.slash", tint: .orange)
        case NSURLErrorCannotConnectToHost, NSURLErrorTimedOut:
            return MenuBarIssue(title: "Server unreachable", shortTitle: "Offline", message: "Hermit could not complete the request to the backend.", recovery: "Verify the backend is running and reachable, then retry.", systemImage: "bolt.horizontal.circle", tint: .orange)
        default:
            return MenuBarIssue(title: "Network error", shortTitle: "Network", message: nsError.localizedDescription, recovery: "Retry the request. If it persists, check network and backend connectivity.", systemImage: "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90", tint: .orange)
        }
    }

    return MenuBarIssue(title: "Git integration error", shortTitle: "Git", message: menuErrorMessage(error), recovery: "Retry the request. If it persists, inspect repo access, branch state, and backend logs.", systemImage: "exclamationmark.triangle", tint: .orange)
}

private func menuIssue(forHTTPStatus statusCode: Int?, message: String) -> MenuBarIssue {
    // GitHub SAML SSO enforcement — arrives as 502 (Go maps GitHub 403 → 502).
    // The error body embeds a URL the user must visit to authorize the token.
    if let ssoURL = extractSAMLAuthURL(from: message) {
        return MenuBarIssue(
            title: "GitHub SSO authorization required",
            shortTitle: "SSO",
            message: "Your token must be authorized for this organization's SAML SSO before Hermit can access the repository.",
            recovery: "Click 'Authorize SSO' to open GitHub and grant access, then retry.",
            systemImage: "person.badge.key",
            tint: .orange,
            actionURL: ssoURL,
            actionLabel: "Authorize SSO"
        )
    }

    if let statusCode, (500...599).contains(statusCode) {
        return MenuBarIssue(title: "Repository refresh failed", shortTitle: "Refresh", message: message, recovery: "The local Hermit service failed while refreshing repository data from the git provider. Retry, then inspect backend logs if needed.", systemImage: "server.rack", tint: .orange)
    }

    switch statusCode {
    case 401:
        return .configuration(title: "Authentication required", message: message, recovery: "Open Settings and refresh the account token used for this repository.")
    case 403:
        return MenuBarIssue(title: "Repository access denied", shortTitle: "Access", message: message, recovery: "This account can reach the server but lacks permission for the repository or action.", systemImage: "lock.slash", tint: .orange)
    case 404:
        return MenuBarIssue(title: "Repository not available", shortTitle: "Missing", message: message, recovery: "The repository may not be registered on the backend yet, or the selected repo no longer matches server state.", systemImage: "shippingbox.slash", tint: .orange)
    case 422:
        return MenuBarIssue(title: "Git action was rejected", shortTitle: "Rejected", message: message, recovery: "The git provider rejected the operation. Check branch state, review state, or repo policy, then retry.", systemImage: "arrow.uturn.left.circle", tint: .orange)
    default:
        return MenuBarIssue(title: "Integration error", shortTitle: "Issue", message: message, recovery: "Retry the request. If it persists, inspect the backend and repository configuration.", systemImage: "exclamationmark.triangle", tint: .orange)
    }
}

// MARK: - RFC cache

@MainActor
final class RepoRFCCache {
    static let shared = RepoRFCCache()
    private let defaultsKey = "hermit.menuBar.rfcProjectionCache.v1"
    private var cache: [UUID: RepoRFCLoader.RFCSections] = [:]

    private init() {
        cache = loadPersistedCache()
    }

    fileprivate func sections(for id: UUID) -> RepoRFCLoader.RFCSections? { cache[id] }
    /// Internal accessor for the native AppKit menu (HermitRepoSubMenu in HermitApp.swift).
    /// Returns mainBranch and pullRequests as a plain tuple to avoid exposing the private RepoRFCLoader type.
    func nativeSections(for id: UUID) -> (mainBranch: [RFC], pullRequests: [RFC])? {
        guard let s = cache[id] else { return nil }
        return (s.mainBranch, s.pullRequests)
    }
    fileprivate func store(_ s: RepoRFCLoader.RFCSections, for id: UUID) {
        cache[id] = s
        persist()
    }
    func invalidate(_ id: UUID) {
        cache.removeValue(forKey: id)
        persist()
    }
    func invalidateAll() {
        cache.removeAll()
        persist()
    }

    private func loadPersistedCache() -> [UUID: RepoRFCLoader.RFCSections] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let payload = try? JSONDecoder().decode([String: CachedSections].self, from: data) else {
            return [:]
        }

        var next: [UUID: RepoRFCLoader.RFCSections] = [:]
        for (rawID, cached) in payload {
            guard let id = UUID(uuidString: rawID) else { continue }
            next[id] = cached.sections
        }
        return next
    }

    private func persist() {
        let payload = Dictionary(uniqueKeysWithValues: cache.map { id, sections in
            (id.uuidString, CachedSections(sections))
        })
        if let data = try? JSONEncoder().encode(payload) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    private struct CachedSections: Codable {
        let mainBranch: [CachedRFC]
        let pullRequests: [CachedRFC]
        let summary: CachedSummary
        let loadedAt: Date

        init(_ sections: RepoRFCLoader.RFCSections) {
            mainBranch = sections.mainBranch.map(CachedRFC.init)
            pullRequests = sections.pullRequests.map(CachedRFC.init)
            summary = CachedSummary(sections.summary)
            loadedAt = sections.loadedAt
        }

        var sections: RepoRFCLoader.RFCSections {
            RepoRFCLoader.RFCSections(
                mainBranch: mainBranch.compactMap(\.rfc),
                pullRequests: pullRequests.compactMap(\.rfc),
                summary: summary.repositorySummary,
                loadedAt: loadedAt
            )
        }
    }

    private struct CachedSummary: Codable {
        let pendingReviewCount: Int
        let openPRCount: Int
        let ready: Int
        let conflicted: Int
        let failed: Int
        let needsReview: Int

        init(_ summary: RepositoryRFCSummary) {
            pendingReviewCount = summary.pendingReviewCount
            openPRCount = summary.openPRCount
            ready = summary.prStateCounts.ready
            conflicted = summary.prStateCounts.conflicted
            failed = summary.prStateCounts.failed
            needsReview = summary.prStateCounts.needsReview
        }

        var repositorySummary: RepositoryRFCSummary {
            RepositoryRFCSummary(
                pendingReviewCount: pendingReviewCount,
                openPRCount: openPRCount,
                prStateCounts: PRStateCounts(
                    ready: ready,
                    conflicted: conflicted,
                    failed: failed,
                    needsReview: needsReview
                )
            )
        }
    }

    private struct CachedRFC: Codable {
        let id: String
        let title: String
        let path: String
        let sha: String
        let lifecycleStatus: String?
        let htmlURL: String
        let pullRequest: CachedPullRequest?

        init(_ rfc: RFC) {
            id = rfc.id
            title = rfc.title
            path = rfc.path
            sha = rfc.sha
            lifecycleStatus = rfc.lifecycleStatus
            htmlURL = rfc.htmlURL
            if case .pullRequest(let pr) = rfc.source {
                pullRequest = CachedPullRequest(pr)
            } else {
                pullRequest = nil
            }
        }

        var rfc: RFC? {
            if let pullRequest {
                return RFC(
                    id: id,
                    title: title,
                    path: path,
                    sha: sha,
                    source: .pullRequest(pullRequest.pullRequest),
                    lifecycleStatus: lifecycleStatus,
                    htmlURL: htmlURL
                )
            }
            return RFC(
                id: id,
                title: title,
                path: path,
                sha: sha,
                source: .mainBranch,
                lifecycleStatus: lifecycleStatus,
                htmlURL: htmlURL
            )
        }
    }

    private struct CachedPullRequest: Codable {
        let id: Int
        let number: Int
        let title: String
        let prTitle: String
        let prState: String
        let prMerged: Bool
        let body: String
        let headSHA: String
        let headRef: String
        let htmlURL: String
        let state: String
        let draft: Bool
        let mergeable: Bool?
        let mergeableState: String?
        let documentType: String
        let documentPath: String
        let catalogID: String
        let labels: [String]
        let changedFiles: Int
        let additions: Int
        let deletions: Int
        let issueCommentCount: Int
        let reviewCommentCount: Int
        let lifecycleStatus: String?

        enum CodingKeys: String, CodingKey {
            case id, number, title, prTitle, prState, prMerged, body
            case headSHA, headRef, htmlURL, state, draft, mergeable, mergeableState
            case documentType, documentPath, catalogID, labels
            case changedFiles, additions, deletions, issueCommentCount, reviewCommentCount
            case lifecycleStatus
        }

        init(_ pr: RFCPullRequest) {
            id = pr.id; number = pr.number; title = pr.title; prTitle = pr.prTitle
            prState = pr.prState; prMerged = pr.prMerged; body = pr.body
            headSHA = pr.headSHA; headRef = pr.headRef; htmlURL = pr.htmlURL
            state = pr.state; draft = pr.draft; mergeable = pr.mergeable
            mergeableState = pr.mergeableState; documentType = pr.documentType
            documentPath = pr.documentPath; catalogID = pr.catalogID; labels = pr.labels
            changedFiles = pr.changedFiles; additions = pr.additions; deletions = pr.deletions
            issueCommentCount = pr.issueCommentCount; reviewCommentCount = pr.reviewCommentCount
            lifecycleStatus = pr.lifecycleStatus
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(Int.self, forKey: .id)
            number = try container.decode(Int.self, forKey: .number)
            title = try container.decode(String.self, forKey: .title)
            prTitle = try container.decode(String.self, forKey: .prTitle)
            prState = try container.decode(String.self, forKey: .prState)
            prMerged = try container.decode(Bool.self, forKey: .prMerged)
            body = try container.decodeIfPresent(String.self, forKey: .body) ?? ""
            headSHA = try container.decode(String.self, forKey: .headSHA)
            headRef = try container.decode(String.self, forKey: .headRef)
            htmlURL = try container.decode(String.self, forKey: .htmlURL)
            state = try container.decode(String.self, forKey: .state)
            draft = try container.decode(Bool.self, forKey: .draft)
            mergeable = try container.decodeIfPresent(Bool.self, forKey: .mergeable)
            mergeableState = try container.decodeIfPresent(String.self, forKey: .mergeableState)
            documentType = try container.decode(String.self, forKey: .documentType)
            documentPath = try container.decode(String.self, forKey: .documentPath)
            catalogID = try container.decode(String.self, forKey: .catalogID)
            labels = try container.decode([String].self, forKey: .labels)
            changedFiles = try container.decode(Int.self, forKey: .changedFiles)
            additions = try container.decode(Int.self, forKey: .additions)
            deletions = try container.decode(Int.self, forKey: .deletions)
            issueCommentCount = try container.decodeIfPresent(Int.self, forKey: .issueCommentCount) ?? 0
            reviewCommentCount = try container.decodeIfPresent(Int.self, forKey: .reviewCommentCount) ?? 0
            lifecycleStatus = try container.decodeIfPresent(String.self, forKey: .lifecycleStatus)
        }

        var pullRequest: RFCPullRequest {
            RFCPullRequest(
                id: id, number: number, title: title, prTitle: prTitle,
                prState: prState, prMerged: prMerged, body: body,
                headSHA: headSHA, headRef: headRef, htmlURL: htmlURL, state: state,
                draft: draft, mergeable: mergeable, mergeableState: mergeableState,
                documentType: documentType, documentPath: documentPath,
                lifecycleStatus: lifecycleStatus,
                catalogID: catalogID, labels: labels, changedFiles: changedFiles,
                additions: additions, deletions: deletions,
                issueCommentCount: issueCommentCount, reviewCommentCount: reviewCommentCount
            )
        }
    }
}

@MainActor
private enum RepoRFCLoader {
    struct RFCSections {
        let mainBranch: [RFC]
         let pullRequests: [RFC]
         let summary: RepositoryRFCSummary
         let loadedAt: Date
     }
 }

