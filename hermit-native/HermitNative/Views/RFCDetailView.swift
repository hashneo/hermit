import SwiftUI

// MARK: - hermit-ii0: RFCDetailView — native markdown viewer with gutter comment markers
// hermit-8q5: Reading Mode — full-screen RFC view with swipe-to-restore sidebar

struct RFCDetailView: View {
    let rfc: RFC
    var commentStore: CommentStore? = nil
    var onLineTapped: ((Int) -> Void)? = nil

    @EnvironmentObject private var appState: AppState

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

    private var rfcContentView: some View {
        // Always inject a CommentStore — use the provided one or a default no-op instance
        let store = commentStore ?? CommentStore()
        let gutterView = GutterMarkdownView(
            blocks: MarkdownParser.parse(markdown),
            onLineTapped: onLineTapped
        )
        return ScrollView(.vertical, showsIndicators: true) {
            gutterView
                .environmentObject(store)
                .padding(.horizontal, 32)
                .padding(.vertical, 40)
                .frame(maxWidth: 940, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
    }

    private func loadContent() async {
        isLoading = true
        errorMessage = nil

        guard let client = appState.makeAPIClient() else {
            errorMessage = "Not configured."
            isLoading = false
            return
        }
        guard !rfc.path.isEmpty else {
            errorMessage = "No RFC file found on this branch."
            isLoading = false
            return
        }

        let ref: String
        switch rfc.source {
        case .mainBranch:
            ref = "main"
        case .pullRequest(let pr):
            ref = pr.headRef
        }

        do {
            markdown = try await client.fetchRFCContent(path: rfc.path, ref: ref)
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
            return
        }

        // Configure and load comments if this is a PR RFC
        if case .pullRequest(let pr) = rfc.source, let store = commentStore {
            store.configure(
                client: client,
                prNumber: pr.number,
                commitSHA: pr.headSHA,
                filePath: rfc.path
            )
            await store.load()
        } else {
            commentStore?.reset()
        }

        isLoading = false
    }
}
