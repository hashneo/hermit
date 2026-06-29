import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - hermit-ii0: RFCDetailView — native markdown viewer with gutter comment markers
// hermit-8q5: Reading Mode — full-screen RFC view with swipe-to-restore sidebar
// hermit-ec7: RFC window toolbar — export/print/share + lifecycle transitions

struct RFCDetailView: View {
    let rfc: RFC
    var repo: Repository? = nil
    var commentStore: CommentStore? = nil
    var onLineTapped: ((Int, Int) -> Void)? = nil
    /// Called after the PR is successfully squash-merged so the parent can
    /// deselect the RFC and reload the list from the main branch.
    var onMerged: (() -> Void)? = nil

    // hermit-d42: isReadingMode is a @Binding so the parent (MenuBarRFCBrowserView)
    // can react to changes and hide/show the NavigationSplitView sidebar.
    // A .constant(false) default keeps all other call sites working unchanged.
    @Binding var isReadingMode: Bool

    // hermit-d42: only show the reading-mode toolbar button when this view is
    // embedded in a NavigationSplitView that has a sidebar to hide.
    // Standalone NSWindow usage (HermitNativeApp, iPad) sets this to false.
    var hasSidebar: Bool = false

    @EnvironmentObject private var appState: AppState

    // Observed so toolbar re-evaluates when comments load/change.
    @ObservedObject private var liveStore: CommentStore

    @State private var markdown: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var actionError: String? = nil  // merge/accept errors surfaced as alert
    @State private var isBehind = false       // true when PR branch is behind base
    /// For PR RFCs: the GitHub blob URL pointing directly to the RFC file on the PR branch.
    @State private var resolvedFileURL: String = ""
    /// The actual .md file path on the PR branch (e.g. "docs-cms/rfcs/rfc-070-...md").
    @State private var resolvedFilePath: String = ""
    /// True when the loaded PR RFC frontmatter already says status: accepted —
    /// meaning the accept commit was made but the PR was not yet merged.
    @State private var prAlreadyAccepted: Bool = false
    /// Bumped by the reload button to re-trigger .task without navigating away.
    @State private var reloadToken = UUID()

    // hermit-ec7: toolbar state
    @State private var callerPermission: String = "none"
    @State private var lifecycleError: String? = nil
    @State private var currentRFC: RFC         // mutable copy so status refreshes after transition
    // hermit-cns: PR RFC approval state
    @State private var prApproved: Bool = false
    @State private var isCIPassing: Bool = false
    // PR review state — count of outstanding CHANGES_REQUESTED reviews
    @State private var pendingReviewCount: Int = 0
    @State private var currentUserLogin: String = ""
    @State private var prAuthorLogin: String = ""

    private struct ReviewSheetContext: Identifiable {
        let id = UUID()
        let client: any HermitClientProtocol
        let prNumber: Int
        let submitMode: PRReviewSheet.SubmitMode
        // Line-comment fields — only used when submitMode == .lineComment
        let filePath: String
        let firstLineFingerprint: String
    }
    @State private var reviewSheetContext: ReviewSheetContext? = nil

    init(rfc: RFC, repo: Repository? = nil,
         commentStore: CommentStore? = nil,
         onLineTapped: ((Int, Int) -> Void)? = nil,
         onMerged: (() -> Void)? = nil,
         isReadingMode: Binding<Bool> = .constant(false),
         hasSidebar: Bool = false) {
        self.rfc          = rfc
        self.repo         = repo
        self.commentStore = commentStore
        self.onLineTapped = onLineTapped
        self.onMerged     = onMerged
        self._isReadingMode = isReadingMode
        self.hasSidebar   = hasSidebar
        self._currentRFC  = State(initialValue: rfc)
        self.liveStore    = commentStore ?? CommentStore()
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = errorMessage {
                ContentUnavailableView("Load Failed", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else {
                rfcContentView
            }
        }
        .navigationTitle(currentRFC.title)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 4) {
                    Button { scrollToPrev() } label: { Image(systemName: "chevron.up") }
                        .disabled(liveStore.commentedLines(blockRanges: blockRanges).isEmpty)
                        .help("Previous comment")
                    Button { scrollToNext() } label: { Image(systemName: "chevron.down") }
                        .disabled(liveStore.commentedLines(blockRanges: blockRanges).isEmpty)
                        .help("Next comment")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button { reloadToken = UUID() } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(isLoading)
                    .help("Reload this RFC")
            }
            // hermit-d42: only show reading-mode toggle when there is a sidebar
            // to hide — standalone NSWindow usage has no NavigationSplitView.
            if hasSidebar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        withAnimation { isReadingMode.toggle() }
                    } label: {
                        Label(
                            isReadingMode ? "Show Sidebar" : "Reading Mode",
                            systemImage: isReadingMode ? "sidebar.left" : "book.pages"
                        )
                    }
                    .help(isReadingMode
                          ? "Show sidebar (or swipe right)"
                          : "Reading Mode — expand RFC to full window")
                }
            }

            // hermit-ec7: export/print/share + lifecycle toolbar
            RFCLifecycleToolbar(
                rfc: currentRFC,
                fileURL: resolvedFileURL,
                callerPermission: callerPermission,
                onMarkImplemented: handleMarkImplemented,
                onApproveAndMerge: {
                    guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient(),
                          case .pullRequest(let pr) = rfc.source else {
                        return AcceptRFCResult(merged: false, blockedByCI: false, commitSHA: "")
                    }
                    // Only approve if not the PR author — GitHub forbids self-approval.
                    let isOwnPR = !prAuthorLogin.isEmpty && !currentUserLogin.isEmpty
                                  && prAuthorLogin == currentUserLogin
                    if !isOwnPR {
                        do {
                            try await client.approve(prNumber: pr.number)
                            prApproved = true
                        } catch {
                            actionError = error.localizedDescription
                            return AcceptRFCResult(merged: false, blockedByCI: false, commitSHA: "")
                        }
                    }
                    // Accept (rewrite frontmatter) + attempt merge for everyone.
                    do {
                        let result = try await client.acceptRFC(prNumber: pr.number, filePath: resolvedFilePath)
                        // Mark accepted immediately so Merge button enables without waiting for reload.
                        prAlreadyAccepted = true
                        if isOwnPR { prApproved = true }
                        if result.merged { onMerged?() } else { reloadToken = UUID() }
                        return result
                    } catch {
                        actionError = error.localizedDescription
                        return AcceptRFCResult(merged: false, blockedByCI: false, commitSHA: "")
                    }
                },
                allThreadsResolved: commentStore?.comments.allSatisfy(\.resolved) ?? true,
                prApproved: prApproved,
                isCIPassing: isCIPassing,
                prAlreadyAccepted: prAlreadyAccepted,
                onMergePR: {
                    guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient(),
                          case .pullRequest(let pr) = rfc.source else {
                        return MergePRResult(merged: false, blockedByCI: false)
                    }
                    do {
                        let result = try await client.mergePR(prNumber: pr.number)
                        if result.merged { onMerged?() }
                        return result
                    } catch {
                        actionError = error.localizedDescription
                        return MergePRResult(merged: false, blockedByCI: false)
                    }
                },
                onPollCI: { sha in
                    guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient() else { return false }
                    for _ in 0..<40 {
                        try? await Task.sleep(for: .seconds(15))
                        let status = (try? await client.getCIStatus(commitSHA: sha)) ?? "pending"
                        if status == "success" { return true }
                        if status == "failure" { return false }
                    }
                    return false
                },
                isBehind: isBehind,
                onUpdateBranch: {
                    guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient(),
                          case .pullRequest(let pr) = rfc.source else { return }
                    try? await client.updateBranch(prNumber: pr.number)
                    if let status = try? await client.getMergeStatus(prNumber: pr.number) {
                        isBehind = status
                    }
                },
                pendingReviewCount: pendingReviewCount,
                onOpenReviews: {
                    guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient(),
                          case .pullRequest(let pr) = currentRFC.source else { return }
                    let isOwnPR = !prAuthorLogin.isEmpty && !currentUserLogin.isEmpty
                                  && prAuthorLogin == currentUserLogin
                    let filePath = resolvedFilePath.isEmpty ? rfc.path : resolvedFilePath
                    let firstLine = markdown.components(separatedBy: "\n").first ?? ""
                    reviewSheetContext = ReviewSheetContext(
                        client: client,
                        prNumber: pr.number,
                        submitMode: isOwnPR ? .lineComment : .requestChanges,
                        filePath: filePath,
                        firstLineFingerprint: Self.makeFingerprint(firstLine)
                    )
                },
                isContentLoading: isLoading,
                markdownSource: markdown
            )
        }
        .sheet(item: $reviewSheetContext) { ctx in
            PRReviewSheet(
                rfcTitle: currentRFC.title,
                currentUserLogin: currentUserLogin,
                submitMode: ctx.submitMode,
                onSubmit: { body in
                    if ctx.submitMode == .lineComment {
                        _ = try await ctx.client.createReviewComment(
                            prNumber: ctx.prNumber,
                            body: body,
                            filePath: ctx.filePath,
                            lineStart: 1,
                            lineEnd: 1,
                            textFingerprint: ctx.firstLineFingerprint
                        )
                    } else {
                        try await ctx.client.requestChanges(prNumber: ctx.prNumber, body: body)
                        await refreshPendingReviewCount(client: ctx.client, prNumber: ctx.prNumber)
                    }
                },
                onDismiss: { reviewID in
                    try await ctx.client.dismissReview(prNumber: ctx.prNumber, reviewID: reviewID, message: "Review dismissed.")
                    await refreshPendingReviewCount(client: ctx.client, prNumber: ctx.prNumber)
                },
                onRefresh: {
                    try await ctx.client.listPRReviews(prNumber: ctx.prNumber)
                },
                onFetchThreads: {
                    try await ctx.client.listReviewComments(prNumber: ctx.prNumber)
                },
                onDeleteThread: { threadID in
                    try await ctx.client.deleteReviewComment(prNumber: ctx.prNumber, threadId: threadID)
                },
                isAccepted: prAlreadyAccepted
            )
        }
        .overlay(lifecycleErrorBanner, alignment: .top)
        .task(id: rfc.id) { await loadContent() }
        .onChange(of: reloadToken) { Task { await loadContent() } }
        .alert("Merge Failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        // hermit-8q5: swipe right restores sidebar
        .gesture(
            DragGesture()
                .onEnded { value in
                    if isReadingMode && value.translation.width > 80 {
                        withAnimation { isReadingMode = false }
                    }
                }
        )
    }

    // MARK: - Error banner

    @ViewBuilder
    private var lifecycleErrorBanner: some View {
        if let msg = lifecycleError {
            HStack {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(msg)
                    .font(.caption)
                Spacer()
                Button("Dismiss") { lifecycleError = nil }
                    .font(.caption)
            }
            .padding(8)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .padding([.horizontal, .top], 12)
        }
    }

    @State private var viewportHeight: CGFloat = 800
    @State private var scrollToLine: Int? = nil

    private var parsedBlocks: [MarkdownBlock] { MarkdownParser.parse(markdown) }
    private var blockRanges: [(start: Int, end: Int)] { parsedBlocks.map { (start: $0.sourceLine, end: $0.sourceLineEnd) } }

    private func scrollToPrev() {
        let lines = liveStore.commentedLines(blockRanges: blockRanges)
        guard !lines.isEmpty else { return }
        let current = scrollToLine ?? Int.max
        let prev = lines.last(where: { $0 < current }) ?? lines.last!
        scrollToLine = prev
    }

    private func scrollToNext() {
        let lines = liveStore.commentedLines(blockRanges: blockRanges)
        guard !lines.isEmpty else { return }
        let current = scrollToLine ?? -1
        let next = lines.first(where: { $0 > current }) ?? lines.first!
        scrollToLine = next
    }

    private var rfcContentView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                GutterMarkdownView(
                    blocks: MarkdownParser.parse(markdown),
                    onLineTapped: onLineTapped,
                    onLinkTapped: { url in handleLinkTap(url) },
                    viewportHeight: viewportHeight,
                    scrollToLine: $scrollToLine,
                    isAccepted: prAlreadyAccepted
                )
                .environmentObject(liveStore)
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { viewportHeight = proxy.size.height }
                    .onChange(of: proxy.size.height) { _, h in viewportHeight = h }
            })
            .onChange(of: scrollToLine) { _, line in
                guard let line else { return }
                withAnimation(.easeInOut(duration: 0.4)) {
                    proxy.scrollTo("line-\(line)", anchor: .center)
                }
            }
        }
    }

    // MARK: - Content loading

    private func loadContent() async {
        isLoading = true
        errorMessage = nil

        guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient() else {
            errorMessage = "Not configured."
            isLoading = false
            return
        }
        // Main branch RFCs need a path; PR RFCs use prNumber via fetchPRRFCContent
        if case .mainBranch = rfc.source, rfc.path.isEmpty {
            errorMessage = "No RFC file found on this branch."
            isLoading = false
            return
        }

        do {
            switch rfc.source {
            case .mainBranch:
                markdown = try await client.fetchRFCContent(path: rfc.path, ref: "main")
            case .pullRequest(let pr):
                let requestedPath = rfc.path.trimmingCharacters(in: .whitespacesAndNewlines)
                if !requestedPath.isEmpty && requestedPath != pr.headRef {
                    markdown = try await client.fetchPRRFCContent(prNumber: pr.number, filePath: requestedPath)
                } else {
                    markdown = try await client.fetchPRRFCContent(prNumber: pr.number)
                }
                if let login = try? await client.fetchPRAuthorLogin(prNumber: pr.number), !login.isEmpty {
                    prAuthorLogin = login
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return
        }

        // For PR RFCs: check if the frontmatter already says accepted (accept commit
        // was made but PR not yet merged — show Merge button instead of Accept & Merge).
        if case .pullRequest = rfc.source {
            prAlreadyAccepted = frontmatterStatus(markdown) == "accepted"
        }

        // For PR RFCs, build the direct blob URL to the file on the PR branch.
        // This is done regardless of whether a commentStore is present.
        if case .pullRequest(let pr) = rfc.source {
            let resolvedPath: String
            let requestedPath = rfc.path.trimmingCharacters(in: .whitespacesAndNewlines)
            if !requestedPath.isEmpty && requestedPath != pr.headRef {
                resolvedPath = requestedPath
            } else if let changed = try? await client.listPRChangedFiles(prNumber: pr.number, docsPath: ""),
               let first = changed.first, !first.isEmpty {
                resolvedPath = first
            } else {
                resolvedPath = rfc.path
            }
            resolvedFilePath = resolvedPath
            // pr.htmlURL is e.g. "https://github.com/owner/repo/pull/123"
            // -> strip "/pull/N" -> append "/blob/{headSHA}/{filePath}".
            // Use the immutable PR head SHA when available because closed/merged
            // PR branches are often deleted, which makes /blob/{headRef}/... 404.
            if URL(string: pr.htmlURL) != nil,
               let prRange = pr.htmlURL.range(of: "/pull/", options: .backwards) {
                let repoBase = String(pr.htmlURL[..<prRange.lowerBound])
                let blobRef = pr.headSHA.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? pr.headRef
                    : pr.headSHA
                resolvedFileURL = "\(repoBase)/blob/\(blobRef)/\(resolvedPath)"
            }

            // Configure and load comments if a store is present.
            if let store = commentStore {
                store.configure(
                    client: client,
                    prNumber: pr.number,
                    filePath: resolvedPath
                )
                await store.load()

                // Check whether this branch is behind the base branch (best-effort; silent on failure).
                if let behind = try? await client.getMergeStatus(prNumber: pr.number) {
                    isBehind = behind
                }
                // (approval review state no longer tracked here — accept flow handles it)
            }
        } else {
            commentStore?.reset()
            isBehind = false
        }

        isLoading = false

        // hermit-ec7: fetch caller permission level for toolbar access control
        await fetchCallerPermission(client: client)
    }

    // MARK: - Permission fetch

    private func fetchCallerPermission(client: any HermitClientProtocol) async {
        // hermit-cns: fetch permission for both main-branch and PR RFCs so
        // the Approve PR button can be gated on admin/maintain.
        do {
            callerPermission = try await client.getCallerPermission()
        } catch {
            callerPermission = "none"
        }

        // Fetch current user login for review sheet ownership checks.
        if let login = try? await client.fetchCurrentUser(), !login.isEmpty {
            currentUserLogin = login
        }

        // For PR RFCs also fetch the current review state, CI status, and pending review count.
        if case .pullRequest(let pr) = rfc.source {
            do {
                let state = try await client.getReviewState(prNumber: pr.number)
                prApproved = state.approved
            } catch {
                prApproved = false
            }
            // Fetch CI status for the PR head commit
            if !pr.headSHA.isEmpty {
                let ci = (try? await client.getCIStatus(commitSHA: pr.headSHA)) ?? "pending"
                isCIPassing = ci == "success"
            } else {
                isCIPassing = false
            }
            await refreshPendingReviewCount(client: client, prNumber: pr.number)
        }
    }

    // MARK: - Review count refresh

    @MainActor
    func refreshPendingReviewCount(client: any HermitClientProtocol, prNumber: Int) async {
        let reviews = (try? await client.listPRReviews(prNumber: prNumber)) ?? []
        pendingReviewCount = reviews.filter { $0.isChangesRequested }.count
    }

    // MARK: - Fingerprint helper (mirrors CommentStore.makeFingerprint)

    private static func makeFingerprint(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let truncated = trimmed.count > 40 ? String(trimmed.prefix(40)) : trimmed
        let slug = truncated.lowercased().replacingOccurrences(of: " ", with: "-")
        return slug.isEmpty ? "line" : slug
    }

    // MARK: - Lifecycle transition handlers

    private func handleApprove() async {
        guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient() else { return }
        do {
            let result = try await client.approveRFC(rfcID: rfc.path)
            // Refresh the displayed RFC with the new status.
            currentRFC = RFC(id: currentRFC.id, title: currentRFC.title,
                             path: currentRFC.path, sha: currentRFC.sha,
                             source: currentRFC.source,
                             lifecycleStatus: result.newStatus,
                             htmlURL: currentRFC.htmlURL)
        } catch {
            lifecycleError = error.localizedDescription
        }
    }

    private func handleMarkImplemented() async {
        guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient() else { return }
        do {
            let result = try await client.markRFCImplemented(rfcID: rfc.path)
            currentRFC = RFC(id: currentRFC.id, title: currentRFC.title,
                             path: currentRFC.path, sha: currentRFC.sha,
                             source: currentRFC.source,
                             lifecycleStatus: result.newStatus,
                             htmlURL: currentRFC.htmlURL)
        } catch {
            lifecycleError = error.localizedDescription
        }
    }

    /// Extracts the value of the `status` key from YAML frontmatter in the given markdown.
    /// Returns nil if no frontmatter or no status key is present.
    private func frontmatterStatus(_ source: String) -> String? {
        let lines = source.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }
            if trimmed.hasPrefix("status:") {
                return trimmed.dropFirst("status:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        return nil
    }

    /// Handle a link tap from the rendered RFC document.
    /// - Relative links (no scheme): resolve against the current RFC's directory,
    ///   encode as a `hermit://rfc/<path>` deep link, and open within Hermit.
    /// - Absolute links: open in the system browser.
    private func handleLinkTap(_ url: URL) {
        if url.scheme == nil || url.scheme == "" {
            // Relative path — resolve against current RFC directory
            let rfcDir = (rfc.path as NSString).deletingLastPathComponent
            let resolved = rfcDir.isEmpty ? url.path : rfcDir + "/" + url.path
            let encoded = resolved.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? resolved
            guard let deepLink = URL(string: "hermit://rfc/\(encoded)") else { return }
            openURL(deepLink)
        } else {
            // Absolute URL — open in system browser
            openURL(url)
        }
    }

    private func openURL(_ url: URL) {
#if os(macOS)
        NSWorkspace.shared.open(url)
#else
        UIApplication.shared.open(url)
#endif
    }
}
