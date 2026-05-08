import SwiftUI

// MARK: - hermit-ii0: RFCDetailView — native markdown viewer with gutter comment markers
// hermit-8q5: Reading Mode — full-screen RFC view with swipe-to-restore sidebar

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
    @State private var isReadingMode = false  // hermit-8q5

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
        .navigationTitle(rfc.title)
        .toolbar {
            RFCLifecycleToolbar(rfc: rfc, markdownSource: markdown)
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 4) {
                    Button { scrollToPrev() } label: {
                        Image(systemName: "chevron.up")
                    }
                    .disabled(liveStore.commentedLines.isEmpty)
                    .help("Previous comment")
                    Button { scrollToNext() } label: {
                        Image(systemName: "chevron.down")
                    }
                    .disabled(liveStore.commentedLines.isEmpty)
                    .help("Next comment")
                }
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation { isReadingMode.toggle() }
                } label: {
                    Image(systemName: isReadingMode ? "sidebar.left" : "arrow.up.left.and.arrow.down.right")
                }
                .help(isReadingMode ? "Restore sidebar" : "Reading mode")
            }
        }
        .task(id: rfc.id) { await loadContent() }
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

    @State private var viewportHeight: CGFloat = 800
    @State private var scrollToLine: Int? = nil

    private func scrollToPrev() {
        let lines = liveStore.commentedLines
        guard !lines.isEmpty else { return }
        if let current = scrollToLine, let idx = lines.firstIndex(of: current), idx > 0 {
            scrollToLine = lines[idx - 1]
        } else {
            scrollToLine = lines.last
        }
    }

    private func scrollToNext() {
        let lines = liveStore.commentedLines
        guard !lines.isEmpty else { return }
        if let current = scrollToLine, let idx = lines.firstIndex(of: current), idx < lines.count - 1 {
            scrollToLine = lines[idx + 1]
        } else {
            scrollToLine = lines.first
        }
    }

    private var rfcContentView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                GutterMarkdownView(
                    blocks: MarkdownParser.parse(markdown),
                    onLineTapped: onLineTapped,
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

        // Configure and load comments if this is a PR RFC
        if case .pullRequest(let pr) = rfc.source, let store = commentStore {
            // rfc.path holds the branch name (headRef) for PR RFCs, not the file path.
            // Resolve the actual changed file path from the server before configuring.
            let resolvedPath: String
            if let changed = try? await client.listPRChangedFiles(prNumber: pr.number, docsPath: ""),
               let first = changed.first, !first.isEmpty {
                resolvedPath = first
            } else {
                resolvedPath = rfc.path   // fallback (won't work for inline comments, but safe)
            }
            store.configure(
                client: client,
                prNumber: pr.number,
                filePath: resolvedPath
            )
            await store.load()
        } else {
            commentStore?.reset()
        }

        isLoading = false
    }
}
