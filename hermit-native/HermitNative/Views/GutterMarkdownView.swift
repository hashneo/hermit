import SwiftUI

// MARK: - GutterMarkdownView
// Two-column layout: a narrow left gutter showing comment count badges
// and a right content column (MarkdownRendererView).
// Tapping a block selects it; an inline compose field expands below it.
// Fires onLineTapped so the parent (iPadRootView) can update the thread panel.

struct GutterMarkdownView: View {
    let blocks: [MarkdownBlock]
    var onLineTapped: ((Int) -> Void)? = nil

    @EnvironmentObject private var commentStore: CommentStore
    @State private var selectedLine: Int? = nil
    @State private var composeText: String = ""
    @State private var isSubmitting: Bool = false
    @State private var submitError: String? = nil

    // Floating + bubble state — tracks which block has an active text selection
    @State private var bubbleLine: Int? = nil
    @State private var bubbleText: String = ""
    @State private var bubbleRect: CGRect = .zero   // in the block content's coord space

    private let gutterWidth: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockRow(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Quote handler
    // Called from SelectableTextView when "Quote & Comment" is chosen.
    // Selects the block, pre-fills compose with a GitHub blockquote, scrolls compose into view.
    private func handleQuote(text: String, line: Int) {
        let quoted = text
            .components(separatedBy: "\n")
            .map { "> \($0)" }
            .joined(separator: "\n")
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedLine = line
            composeText = quoted + "\n\n"
            submitError = nil
        }
        onLineTapped?(line)
    }

    // MARK: - Per-block row

    @ViewBuilder
    private func blockRow(_ block: MarkdownBlock) -> some View {
        let line = block.sourceLine
        let isSelected = selectedLine == line
        let count = commentStore.count(for: line)
        let hasBubble = bubbleLine == line && !bubbleText.isEmpty

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                gutterCell(line: line, count: count, isSelected: isSelected)

                MarkdownBlockView(
                    block: block,
                    onQuoteSelected: { text in
                        handleQuote(text: text, line: line)
                    },
                    onSelectionChanged: { text, rect in
                        if let text {
                            bubbleLine = line
                            bubbleText = text
                            bubbleRect = rect
                        } else if bubbleLine == line {
                            bubbleLine = nil
                            bubbleText = ""
                        }
                    }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if selectedLine == line {
                            selectedLine = nil; composeText = ""; submitError = nil
                        } else {
                            selectedLine = line; composeText = ""; submitError = nil
                        }
                    }
                    onLineTapped?(line)
                }
                .background(isSelected ? Color.accentColor.opacity(0.05) : Color.clear)
                // + bubble overlay — anchored to bottom-right of selection rect
                .overlay(alignment: .topLeading) {
                    if hasBubble {
                        commentBubble(line: line)
                            // Offset to sit just below-right of the selection end
                            .offset(x: bubbleRect.maxX + 4, y: bubbleRect.maxY - 4)
                    }
                }
            }

            if isSelected {
                inlineCompose(for: line)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Divider().opacity(0.4)
        }
    }

    // MARK: - Floating + bubble

    private func commentBubble(line: Int) -> some View {
        Button {
            handleQuote(text: bubbleText, line: line)
            bubbleLine = nil; bubbleText = ""
        } label: {
            Image(systemName: "plus.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(
                    Circle().fill(Color.accentColor)
                        .shadow(color: .black.opacity(0.18), radius: 4, x: 0, y: 2)
                )
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: bubbleLine)
        .help("Quote this selection and add a comment")
    }

    // MARK: - Gutter cell

    private func gutterCell(line: Int, count: Int, isSelected: Bool) -> some View {
        ZStack {
            Rectangle()
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.clear)

            if count > 0 {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selectedLine = (selectedLine == line) ? nil : line
                        composeText = ""
                        submitError = nil
                    }
                    onLineTapped?(line)
                } label: {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor))
                }
                .buttonStyle(.plain)
            } else if isSelected {
                Image(systemName: "plus.bubble.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor.opacity(0.8))
            }
        }
        .frame(width: gutterWidth)
        .frame(maxHeight: .infinity)
    }

    // MARK: - Inline compose

    @ViewBuilder
    private func inlineCompose(for line: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = submitError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, gutterWidth + 12)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Indent to align with content column
                Spacer().frame(width: gutterWidth)

                TextField("Add a comment…", text: $composeText, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.system(size: 14))
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor.opacity(0.4), lineWidth: 1)
                    )

                VStack(spacing: 6) {
                    Button {
                        Task { await submitComment(line: line) }
                    } label: {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 14))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(composeText.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                    .frame(width: 38, height: 38)

                    Button {
                        withAnimation { selectedLine = nil; composeText = ""; submitError = nil }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(Color.accentColor.opacity(0.03))
    }

    // MARK: - Submit

    private func submitComment(line: Int) async {
        let body = composeText.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        isSubmitting = true
        submitError = nil
        do {
            try await commentStore.postComment(body: body, line: line)
            withAnimation { selectedLine = nil; composeText = "" }
        } catch {
            submitError = error.localizedDescription
        }
        isSubmitting = false
    }
}

// MARK: - MarkdownBlockView

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    var onQuoteSelected: ((String) -> Void)? = nil
    /// Called when text selection changes inside this block.
    /// Receives (selectedText, selectionRect-in-view-coords) — nil text means deselected.
    var onSelectionChanged: ((String?, CGRect) -> Void)? = nil

    private var codeBackground: Color {
#if os(macOS)
        Color(nsColor: .windowBackgroundColor)
#else
        Color(uiColor: .secondarySystemBackground)
#endif
    }

#if os(macOS)
    private func monoFont(_ size: CGFloat = NSFont.systemFontSize - 1) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
#else
    private func monoFont(_ size: CGFloat = UIFont.systemFontSize - 1) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
#endif

    var body: some View {
        switch block {
        case .heading(let level, let inlines, _):
            headingView(level: level, inlines: inlines)
        case .paragraph(let inlines, _):
            selectable(inlines.nsAttributedString())
                .fixedSize(horizontal: false, vertical: true)
        case .codeBlock(let lang, let code, _):
            codeBlockView(language: lang, code: code)
        case .mermaidBlock(let source, _):
            MermaidView(source: source)
                .frame(minHeight: 200)
                .frame(maxWidth: .infinity)
        case .bulletList(let items, _):
            bulletListView(items: items)
        case .orderedList(let items, _):
            orderedListView(items: items)
        case .blockquote(let inlines, _):
            blockquoteView(inlines: inlines)
        case .horizontalRule(_):
            Divider().padding(.vertical, 4)
        case .table(let headers, let rows, _):
            tableView(headers: headers, rows: rows)
        }
    }

    // Convenience: wrap an NSAttributedString in a SelectableTextView with callbacks wired
    private func selectable(_ attrStr: NSAttributedString) -> SelectableTextView {
        SelectableTextView(
            attributedText: attrStr,
            onQuoteSelected: onQuoteSelected,
            onSelectionChanged: { text, rect in onSelectionChanged?(text, rect) }
        )
    }

    // MARK: Heading
    @ViewBuilder
    private func headingView(level: Int, inlines: [MarkdownInline]) -> some View {
        let sizes: [Int: CGFloat] = [1: 28, 2: 22, 3: 18, 4: 16]
        let sz = sizes[level] ?? 14
#if os(macOS)
        let wt: NSFont.Weight = level <= 2 ? .semibold : .medium
        let font = NSFont.systemFont(ofSize: sz, weight: wt)
#else
        let wt: UIFont.Weight = level <= 2 ? .semibold : .medium
        let font = UIFont.systemFont(ofSize: sz, weight: wt)
#endif
        let attrStr = inlines.nsAttributedString(font: font)
        if level == 1 {
            VStack(alignment: .leading, spacing: 4) {
                selectable(attrStr)
                Divider()
            }
        } else {
            selectable(attrStr)
                .padding(.top, level == 2 ? 8 : level == 3 ? 4 : 0)
        }
    }

    // MARK: Code block — monospaced selectable text inside styled container
    private func codeBlockView(language: String, code: String) -> some View {
#if os(macOS)
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .regular)
        let attr = NSAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
#else
        let font = UIFont.monospacedSystemFont(ofSize: UIFont.systemFontSize - 1, weight: .regular)
        let attr = NSAttributedString(string: code, attributes: [
            .font: font,
            .foregroundColor: UIColor.label
        ])
#endif
        return selectable(attr)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(codeBackground))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
    }

    // MARK: Lists — each item is its own selectable run
    private func bulletListView(items: [[MarkdownInline]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, inlines in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.secondary)
                    selectable(inlines.nsAttributedString())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func orderedListView(items: [[MarkdownInline]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, inlines in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).").foregroundStyle(.secondary).frame(minWidth: 20, alignment: .trailing)
                    selectable(inlines.nsAttributedString())
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Blockquote
    private func blockquoteView(inlines: [MarkdownInline]) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle().fill(Color.accentColor.opacity(0.6)).frame(width: 3).cornerRadius(2)
            selectable(inlines.nsAttributedString())
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }

    // MARK: Table — each cell is selectable
    private func tableView(headers: [[MarkdownInline]], rows: [[[MarkdownInline]]]) -> some View {
#if os(macOS)
        let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont   = NSFont.systemFont(ofSize: 13, weight: .regular)
#else
        let headerFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
        let bodyFont   = UIFont.systemFont(ofSize: 13, weight: .regular)
#endif
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                    selectable(cell.nsAttributedString(font: headerFont))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.12))
                    Divider().frame(width: 1)
                }
            }
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                HStack(spacing: 0) {
                    ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                        selectable(cell.nsAttributedString(font: bodyFont))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(rowIdx % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
                        if colIdx < row.count - 1 { Divider().frame(width: 1) }
                    }
                }
                Divider()
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25), lineWidth: 1))
        .cornerRadius(6)
    }
}
