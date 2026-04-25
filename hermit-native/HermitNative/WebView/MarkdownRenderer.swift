import Foundation

// MARK: - MarkdownRenderer: marked.js + mermaid.js via CDN

/// Converts raw RFC markdown to a self-contained HTML string ready for WKWebView.
/// - Uses marked.js (CDN) for full CommonMark rendering
/// - Uses mermaid.js (CDN) for diagram fences
/// - Strips YAML frontmatter via JS
/// - Wraps content in .doc-card.rfc-page layout matching the web GUI
enum MarkdownRenderer {

    static func htmlString(from markdown: String, css: String, mermaidScript: String) -> String {
        // JSON-encode the markdown so it's safe to embed in a JS string literal.
        // JSONSerialization encodes as a quoted string including escaping of backslashes,
        // backticks, dollar signs, etc.
        let markdownJSON: String
        if let data = try? JSONSerialization.data(withJSONObject: markdown, options: []),
           let s = String(data: data, encoding: .utf8) {
            markdownJSON = s
        } else {
            // Fallback: escape manually
            let escaped = markdown
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "`", with: "\\`")
                .replacingOccurrences(of: "$", with: "\\$")
            markdownJSON = "\"\(escaped)\""
        }

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
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
            mermaid.initialize({ startOnLoad: false, theme: 'default' });
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
