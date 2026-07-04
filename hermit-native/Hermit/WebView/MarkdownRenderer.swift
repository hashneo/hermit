import Foundation

// MARK: - MarkdownRenderer: legacy shim (superseded by MarkdownRendererView + MarkdownParser)
//
// hermit-sqo: RFCDetailView now uses MarkdownRendererView (native SwiftUI) directly.
// This file is retained for reference and potential reuse (e.g. export/share flows).

enum MarkdownRenderer {

    @available(*, deprecated, renamed: "MarkdownRendererView", message: "Use MarkdownRendererView + MarkdownParser for native rendering.")
    static func htmlString(from markdown: String, css: String, mermaidScript: String, prefersDarkMode: Bool = false) -> String {
        // JSON-encode the markdown by wrapping it in an array so NSJSONSerialization
        // accepts it (it requires an array or dict root object). We then strip the
        // surrounding [ ] to get a quoted JSON string literal safe for embedding in JS.
        let markdownJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: [markdown], options: []),
           let s = String(data: data, encoding: .utf8),
           s.hasPrefix("["), s.hasSuffix("]") {
            // Strip the enclosing array brackets to get the bare JSON string
            markdownJSON = String(s.dropFirst().dropLast())
        } else {
            // Fallback: manual escaping
            let escaped = markdown
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
            markdownJSON = "\"\(escaped)\""
        }

        let themeClass = prefersDarkMode ? "hermit-preview-dark" : "hermit-preview-light"
        let mermaidTheme = prefersDarkMode ? "dark" : "default"

        return """
        <!DOCTYPE html>
        <html class="\(themeClass)">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <style>\(css)</style>
        <style>
        :root { color-scheme: light dark; }
        html.hermit-preview-dark,
        html.hermit-preview-dark body,
        html.hermit-preview-dark .rfc-stage-bg {
          background: #12121e !important;
          color: #e8e8f4 !important;
        }
        html.hermit-preview-dark .doc-card.rfc-page {
          background: #181824 !important;
          border-color: #2a2a40 !important;
          box-shadow: none !important;
        }
        html.hermit-preview-dark .doc-body,
        html.hermit-preview-dark .doc-body p,
        html.hermit-preview-dark .doc-body li,
        html.hermit-preview-dark .doc-body td {
          color: #e8e8f4 !important;
        }
        html.hermit-preview-dark .doc-body h1,
        html.hermit-preview-dark .doc-body h2,
        html.hermit-preview-dark .doc-body h3,
        html.hermit-preview-dark .doc-body h4,
        html.hermit-preview-dark .doc-body h5,
        html.hermit-preview-dark .doc-body h6,
        html.hermit-preview-dark .doc-body th {
          color: #f4f4ff !important;
          border-color: #2a2a40 !important;
        }
        html.hermit-preview-dark .doc-body pre,
        html.hermit-preview-dark .doc-body :not(pre) > code,
        html.hermit-preview-dark .doc-body th,
        html.hermit-preview-dark .doc-body tr:nth-child(even) {
          background: #1e1e30 !important;
          border-color: #2a2a40 !important;
        }
        html.hermit-preview-dark .doc-body pre code,
        html.hermit-preview-dark .doc-body :not(pre) > code {
          color: #e8e8f4 !important;
        }
        html.hermit-preview-dark .doc-body blockquote {
          color: #a0a0c0 !important;
          border-color: #5b8cff !important;
          background: #1a1a2e !important;
        }
        html.hermit-preview-dark .doc-body a { color: #7da2ff !important; }
        html.hermit-preview-dark .doc-body hr,
        html.hermit-preview-dark .doc-body th,
        html.hermit-preview-dark .doc-body td {
          border-color: #2a2a40 !important;
        }
        html.hermit-preview-light,
        html.hermit-preview-light body {
          background: #eef1f6;
          color: #1a1a2e;
        }
        </style>
        <script src="https://cdn.jsdelivr.net/npm/marked@12/marked.min.js"></script>
        <script src="https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.min.js"></script>
        </head>
        <body>
        <div class="rfc-stage-bg">
          <div class="doc-card rfc-page">
            <div class="doc-body" id="content"></div>
          </div>
        </div>
        <script>
        (function() {
          var raw = \(markdownJSON);

          // Strip YAML frontmatter (--- ... ---)
          raw = raw.replace(/^---[\\s\\S]*?\\n---\\n?/, '');

          // Configure marked with a custom renderer that converts mermaid fences
          // to <div class="mermaid"> elements
          var renderer = new marked.Renderer();
          var origCode = renderer.code.bind(renderer);
          renderer.code = function(token) {
            // marked v12+ passes a token object; extract lang and text
            var lang = (token && token.lang) ? token.lang : (typeof token === 'string' ? '' : '');
            var text = (token && token.text != null) ? token.text : (typeof token === 'string' ? token : '');
            // Fallback for older marked API (string, lang, escaped)
            if (typeof arguments[0] === 'string') {
              text = arguments[0];
              lang = arguments[1] || '';
            }
            if (lang === 'mermaid') {
              return '<div class="mermaid">' + text + '</div>';
            }
            return origCode(token);
          };

          marked.setOptions({ renderer: renderer });

          document.getElementById('content').innerHTML = marked.parse(raw);

          // Initialize mermaid after content is injected
          if (typeof mermaid !== 'undefined') {
            mermaid.initialize({ startOnLoad: false, theme: '\(mermaidTheme)' });
            mermaid.run({ nodes: document.querySelectorAll('.mermaid') });
          }

          // Notify Swift of text selections
          document.addEventListener('selectionchange', function() {
            var sel = window.getSelection();
            if (sel && sel.toString().length > 0) {
              try {
                window.webkit.messageHandlers.textSelected.postMessage({
                  text: sel.toString(),
                  range: sel.getRangeAt(0).startOffset
                });
              } catch(e) {}
            }
          });
        })();
        </script>
        </body>
        </html>
        """
    }
}
