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
    case heading(level: Int, inlines: [MarkdownInline], sourceLine: Int, sourceLineEnd: Int)
    case paragraph(inlines: [MarkdownInline], sourceLine: Int, sourceLineEnd: Int)
    case codeBlock(language: String, code: String, sourceLine: Int, sourceLineEnd: Int)
    case mermaidBlock(source: String, sourceLine: Int, sourceLineEnd: Int)
    case bulletList(items: [ListItem], sourceLine: Int, sourceLineEnd: Int)
    case orderedList(items: [ListItem], sourceLine: Int, sourceLineEnd: Int)
    case blockquote(inlines: [MarkdownInline], sourceLine: Int, sourceLineEnd: Int)
    case horizontalRule(sourceLine: Int)
    case table(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]], sourceLine: Int, sourceLineEnd: Int)

    /// A single list item with its nesting depth (0 = top level, 1 = one indent, etc.)
    struct ListItem {
        let depth: Int
        let inlines: [MarkdownInline]
    }

    var sourceLine: Int {
        switch self {
        case .heading(_, _, let l, _), .paragraph(_, let l, _), .codeBlock(_, _, let l, _),
             .mermaidBlock(_, let l, _), .bulletList(_, let l, _), .orderedList(_, let l, _),
             .blockquote(_, let l, _), .horizontalRule(let l), .table(_, _, let l, _):
            return l
        }
    }

    /// The last raw file line number covered by this block (inclusive).
    /// For single-line blocks this equals `sourceLine`.
    var sourceLineEnd: Int {
        switch self {
        case .heading(_, _, _, let e), .paragraph(_, _, let e), .codeBlock(_, _, _, let e),
             .mermaidBlock(_, _, let e), .bulletList(_, _, let e), .orderedList(_, _, let e),
             .blockquote(_, _, let e), .table(_, _, _, let e):
            return e
        case .horizontalRule(let l):
            return l
        }
    }
}

// MARK: - Parser

enum MarkdownParser {

    static func parse(_ input: String) -> [MarkdownBlock] {
        var lines = input.components(separatedBy: "\n")

        // Strip YAML frontmatter — track how many lines we skip so sourceLine is correct
        var frontmatterOffset = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            if let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
                frontmatterOffset = end + 1  // lines consumed (includes both --- delimiters)
                lines = Array(lines[(end + 1)...])
            }
        }

        // sourceLine converts the local index i (into the post-frontmatter array) to a
        // 1-based raw file line number.
        func rawLine(_ localIndex: Int) -> Int { localIndex + frontmatterOffset + 1 }

        var blocks: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Blank line
            if trimmed.isEmpty { i += 1; continue }

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let blockStart = i
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                i += 1
                var codeLines: [String] = []
                while i < lines.count {
                    let cl = lines[i]
                    if cl.trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
                    codeLines.append(cl)
                    i += 1
                }
                // i now points one past the closing fence; the fence itself was at i-1.
                let blockEnd = i - 1
                let source = codeLines.joined(separator: "\n")
                if lang == "mermaid" {
                    blocks.append(.mermaidBlock(source: source, sourceLine: rawLine(blockStart), sourceLineEnd: rawLine(blockEnd)))
                } else {
                    blocks.append(.codeBlock(language: lang, code: source, sourceLine: rawLine(blockStart), sourceLineEnd: rawLine(blockEnd)))
                }
                continue
            }

            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule(sourceLine: rawLine(i)))
                i += 1; continue
            }

            // Heading
            if trimmed.hasPrefix("#") {
                let level = min(trimmed.prefix(while: { $0 == "#" }).count, 6)
                let text = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: level, inlines: parseInline(text), sourceLine: rawLine(i), sourceLineEnd: rawLine(i)))
                i += 1; continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                let blockStart = i
                var bqLines: [String] = []
                while i < lines.count {
                    let bl = lines[i].trimmingCharacters(in: .whitespaces)
                    guard bl.hasPrefix(">") else { break }
                    bqLines.append(String(bl.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                let text = bqLines.joined(separator: " ")
                blocks.append(.blockquote(inlines: parseInline(text), sourceLine: rawLine(blockStart), sourceLineEnd: rawLine(i - 1)))
                continue
            }

            // Bullet list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                let blockStart = i
                var items: [MarkdownBlock.ListItem] = []
                while i < lines.count {
                    let raw = lines[i]
                    let bl = raw.trimmingCharacters(in: .whitespaces)
                    if bl.hasPrefix("- ") || bl.hasPrefix("* ") {
                        let indent = raw.prefix(while: { $0 == " " }).count
                        let depth = indent / 2
                        items.append(MarkdownBlock.ListItem(depth: depth, inlines: parseInline(String(bl.dropFirst(2)))))
                        i += 1
                    } else if bl.isEmpty {
                        i += 1; break
                    } else {
                        break
                    }
                }
                blocks.append(.bulletList(items: items, sourceLine: rawLine(blockStart), sourceLineEnd: rawLine(i - 1)))
                continue
            }

            // Ordered list
            let olPattern = #"^\d+\.\s"#
            if trimmed.range(of: olPattern, options: .regularExpression) != nil {
                let blockStart = i
                var items: [MarkdownBlock.ListItem] = []
                while i < lines.count {
                    let raw = lines[i]
                    let bl = raw.trimmingCharacters(in: .whitespaces)
                    if bl.range(of: olPattern, options: .regularExpression) != nil {
                        let indent = raw.prefix(while: { $0 == " " }).count
                        let depth = indent / 2
                        let text = bl.replacingOccurrences(of: olPattern, with: "", options: .regularExpression)
                        items.append(MarkdownBlock.ListItem(depth: depth, inlines: parseInline(text)))
                        i += 1
                    } else if bl.isEmpty {
                        i += 1; break
                    } else {
                        break
                    }
                }
                blocks.append(.orderedList(items: items, sourceLine: rawLine(blockStart), sourceLineEnd: rawLine(i - 1)))
                continue
            }

            // GFM Table — header row | sep row (|---|) | data rows
            // Detect: current line contains |, next line is a separator
            if trimmed.contains("|") && i + 1 < lines.count {
                let sepLine = lines[i + 1].trimmingCharacters(in: .whitespaces)
                let isSep = sepLine.contains("|") &&
                    sepLine.replacingOccurrences(of: "|", with: "")
                            .replacingOccurrences(of: "-", with: "")
                            .replacingOccurrences(of: ":", with: "")
                            .replacingOccurrences(of: " ", with: "")
                            .isEmpty
                if isSep {
                    let blockStart = i
                    let headers = parseTableRow(trimmed)
                    i += 2  // skip header + separator
                    var rows: [[[MarkdownInline]]] = []
                    while i < lines.count {
                        let rl = lines[i].trimmingCharacters(in: .whitespaces)
                        if rl.isEmpty || !rl.contains("|") { break }
                        rows.append(parseTableRow(rl))
                        i += 1
                    }
                    blocks.append(.table(headers: headers, rows: rows, sourceLine: rawLine(blockStart), sourceLineEnd: rawLine(i - 1)))
                    continue
                }
            }

            // Paragraph — accumulate until blank line or block-level element
            let paraStart = i
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
                blocks.append(.paragraph(inlines: parseInline(text), sourceLine: rawLine(paraStart), sourceLineEnd: rawLine(i - 1)))
            }
        }

        return blocks
    }

    // MARK: - Inline parser

    private static func parseTableRow(_ line: String) -> [[MarkdownInline]] {
        // Strip leading/trailing |, split on |, trim each cell
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s = String(s.dropFirst()) }
        if s.hasSuffix("|") { s = String(s.dropLast()) }
        return s.components(separatedBy: "|").map { parseInline($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func parseInline(_ input: String) -> [MarkdownInline] {
        var result: [MarkdownInline] = []
        var chars = Array(input) // work on character array to avoid index hell
        var i = 0

        // Append a plain text character, merging with previous text run if possible
        func emitChar(_ c: Character) {
            if case .text(let s) = result.last {
                result[result.count - 1] = .text(s + String(c))
            } else {
                result.append(.text(String(c)))
            }
        }

        while i < chars.count {
            let c = chars[i]

            // Image ![alt](url)
            if c == "!" && i + 1 < chars.count && chars[i + 1] == "[" {
                if let (alt, url, advance) = parseLinkOrImage(chars: chars, from: i + 1, isImage: true) {
                    result.append(.image(alt: alt, url: url))
                    i += advance + 1
                    continue
                }
            }

            // Link [text](url)
            if c == "[" {
                if let (text, url, advance) = parseLinkOrImage(chars: chars, from: i, isImage: false) {
                    result.append(.link(text: text, url: url))
                    i += advance
                    continue
                }
            }

            // Bold **...**
            if c == "*" && i + 1 < chars.count && chars[i + 1] == "*" {
                let start = i + 2
                if let end = findClosing(chars: chars, from: start, marker: ["*", "*"]) {
                    let inner = String(chars[start..<end])
                    result.append(.bold(parseInline(inner)))
                    i = end + 2
                    continue
                }
            }

            // Italic *...*  (but not **)
            if c == "*" && !(i + 1 < chars.count && chars[i + 1] == "*") {
                let start = i + 1
                if let end = findClosing(chars: chars, from: start, marker: ["*"]), end > start {
                    let inner = String(chars[start..<end])
                    result.append(.italic(parseInline(inner)))
                    i = end + 1
                    continue
                }
            }

            // Inline code `...`
            if c == "`" {
                let start = i + 1
                if let end = findClosing(chars: chars, from: start, marker: ["`"]) {
                    let inner = String(chars[start..<end])
                    result.append(.code(inner))
                    i = end + 1
                    continue
                }
            }

            // No match — emit as plain text and advance
            emitChar(c)
            i += 1
        }

        return result
    }

    // Finds the next occurrence of `marker` in `chars` starting at `from`.
    // Returns the index where the marker starts (i.e. content ends before it).
    private static func findClosing(chars: [Character], from: Int, marker: [Character]) -> Int? {
        guard from < chars.count else { return nil }
        var j = from
        while j <= chars.count - marker.count {
            if Array(chars[j..<(j + marker.count)]) == marker {
                return j
            }
            j += 1
        }
        return nil
    }

    // Parses [text](url) or (for isImage: true) the [alt](url) part after the !.
    // `from` is the index of the opening `[`.
    // Returns (text/alt, url, characters consumed including the opening char).
    private static func parseLinkOrImage(chars: [Character], from: Int, isImage: Bool) -> (String, String, Int)? {
        guard from < chars.count, chars[from] == "[" else { return nil }
        // Find closing ]
        guard let bracketClose = findClosing(chars: chars, from: from + 1, marker: ["]"]) else { return nil }
        // Expect ( immediately after ]
        let parenOpen = bracketClose + 1
        guard parenOpen < chars.count, chars[parenOpen] == "(" else { return nil }
        guard let parenClose = findClosing(chars: chars, from: parenOpen + 1, marker: [")"]) else { return nil }

        let text = String(chars[(from + 1)..<bracketClose])
        let url  = String(chars[(parenOpen + 1)..<parenClose])
        let consumed = parenClose - from + 1  // number of chars from `from` through `)`
        return (text, url, consumed)
    }
}
