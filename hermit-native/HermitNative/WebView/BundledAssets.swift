import Foundation

// MARK: - hermit-1rd: Bundled asset loader for WKWebView

/// Loads bundled resources (hermit-reader.css, mermaid.min.js) from the app bundle.
/// Falls back to embedded stubs so the app is functional even without the binary assets
/// (e.g. during development before the resource bundle step is wired in Xcode).
enum BundledAssets {

    // MARK: CSS

    static var readerCSS: String {
        loadText(named: "hermit-reader", ext: "css") ?? embeddedCSS
    }

    // MARK: Mermaid

    static var mermaidScript: String {
        loadText(named: "mermaid.min", ext: "js") ?? embeddedMermaidStub
    }

    // MARK: Private

    private static func loadText(named name: String, ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return text
    }

    /// Minimal inline CSS stub so WKWebView is readable during development.
    private static let embeddedCSS = """
    body { font-family: -apple-system, sans-serif; font-size: 16px; line-height: 1.6;
           max-width: 780px; margin: auto; padding: 1.5rem 1rem; }
    pre  { background: #f5f5f5; padding: 1rem; border-radius: 6px; overflow-x: auto; }
    code { font-family: 'SF Mono', Menlo, monospace; font-size: .875em; }
    h1, h2, h3 { font-weight: 700; }
    """

    /// If mermaid.min.js is not bundled, diagrams render as plain text blocks.
    private static let embeddedMermaidStub = "/* mermaid.min.js not bundled */"
}
