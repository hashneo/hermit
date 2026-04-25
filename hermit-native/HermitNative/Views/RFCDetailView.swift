import SwiftUI
import WebKit

// MARK: - hermit-ii0: RFCDetailView — WKWebView reading view with thread gutter markers
// hermit-8q5: Reading Mode — full-screen RFC view with swipe-to-restore sidebar

struct RFCDetailView: View {
    let rfc: RFC
    var onTextSelected: ((String) -> Void)? = nil

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
                rfcWebView
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
        .task { await loadContent() }
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

    private var rfcWebView: some View {
        let html = MarkdownRenderer.htmlString(
            from: markdown,
            css: BundledAssets.readerCSS,
            mermaidScript: BundledAssets.mermaidScript
        )
        return WebViewRenderer(html: html, onTextSelected: onTextSelected)
    }

    private func loadContent() async {
        // In real usage, client is injected via environment; stub for compilability.
        // Full wiring in RFCStore/iPadRootView task graph.
        isLoading = false
        markdown = "# \(rfc.title)\n\n*Content loads via GitHubAPIClient.*"
    }
}
