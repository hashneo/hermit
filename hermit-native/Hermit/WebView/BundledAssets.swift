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

    /// Inline CSS matching the web GUI's .doc-card.rfc-page + .doc-body styles.
    /// Ported from ui/src/styles.css.
    private static let embeddedCSS = """
    *, *::before, *::after { box-sizing: border-box; }

    body {
      margin: 0;
      font-family: -apple-system, 'Helvetica Neue', Arial, sans-serif;
      font-size: 16px;
      color: #1a1a2e;
      background: #eef1f6;
    }

    /* Page background wrapper */
    .rfc-stage-bg {
      background: #eef1f6;
      padding: 28px 40px 64px;
      min-height: 100vh;
    }

    /* Card — matches .doc-card.rfc-page */
    .doc-card.rfc-page {
      background: #ffffff;
      border: 1px solid #d9dee7;
      border-radius: 2px;
      max-width: 980px;
      margin: 0 auto;
      padding: 44px 56px;
      box-shadow:
        0 1px 1px rgba(31, 41, 55, 0.08),
        0 8px 26px rgba(15, 23, 42, 0.07);
    }

    /* Doc body — matches .doc-body */
    .doc-body {
      font-size: 1.03rem;
    }

    .doc-body h1,
    .doc-body h2,
    .doc-body h3 {
      color: #252934;
      margin-top: 22px;
    }

    .doc-body h1 { font-size: 1.9em; font-weight: 700; margin-bottom: 0.4em; border-bottom: 1px solid #d9dee7; padding-bottom: 0.3em; }
    .doc-body h2 { font-size: 1.4em; font-weight: 600; margin-bottom: 0.4em; }
    .doc-body h3 { font-size: 1.15em; font-weight: 600; margin-bottom: 0.3em; }
    .doc-body h4, .doc-body h5, .doc-body h6 { font-size: 1em; font-weight: 600; margin: 1em 0 0.3em; color: #252934; }

    .doc-body p, .doc-body li {
      line-height: 1.62;
      color: #2c313b;
    }

    .doc-body p { margin: 0.8em 0; }
    .doc-body ul, .doc-body ol { padding-left: 1.6em; margin: 0.8em 0; }
    .doc-body li { margin: 0.3em 0; }

    /* Code blocks */
    .doc-body pre {
      background: #eafaea;
      border: 1px solid #d0d7de;
      border-radius: 6px;
      padding: 12px 14px;
      overflow-x: auto;
      margin: 1em 0;
    }

    .doc-body pre code {
      background: transparent;
      border: 0;
      padding: 0;
      color: #24292f;
      font-size: 0.9rem;
      font-family: 'SF Mono', Menlo, 'Cascadia Code', monospace;
    }

    .doc-body :not(pre) > code {
      background: #eafaea;
      border: 1px solid #d0d7de;
      border-radius: 6px;
      padding: 0.1em 0.35em;
      color: #24292f;
      font-size: 0.875em;
      font-family: 'SF Mono', Menlo, 'Cascadia Code', monospace;
    }

    .doc-body blockquote {
      border-left: 4px solid #d0d7de;
      margin: 1em 0;
      padding: 0.5em 1em;
      color: #57606a;
      font-style: italic;
    }

    .doc-body hr {
      border: none;
      border-top: 1px solid #d9dee7;
      margin: 2em 0;
    }

    .doc-body a { color: #0969da; text-decoration: none; }
    .doc-body a:hover { text-decoration: underline; }

    .doc-body img {
      display: block;
      max-width: 100%;
      height: auto;
    }

    /* Mermaid diagrams */
    .mermaid { margin: 1.5em 0; text-align: center; }

    /* Tables */
    .doc-body table {
      border-collapse: collapse;
      width: 100%;
      margin: 1em 0;
      font-size: 0.95rem;
    }
    .doc-body th, .doc-body td {
      border: 1px solid #d0d7de;
      padding: 8px 12px;
      text-align: left;
    }
    .doc-body th {
      background: #f6f8fa;
      font-weight: 600;
      color: #252934;
    }

    /* Selection highlight */
    .doc-body ::selection {
      background: #f7dc6f;
      color: #212121;
    }
    """

    /// If mermaid.min.js is not bundled, diagrams render as plain text blocks.
    private static let embeddedMermaidStub = "/* mermaid.min.js not bundled */"
}
