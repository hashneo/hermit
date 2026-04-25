import SwiftUI

// MARK: - hermit-ii0: RFCDetailView — WKWebView reading view with thread gutter markers
// hermit-8q5: Reading Mode — full-screen RFC view with swipe-to-restore sidebar

struct RFCDetailView: View {
    let rfc: RFC
    var onTextSelected: ((String) -> Void)? = nil

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
        ScrollView(.vertical, showsIndicators: true) {
            MarkdownRendererView(blocks: MarkdownParser.parse(markdown))
                .padding(40)
                .frame(maxWidth: 900, alignment: .leading)
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
        do {
            let ref: String
            switch rfc.source {
            case .mainBranch:
                ref = "main"
            case .pullRequest(let pr):
                ref = pr.headRef
            }
            markdown = try await client.fetchRFCContent(path: rfc.path, ref: ref)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
