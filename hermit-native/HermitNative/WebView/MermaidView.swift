import SwiftUI
import WebKit

// MARK: - MermaidView: inline WKWebView island for a single mermaid diagram

#if os(macOS)
struct MermaidView: NSViewRepresentable {
    let source: String

    func makeNSView(context: Context) -> WKWebView {
        makeWebView()
    }

    func updateNSView(_ wv: WKWebView, context: Context) {
        wv.loadHTMLString(html, baseURL: nil)
    }
}
#else
struct MermaidView: UIViewRepresentable {
    let source: String

    func makeUIView(context: Context) -> WKWebView {
        makeWebView()
    }

    func updateUIView(_ wv: WKWebView, context: Context) {
        wv.loadHTMLString(html, baseURL: nil)
    }
}
#endif

private extension MermaidView {
    func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let wv = WKWebView(frame: .zero, configuration: config)
#if os(macOS)
        wv.setValue(false, forKey: "drawsBackground")
#else
        wv.isOpaque = false
        wv.backgroundColor = .clear
        wv.scrollView.backgroundColor = .clear
        wv.scrollView.isScrollEnabled = false
#endif
        wv.loadHTMLString(html, baseURL: nil)
        return wv
    }

    var html: String {
        // JSON-encode source safely
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
        body { margin: 0; padding: 8px; background: transparent; display: flex; justify-content: center; }
        .mermaid { max-width: 100%; }
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
}
