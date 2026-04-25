import SwiftUI
import WebKit

// MARK: - MermaidView: inline WKWebView island for a single mermaid diagram
// Sizes itself to the rendered diagram height — no internal scrollbars.

#if os(macOS)
struct MermaidView: NSViewRepresentable {
    let source: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = makeWebView(coordinator: context.coordinator)
        wv.loadHTMLString(mermaidHTML(source: source), baseURL: nil)
        return wv
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        wv.loadHTMLString(mermaidHTML(source: source), baseURL: nil)
    }
}
#else
struct MermaidView: UIViewRepresentable {
    let source: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let wv = makeWebView(coordinator: context.coordinator)
        wv.loadHTMLString(mermaidHTML(source: source), baseURL: nil)
        return wv
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        wv.loadHTMLString(mermaidHTML(source: source), baseURL: nil)
    }
}
#endif

// MARK: - Shared

extension MermaidView {
    final class Coordinator: NSObject, WKNavigationDelegate {
        // After the page loads, read the rendered height and update the view
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            webView.evaluateJavaScript("document.body.scrollHeight") { result, _ in
                guard let height = result as? CGFloat, height > 0 else { return }
                DispatchQueue.main.async {
#if os(macOS)
                    var frame = webView.frame
                    frame.size.height = height
                    webView.frame = frame
                    // Notify the hosting view that intrinsic size changed
                    webView.invalidateIntrinsicContentSize()
#else
                    webView.frame.size.height = height
                    webView.invalidateIntrinsicContentSize()
#endif
                }
            }
        }
    }
}

private func makeWebView(coordinator: MermaidView.Coordinator) -> WKWebView {
    let config = WKWebViewConfiguration()
    let prefs = WKWebpagePreferences()
    prefs.allowsContentJavaScript = true
    config.defaultWebpagePreferences = prefs
    let wv = WKWebView(frame: .zero, configuration: config)
    wv.navigationDelegate = coordinator
#if os(macOS)
    wv.setValue(false, forKey: "drawsBackground")
    // Disable scroll indicators
    if let scrollView = wv.subviews.compactMap({ $0 as? NSScrollView }).first {
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
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
    <meta name="viewport" content="width=device-width,initial-scale=1">
    <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { background: transparent; display: flex; justify-content: center; padding: 8px; }
    .mermaid { max-width: 100%; }
    .mermaid svg { max-width: 100%; height: auto; }
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
