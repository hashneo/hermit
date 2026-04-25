import Foundation

// MARK: - AST types

indirect enum MarkdownInline: Equatable {
    case text(String)
    case bold([MarkdownInline])
    case italic([MarkdownInline])
    case code(String)
    case link(text: String, url: String)
    case image(alt: String, url: String)
}

enum MarkdownBlock {
    case heading(level: Int, inlines: [MarkdownInline])
    case paragraph(inlines: [MarkdownInline])
    case codeBlock(language: String, code: String)
    case mermaidBlock(source: String)
    case bulletList(items: [[MarkdownInline]])
    case orderedList(items: [[MarkdownInline]])
    case blockquote(inlines: [MarkdownInline])
    case horizontalRule
}

// MARK: - Parser

enum MarkdownParser {

    static func parse(_ input: String) -> [MarkdownBlock] {
        var lines = input.components(separatedBy: "\n")

        // Strip YAML frontmatter
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                lines = Array(lines[(end + 1)...])
            }
        }

        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                    codeLines.append(cl)
                    i += 1
                }
                let source = codeLines.joined(separator: "\n")
                if lang == "mermaid" {
                    blocks.append(.mermaidBlock(source: source))
                } else {
                    blocks.append(.codeBlock(language: lang, code: source))
                }
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule)
                i += 1; continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let level = min(trimmed.prefix(while: { $0 == "#" }).count, 6)
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, inlines: parseInline(text)))
                i += 1; continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                var bqLines: [String] = []
                while i < lines.count {
                    let bl = lines[i].trimmingCharacters(in: .whitespaces)
                    guard bl.hasPrefix(">") else { break }
                    bqLines.append(String(bl.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                let text = bqLines.joined(separator: " ")
                blocks.append(.blockquote(inlines: parseInline(text)))
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                var items: [[MarkdownInline]] = []
                while i < lines.count {
                    let bl = lines[i].trimmingCharacters(in: .whitespaces)
                    if bl.hasPrefix("- ") || bl.hasPrefix("* ") {
                        items.append(parseInline(String(bl.dropFirst(2))))
                        i += 1
                    } else if bl.isEmpty {
                        i += 1; break
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(items: items))
                continue
            }

            // Ordered list
            let olPattern = #"^\d+\.\s"#
            if trimmed.range(of: olPattern, options: .regularExpression) != nil {
                var items: [[MarkdownInline]] = []
                while i < lines.count {
                    let bl = lines[i].trimmingCharacters(in: .whitespaces)
                    if bl.range(of: olPattern, options: .regularExpression) != nil {
                        let text = bl.replacingOccurrences(of: olPattern, with: "", options: .regularExpression)
                        items.append(parseInline(text))
                        i += 1
                    } else if bl.isEmpty {
                        i += 1; break
                    } else {
                        break
                    }
                }
                blocks.append(.orderedList(items: items))
                continue
            }

            // Paragraph — accumulate until blank line or block-level element
            var paraLines: [String] = []
            while i < lines.count {
                let pl = lines[i]
                let pt = pl.trimmingCharacters(in: .whitespaces)
                if pt.isEmpty { i += 1; break }
                if pt.hasPrefix("#") || pt.hasPrefix(">") || pt.hasPrefix("```")
                    || pt.hasPrefix("- ") || pt.hasPrefix("* ")
                    || pt.range(of: olPattern, options: .regularExpression) != nil
                    || pt == "---" || pt == "***" || pt == "___" { break }
                paraLines.append(pt)
                i += 1
            }
            if !paraLines.isEmpty {
                let text = paraLines.joined(separator: " ")
                blocks.append(.paragraph(inlines: parseInline(text)))
            }
        }

        return blocks
    }

    // MARK: - Inline parser

    static func parseInline(_ input: String) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var s = input
        while !s.isEmpty {
            // Image ![alt](url)
            if let r = s.range(of: #"^!\[([^\]]*)\]\(([^)]*)\)"#, options: .regularExpression) {
                let match = String(s[r])
                let inner = match.dropFirst(2) // drop ![ 
                if let altEnd = inner.firstIndex(of: "]"),
                   let urlStart = inner[altEnd...].firstIndex(of: "("),
                   let urlEnd = inner[urlStart...].firstIndex(of: ")") {
                    let alt = String(inner[inner.startIndex..<altEnd])
                    let urlRange = inner.index(after: urlStart)..<urlEnd
                    let url = String(inner[urlRange])
                    result.append(.image(alt: alt, url: url))
                    s = String(s[r.upperBound...])
                    continue
                }
            }

            // Link [text](url)
            if let r = s.range(of: #"^\[([^\]]*)\]\(([^)]*)\)"#, options: .regularExpression) {
                let match = String(s[r])
                let inner = match.dropFirst() // drop [
                if let textEnd = inner.firstIndex(of: "]"),
                   let urlStart = inner[textEnd...].firstIndex(of: "("),
                   let urlEnd = inner[urlStart...].firstIndex(of: ")") {
                    let text = String(inner[inner.startIndex..<textEnd])
                    let urlRange = inner.index(after: urlStart)..<urlEnd
                    let url = String(inner[urlRange])
                    result.append(.link(text: text, url: url))
                    s = String(s[r.upperBound...])
                    continue
                }
            }

            // Bold **...**
            if s.hasPrefix("**"), let end = s.dropFirst(2).range(of: "**") {
                let inner = String(s[s.index(s.startIndex, offsetBy: 2)..<s.index(end.lowerBound, offsetBy: 2)])
                result.append(.bold(parseInline(inner)))
                s = String(s[s.index(end.upperBound, offsetBy: 2)...])
                continue
            }

            // Italic *...*
            if s.hasPrefix("*"), !s.hasPrefix("**") {
                let rest = s.dropFirst()
                if let end = rest.firstIndex(of: "*"), !rest[rest.startIndex..<end].isEmpty {
                    let inner = String(rest[rest.startIndex..<end])
                    result.append(.italic(parseInline(inner)))
                    s = String(rest[rest.index(after: end)...])
                    continue
                }
            }

            // Inline code `...`
            if s.hasPrefix("`"), let end = s.dropFirst().firstIndex(of: "`") {
                let inner = String(s.dropFirst()[s.dropFirst().startIndex..<end])
                result.append(.code(inner))
                s = String(s.dropFirst()[s.dropFirst().index(after: end)...])
                continue
            }

            // Plain text — consume until next special char
            var text = ""
            while !s.isEmpty {
                let c = s.first!
                if c == "*" || c == "`" || c == "[" || c == "!" { break }
                text.append(c)
                s = String(s.dropFirst())
            }
            if !text.isEmpty { result.append(.text(text)) }
        }
        return result
    }
}
