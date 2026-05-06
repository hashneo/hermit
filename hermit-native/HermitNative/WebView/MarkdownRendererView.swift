import SwiftUI

// MARK: - MarkdownRendererView: native SwiftUI renderer for [MarkdownBlock]

struct MarkdownRendererView: View {
    let blocks: [MarkdownBlock]
    /// Called when the user taps a block; receives the 1-based raw markdown source line number.
    var onLineTapped: ((Int) -> Void)? = nil

    private var codeBackground: Color {
        Color(red: 0.92, green: 0.98, blue: 0.92)  // light green
    }

    private var codeBackgroundSwiftUIColor: Color {
        codeBackground
    }

    var body: some View {        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .contentShape(Rectangle())
                    .onTapGesture { onLineTapped?(block.sourceLine) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let inlines, _, _):
            headingView(level: level, inlines: inlines)

        case .paragraph(let inlines, _, _):
            Text(attributedString(inlines))
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(let lang, let code, _, _):
            codeBlockView(language: lang, code: code)

        case .mermaidBlock(let source, _, _):
            MermaidView(source: source)
                .frame(minHeight: 200)
                .frame(maxWidth: .infinity)

        case .bulletList(let items, _, _):
            bulletListView(items: items)

        case .orderedList(let items, _, _):
            orderedListView(items: items)

        case .blockquote(let inlines, _, _):
            blockquoteView(inlines: inlines)

        case .horizontalRule(_):
            Divider()
                .padding(.vertical, 4)

        case .table(let headers, let rows, _, _):
            tableView(headers: headers, rows: rows)
        }
    }

    // MARK: - Heading

    @ViewBuilder
    private func headingView(level: Int, inlines: [MarkdownInline]) -> some View {
        let text = Text(attributedString(inlines))
        switch level {
        case 1:
            VStack(alignment: .leading, spacing: 4) {
                text.font(.system(size: 28, weight: .bold))
                Divider()
            }
        case 2:
            VStack(alignment: .leading, spacing: 4) {
                text.font(.system(size: 22, weight: .semibold))
                    .padding(.top, 8)
                Divider()
            }
        case 3:
            text.font(.system(size: 18, weight: .semibold))
                .padding(.top, 4)
        case 4:
            text.font(.system(size: 16, weight: .semibold))
        default:
            text.font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Code block

    private func codeBlockView(language: String, code: String) -> some View {
        let content: Text
        if language.isEmpty {
            content = Text(code)
                .font(.system(.callout, design: .monospaced))
        } else {
            let nsAttr = SyntaxHighlighter.highlight(code: code, language: language)
            let attrStr: AttributedString
#if os(macOS)
            attrStr = (try? AttributedString(nsAttr, including: \.appKit)) ?? AttributedString(code)
#else
            attrStr = (try? AttributedString(nsAttr, including: \.uiKit)) ?? AttributedString(code)
#endif
            content = Text(attrStr)
        }
        return content
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(codeBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }

    // MARK: - Lists

    private func bulletListView(items: [MarkdownBlock.ListItem]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(attributedString(item.inlines))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 20)
            }
        }
    }

    private func orderedListView(items: [MarkdownBlock.ListItem]) -> some View {
        // Re-number items per depth level so nested lists restart at 1.
        var counters: [Int: Int] = [:]
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let count: Int = {
                    counters[item.depth, default: 0] += 1
                    // Reset deeper levels when we step back up
                    for key in counters.keys where key > item.depth {
                        counters[key] = 0
                    }
                    return counters[item.depth]!
                }()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(count).")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                    Text(attributedString(item.inlines))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, CGFloat(item.depth) * 20)
            }
        }
    }

    // MARK: - Table

    private func tableView(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                    Text(attributedString(cell))
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12))
                    Divider().frame(width: 1)
                }
            }
            Divider()
            // Data rows
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                        Text(attributedString(cell))
                            .font(.system(size: 13))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowIdx % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
                        if colIdx < row.count - 1 {
                            Divider().frame(width: 1)
                        }
                    }
                }
                Divider()
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    // MARK: - Blockquote

    private func blockquoteView(inlines: [MarkdownInline]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.6))
                .frame(width: 3)
                .cornerRadius(2)
            Text(attributedString(inlines))
                .foregroundStyle(.secondary)
                .italic()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: - AttributedString from inlines

    private func attributedString(_ inlines: [MarkdownInline]) -> AttributedString {
        inlines.reduce(AttributedString()) { result, inline in
            result + attributedStringForInline(inline)
        }
    }

    private func attributedStringForInline(_ inline: MarkdownInline) -> AttributedString {
        switch inline {
        case .text(let s):
            return AttributedString(s)

        case .bold(let children):
            var a = attributedString(children)
            a.font = .body.bold()
            return a

        case .italic(let children):
            var a = attributedString(children)
            a.font = .body.italic()
            return a

        case .code(let s):
            var a = AttributedString(s)
            a.font = .system(.body, design: .monospaced)
            a.backgroundColor = codeBackgroundSwiftUIColor
            return a

        case .link(let text, let url):
            var a = AttributedString(text)
            if let u = URL(string: url) { a.link = u }
            a.foregroundColor = .accentColor
            return a

        case .image(let alt, _):
            // Inline images in paragraphs fall back to alt text
            var a = AttributedString("[\(alt)]")
            a.foregroundColor = .secondary
            return a
        }
    }
}
