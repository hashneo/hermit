import SwiftUI

// MARK: - MarkdownRendererView: native SwiftUI renderer for [MarkdownBlock]

struct MarkdownRendererView: View {
    let blocks: [MarkdownBlock]

    private var codeBackground: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .secondarySystemBackground)
#endif
    }

    private var codeBackgroundSwiftUIColor: Color {
        codeBackground
    }

    var body: some View {        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let inlines):
            headingView(level: level, inlines: inlines)

        case .paragraph(let inlines):
            Text(attributedString(inlines))
                .fixedSize(horizontal: false, vertical: true)

        case .codeBlock(let lang, let code):
            codeBlockView(language: lang, code: code)

        case .mermaidBlock(let source):
            MermaidView(source: source)
                .frame(minHeight: 200)
                .frame(maxWidth: .infinity)

        case .bulletList(let items):
            bulletListView(items: items)

        case .orderedList(let items):
            orderedListView(items: items)

        case .blockquote(let inlines):
            blockquoteView(inlines: inlines)

        case .horizontalRule:
            Divider()
                .padding(.vertical, 4)
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
            text.font(.system(size: 22, weight: .semibold))
                .padding(.top, 8)
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
        Text(code)
            .font(.system(.callout, design: .monospaced))
            .foregroundStyle(.primary)
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

    private func bulletListView(items: [[MarkdownInline]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, inlines in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                        .foregroundStyle(.secondary)
                    Text(attributedString(inlines))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func orderedListView(items: [[MarkdownInline]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, inlines in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 20, alignment: .trailing)
                    Text(attributedString(inlines))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
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
