import SwiftUI
import WebKit

// MARK: - MermaidView: inline WKWebView island for a single mermaid diagram
// Reads rendered scrollHeight via JS and drives height through SwiftUI state.

struct MermaidView: View {
    let source: String
    @State private var height: CGFloat = 200

    var body: some View {
        MermaidWebView(source: source, height: $height)
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

// MARK: - Platform representable

#if os(macOS)
private struct MermaidWebView: NSViewRepresentable {
    let source: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeNSView(context: Context) -> WKWebView {
        let wv = buildWebView(coordinator: context.coordinator)
        wv.loadHTMLString(mermaidHTML(source: source), baseURL: nil)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {}
}
#else
private struct MermaidWebView: UIViewRepresentable {
    let source: String
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = buildWebView(coordinator: context.coordinator)
        wv.loadHTMLString(mermaidHTML(source: source), baseURL: nil)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {}
}
#endif

// MARK: - Coordinator

private final class Coordinator: NSObject, WKNavigationDelegate {
    @Binding var height: CGFloat

    init(height: Binding<CGFloat>) { _height = height }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Poll until mermaid has finished rendering (SVG inserted into DOM)
        poll(webView: webView, attempts: 20)
    }

    private func poll(webView: WKWebView, attempts: Int) {
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] result, _ in
            guard let self else { return }
            if let h = result as? CGFloat, h > 40 {
                DispatchQueue.main.async { self.height = h }
            } else if attempts > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    self.poll(webView: webView, attempts: attempts - 1)
                }
            }
        }
    }
}

// MARK: - Shared WKWebView factory

private func buildWebView(coordinator: Coordinator) -> WKWebView {
    let config = WKWebViewConfiguration()
    let prefs = WKWebpagePreferences()
    prefs.allowsContentJavaScript = true
    config.defaultWebpagePreferences = prefs
    let wv = WKWebView(frame: .zero, configuration: config)
    wv.navigationDelegate = coordinator
#if os(macOS)
    wv.setValue(false, forKey: "drawsBackground")
    // Disable scroll indicators inside the WKWebView's NSScrollView
    DispatchQueue.main.async {
        if let sv = wv.subviews.compactMap({ $0 as? NSScrollView }).first {
            sv.hasVerticalScroller = false
            sv.hasHorizontalScroller = false
            sv.verticalScrollElasticity = .none
            sv.horizontalScrollElasticity = .none
        }
    }
#else
    wv.isOpaque = false
    wv.backgroundColor = .clear
    wv.scrollView.backgroundColor = .clear
    wv.scrollView.isScrollEnabled = false
    wv.scrollView.showsVerticalScrollIndicator = false
    wv.scrollView.showsHorizontalScrollIndicator = false
#endif
    return wv
}

// MARK: - HTML

private func mermaidHTML(source: String) -> String {
    let encoded: String
    if let data = try? JSONSerialization.data(withJSONObject: [source], options: []),
       let s = String(data: data, encoding: .utf8),
       s.hasPrefix("["), s.hasSuffix("]") {
        encoded = String(s.dropFirst().dropLast())
    } else {
        let esc = source
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        encoded = "\"\(esc)\""
    }

    return """
    <!DOCTYPE html>
    <html>
    <head>
    <meta charset="utf-8">
    <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: transparent; display: flex; justify-content: center; padding: 8px; }
    .mermaid svg { max-width: 100%; height: auto; display: block; }
    </style>
    <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
    </head>
    <body>
    <div class="mermaid" id="diagram"></div>
    <script>
    mermaid.initialize({ startOnLoad: false, theme: 'default' });
    document.getElementById('diagram').textContent = \(encoded);
    mermaid.run({ nodes: [document.getElementById('diagram')] });
    </script>
    </body>
    </html>
    """
}
