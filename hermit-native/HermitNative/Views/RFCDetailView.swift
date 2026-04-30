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

    @EnvironmentObject private var appState: AppState

    // Observed so toolbar re-evaluates when comments load/change.
    @ObservedObject private var liveStore: CommentStore

    init(rfc: RFC, repo: Repository? = nil, commentStore: CommentStore? = nil, onLineTapped: ((Int, Int) -> Void)? = nil) {
        self.rfc = rfc
        self.repo = repo
        self.commentStore = commentStore
        self.onLineTapped = onLineTapped
        self.liveStore = commentStore ?? CommentStore()
    }

    @State private var markdown: String = ""
    @State private var isLoading = true
    @State private var errorMessage: String? = nil
    @State private var actionError: String? = nil  // merge/accept errors surfaced as alert
    @State private var isReadingMode = false  // hermit-8q5
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

    init(rfc: RFC, repo: Repository? = nil,
         commentStore: CommentStore? = nil,
         onLineTapped: ((Int, Int) -> Void)? = nil) {
        self.rfc          = rfc
        self.repo         = repo
        self.commentStore = commentStore
        self.onLineTapped = onLineTapped
        self._currentRFC  = State(initialValue: rfc)
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
            // hermit-8q5 / hermit-d42: reading-mode toggle — labelled so macOS
            // toolbar can render it as text+icon in customised toolbar layouts.
            RFCLifecycleToolbar(
                rfc: rfc,
                fileURL: resolvedFileURL,
                prAlreadyAccepted: prAlreadyAccepted,
                onAcceptRFC: {
                    guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient(),
                          case .pullRequest(let pr) = rfc.source else {
                        return AcceptRFCResult(merged: false, blockedByCI: false, commitSHA: "")
                    }
                    let result: AcceptRFCResult
                    do {
                        result = try await client.acceptRFC(prNumber: pr.number, filePath: resolvedFilePath)
                    } catch {
                        actionError = error.localizedDescription
                        return AcceptRFCResult(merged: false, blockedByCI: false, commitSHA: "")
                    }
                    if result.merged {
                        reloadToken = UUID()
                    }
                    return result
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
                allThreadsResolved: liveStore.visibleComments.isEmpty,
                isBehind: isBehind,
                onUpdateBranch: {
                    guard let client = repo.flatMap({ appState.makeAPIClient(for: $0) }) ?? appState.makeAPIClient(),
                          case .pullRequest(let pr) = rfc.source else { return }
                    try? await client.updateBranch(prNumber: pr.number)
                    if let status = try? await client.getMergeStatus(prNumber: pr.number) {
                        isBehind = status
                    }
                },
                markdownSource: $markdown
            )
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

            // hermit-ec7: export/print/share + lifecycle toolbar
            RFCLifecycleToolbar(
                rfc: currentRFC,
                callerPermission: callerPermission,
                onApprove: handleApprove,
                onMarkImplemented: handleMarkImplemented,
                markdownSource: markdown
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
                    scrollToLine: $scrollToLine
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
                markdown = try await client.fetchPRRFCContent(prNumber: pr.number)
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
            if let changed = try? await client.listPRChangedFiles(prNumber: pr.number, docsPath: ""),
               let first = changed.first, !first.isEmpty {
                resolvedPath = first
            } else {
                resolvedPath = rfc.path
            }
            resolvedFilePath = resolvedPath
            // pr.htmlURL is e.g. "https://github.com/owner/repo/pull/123"
            // → strip "/pull/N" → append "/blob/{headRef}/{filePath}"
            if URL(string: pr.htmlURL) != nil,
               let prRange = pr.htmlURL.range(of: "/pull/", options: .backwards) {
                let repoBase = String(pr.htmlURL[..<prRange.lowerBound])
                resolvedFileURL = "\(repoBase)/blob/\(pr.headRef)/\(resolvedPath)"
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
        guard case .mainBranch = rfc.source else {
            // PR RFCs don't expose lifecycle transitions; no need to check.
            callerPermission = "none"
            return
        }
        do {
            callerPermission = try await client.getCallerPermission()
        } catch {
            // Non-fatal — toolbar buttons will be disabled (safest default).
            callerPermission = "none"
        }
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
                             lifecycleStatus: result.newStatus)
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
                             lifecycleStatus: result.newStatus)
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
