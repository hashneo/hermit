import Foundation

// MARK: - hermit-m8j: Markdown → HTML conversion

/// Converts raw RFC markdown to a self-contained HTML string ready for WKWebView.
/// - Injects hermit-reader.css (inline)
/// - Adds heading anchor IDs
/// - Rewrites ```mermaid fences to <div class="mermaid"> for Mermaid.js
/// - Adds data-line attributes for gutter markers
enum MarkdownRenderer {

    static func htmlString(from markdown: String, css: String, mermaidScript: String) -> String {
        let body = convertToHTML(markdown)
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>\(css)</style>
        </head>
        <body>
        \(body)
        <script>\(mermaidScript)</script>
        <script>
        if (typeof mermaid !== 'undefined') {
          mermaid.initialize({ startOnLoad: true, theme: 'default' });
        }
        // Notify Swift of text selections
        document.addEventListener('selectionchange', function() {
          var sel = window.getSelection();
          if (sel && sel.toString().length > 0) {
            window.webkit.messageHandlers.textSelected.postMessage({
              text: sel.toString(),
              range: sel.getRangeAt(0).startOffset
            });
          }
        });
        </script>
        </body>
        </html>
        """
    }

    // MARK: - Private conversion

    /// Minimal line-by-line markdown → HTML.
    /// Handles: headings, mermaid fences, code fences, paragraphs, blank lines.
    /// Full fidelity rendering is deferred to a future goldmark-based server pass.
    private static func convertToHTML(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var html: [String] = []
        var inFence = false
        var fenceTag = ""
        var lineNumber = 0
        var inParagraph = false

        func closeParagraph() {
            if inParagraph { html.append("</p>"); inParagraph = false }
        }

        for line in lines {
            lineNumber += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Mermaid / code fence toggle
            if trimmed.hasPrefix("```") {
                if inFence {
                    html.append(fenceTag == "mermaid" ? "</div>" : "</code></pre>")
                    inFence = false
                    fenceTag = ""
                } else {
                    closeParagraph()
                    fenceTag = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    inFence = true
                    if fenceTag == "mermaid" {
                        html.append("<div class=\"mermaid\" data-line=\"\(lineNumber)\">")
                    } else {
                        let lang = fenceTag.isEmpty ? "" : " class=\"language-\(fenceTag)\""
                        html.append("<pre data-line=\"\(lineNumber)\"><code\(lang)>")
                    }
                }
                continue
            }

            if inFence {
                html.append(escapeHTML(line))
                continue
            }

            // Headings
            if trimmed.hasPrefix("#") {
                closeParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                let capped = min(level, 6)
                let text = trimmed.dropFirst(level).trimmingCharacters(in: .whitespaces)
                let slug = text.lowercased()
                    .components(separatedBy: .alphanumerics.inverted).joined(separator: "-")
                    .replacingOccurrences(of: "--", with: "-")
                html.append("<h\(capped) id=\"\(slug)\" data-line=\"\(lineNumber)\">\(escapeHTML(text))</h\(capped)>")
                continue
            }

            // Blank lines close paragraphs
            if trimmed.isEmpty {
                closeParagraph()
                continue
            }

            // Paragraph
            if !inParagraph {
                html.append("<p data-line=\"\(lineNumber)\">")
                inParagraph = true
            }
            html.append(inlineMarkdown(trimmed))
        }

        closeParagraph()
        return html.joined(separator: "\n")
    }

    private static func inlineMarkdown(_ text: String) -> String {
        var s = escapeHTML(text)
        // Bold
        s = s.replacingOccurrences(of: #"\*\*(.*?)\*\*"#, with: "<strong>$1</strong>",
                                    options: .regularExpression)
        // Italic
        s = s.replacingOccurrences(of: #"\*(.*?)\*"#, with: "<em>$1</em>",
                                    options: .regularExpression)
        // Inline code
        s = s.replacingOccurrences(of: #"`(.*?)`"#, with: "<code>$1</code>",
                                    options: .regularExpression)
        // Links
        s = s.replacingOccurrences(of: #"\[(.*?)\]\((.*?)\)"#,
                                    with: "<a href=\"$2\">$1</a>",
                                    options: .regularExpression)
        return s
    }

    private static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }
}
