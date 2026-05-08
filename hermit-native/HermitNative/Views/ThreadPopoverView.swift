import SwiftUI
#if canImport(UIKit)
import UIKit

// MARK: - GrowingTextView
// UIViewRepresentable wrapping UITextView so we control textContainerInset
// exactly — eliminating the alignment gap between cursor and placeholder
// that SwiftUI's TextEditor introduces.

private struct GrowingTextView: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Reply…"
    var font: UIFont = .preferredFont(forTextStyle: .subheadline)
    var maxLines: Int = 5
    var isDisabled: Bool = false
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UITextView {
        let tv = UITextView()
        tv.delegate = context.coordinator
        tv.font = font
        tv.backgroundColor = .clear
        tv.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 4)
        tv.textContainer.lineFragmentPadding = 0
        tv.isScrollEnabled = false
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let ph = UILabel()
        ph.text = placeholder
        ph.font = font
        ph.textColor = .tertiaryLabel
        ph.tag = 999
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: 8),
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 4),
        ])

        return tv
    }

    func updateUIView(_ tv: UITextView, context: Context) {
        if tv.text != text { tv.text = text }
        tv.isEditable = !isDisabled
        tv.isSelectable = !isDisabled
        if let ph = tv.viewWithTag(999) { ph.isHidden = !text.isEmpty }

        let lineH = font.lineHeight
        let insets = tv.textContainerInset.top + tv.textContainerInset.bottom
        let maxH = lineH * CGFloat(maxLines) + insets
        tv.isScrollEnabled = tv.contentSize.height > maxH
    }

    class Coordinator: NSObject, UITextViewDelegate {
        var parent: GrowingTextView
        init(_ parent: GrowingTextView) { self.parent = parent }

        func textViewDidChange(_ tv: UITextView) {
            parent.text = tv.text
            tv.invalidateIntrinsicContentSize()
        }
        func textViewDidBeginEditing(_ tv: UITextView) { parent.onFocusChange(true) }
        func textViewDidEndEditing(_ tv: UITextView)   { parent.onFocusChange(false) }
    }
}
#endif

#if os(macOS)
import AppKit

// NSTextView subclass that reports an intrinsic height so SwiftUI
// allocates space before the user types.
private class AutosizingTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let lm = layoutManager, let tc = textContainer, let f = font else {
            return NSSize(width: NSView.noIntrinsicMetric, height: 36)
        }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc).height
        let insetH = textContainerInset.height * 2
        let lineH = lm.defaultLineHeight(for: f)
        let contentH = used > 0 ? used : lineH
        return NSSize(width: NSView.noIntrinsicMetric, height: contentH + insetH)
    }
}

// MARK: - GrowingTextView (macOS)
private struct GrowingTextView: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String = "Reply…"
    var maxLines: Int = 5
    var isDisabled: Bool = false
    var onFocusChange: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = AutosizingTextView()
        tv.delegate = context.coordinator
        tv.font = .preferredFont(forTextStyle: .body)
        tv.backgroundColor = .clear
        tv.isRichText = false
        tv.isEditable = !isDisabled
        tv.isSelectable = true
        tv.textContainerInset = NSSize(width: 4, height: 8)
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]

        // Placeholder
        let ph = NSTextField(labelWithString: placeholder)
        ph.font = tv.font
        ph.textColor = .tertiaryLabelColor
        ph.tag = 999
        ph.translatesAutoresizingMaskIntoConstraints = false
        tv.addSubview(ph)
        NSLayoutConstraint.activate([
            ph.topAnchor.constraint(equalTo: tv.topAnchor, constant: 8),
            ph.leadingAnchor.constraint(equalTo: tv.leadingAnchor, constant: 6),
        ])

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        tv.frame = CGRect(x: 0, y: 0, width: scroll.bounds.width, height: 0)
        context.coordinator.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        if tv.string != text { tv.string = text }
        tv.isEditable = !isDisabled
        if let ph = tv.viewWithTag(999) { ph.isHidden = !text.isEmpty }
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: GrowingTextView
        weak var textView: NSTextView?
        init(_ parent: GrowingTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            tv.invalidateIntrinsicContentSize()
        }
        func textDidBeginEditing(_ notification: Notification) { parent.onFocusChange(true) }
        func textDidEndEditing(_ notification: Notification)   { parent.onFocusChange(false) }
    }
}
#endif

// MARK: - ScrollContentHeightKey
// Measures the natural height of the scroll content so the ScrollView can
// size itself to fit, capped at a fraction of the window height.
private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - PopoverSizeModifier
// Sizes the popover width; height is driven by content via ScrollContentHeightKey.

private struct PopoverSizeModifier: ViewModifier {
    let containerWidth: CGFloat

    func body(content: Content) -> some View {
        content
            .frame(width: max(480, containerWidth * 0.8))
    }
}

// MARK: - CommentBodyView
// Renders a GitHub-style comment body.
// Lines starting with "> " are shown as Slack-style block quotes
// (left accent bar + italic muted text). All other lines are plain text.

struct CommentBodyView: View {
    let text: String

    // Split body into runs of quote-lines and plain-lines
    private struct Run: Identifiable {
        let id = UUID()
        let isQuote: Bool
        let text: String  // joined lines, ">" prefix stripped for quotes
    }

    private var runs: [Run] {
        var result: [Run] = []
        var currentQuote = false
        var currentLines: [String] = []

        func flush(isQuote: Bool, lines: [String]) -> Run {
            Run(isQuote: isQuote, text: lines.joined(separator: "\n"))
        }

        for line in text.components(separatedBy: "\n") {
            let isQuote = line.hasPrefix("> ") || line == ">"
            let stripped = isQuote ? String(line.dropFirst(line.hasPrefix("> ") ? 2 : 1)) : line

            if isQuote != currentQuote && !currentLines.isEmpty {
                result.append(flush(isQuote: currentQuote, lines: currentLines))
                currentLines = []
            }
            currentQuote = isQuote
            currentLines.append(stripped)
        }
        if !currentLines.isEmpty {
            result.append(flush(isQuote: currentQuote, lines: currentLines))
        }
        // Drop trailing blank plain runs
        while result.last.map({ !$0.isQuote && $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) == true {
            result.removeLast()
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(runs) { run in
                if run.isQuote {
                    HStack(alignment: .top, spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.7))
                            .frame(width: 3)
                        Text(run.text)
                            .font(.subheadline.italic())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                    .padding(.horizontal, 2)
                    .background(Color.accentColor.opacity(0.05))
                    .cornerRadius(4)
                } else {
                    Text(run.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - ThreadPopoverView
//
// Google Docs-style conversation popover anchored to a gutter badge.
// Shows all messages in every thread for a given line, with a reply
// field at the bottom of each thread.
//
// Presented via .popover() attached to the gutter badge button so it
// appears to the left of the content column on iPad (leading edge).

struct ThreadPopoverView: View {
    let line: Int
    var lineEnd: Int? = nil
    @Binding var isEditing: Bool
    var containerWidth: CGFloat = 600
    var containerHeight: CGFloat = 800
    var blockRanges: [(start: Int, end: Int)] = []
    /// When set, only show threads matching the outdated flag.
    /// nil = show all (legacy behaviour), true = outdated only, false = current only.
    var outdatedOnly: Bool? = nil
    @EnvironmentObject private var commentStore: CommentStore

    @State private var replyText: [String: String] = [:]
    @State private var submitting: [String: Bool]  = [:]
    @State private var errors:     [String: String] = [:]
    @State private var deleting:   [String: Bool]  = [:]
    @State private var resolving:  [String: Bool]  = [:]
    @State private var pendingDeleteThreadId: String? = nil
    @State private var pendingResolveThreadId: String? = nil
    @State private var scrollContentHeight: CGFloat = 0
    @FocusState private var replyFocused: Bool

    private let lineHeight: CGFloat = 20   // approx .subheadline line height
    private let maxEditorLines: Int = 5

    private var hasUnsavedText: Bool {
        replyText.values.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var threads: [ReviewThread] {
        let all = commentStore.comments(for: line, lineEnd: lineEnd, blockRanges: blockRanges)
        guard let filter = outdatedOnly else { return all }
        return all.filter { $0.outdated == filter }
    }

    private var rootThread: ReviewThread? { threads.first }

    private var allMessages: [(message: ThreadMessage, resolved: Bool, threadId: String)] {
        threads.flatMap { thread in thread.messages.map { ($0, thread.resolved, thread.id) } }
    }

    var body: some View {
        threadContent
            .modifier(PopoverSizeModifier(containerWidth: containerWidth))
            .task { await commentStore.load() }
            // Reload every 15 s while the popover is open so new replies appear.
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(15))
                    await commentStore.load()
                }
            }
            .onChange(of: replyText) { _, _ in isEditing = hasUnsavedText }
            .confirmationDialog(
                "Delete Comment",
                isPresented: Binding(
                    get: { pendingDeleteThreadId != nil },
                    set: { if !$0 { pendingDeleteThreadId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let threadId = pendingDeleteThreadId {
                        pendingDeleteThreadId = nil
                        Task { await deleteComment(threadId: threadId) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingDeleteThreadId = nil }
            } message: {
                Text("This will permanently delete your comment. This cannot be undone.")
            }
            .confirmationDialog(
                "Resolve Conversation",
                isPresented: Binding(
                    get: { pendingResolveThreadId != nil },
                    set: { if !$0 { pendingResolveThreadId = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Resolve") {
                    if let threadId = pendingResolveThreadId {
                        pendingResolveThreadId = nil
                        Task { await resolveThread(threadId: threadId) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingResolveThreadId = nil }
            } message: {
                Text("Mark this conversation as resolved on GitHub.")
            }
    }

    private var threadContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(Color.accentColor)
                Text("Comment")
                    .font(.subheadline).fontWeight(.semibold)
                if let root = rootThread, root.outdated {
                    Text("Outdated")
                        .font(.caption2).fontWeight(.medium)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if threads.isEmpty {
                Text("No comments on this line.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(14)
            } else {
                // Messages scroll — sizes to content, capped at 75% of window height
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(allMessages, id: \.message.id) { item in
                            let isLast = item.message.id == allMessages.last?.message.id
                            messageRow(item.message, resolved: item.resolved, threadId: item.threadId, isLast: isLast)
                            if !isLast {
                                Divider().padding(.horizontal, 14)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: ScrollContentHeightKey.self,
                                                   value: geo.size.height)
                        }
                    )
                }
                .frame(height: min(scrollContentHeight, containerHeight * 0.75))
                .onPreferenceChange(ScrollContentHeightKey.self) { scrollContentHeight = $0 }

                Divider()

                if let root = rootThread, !root.resolved {
                    let isOriginalAuthor = !commentStore.currentUserLogin.isEmpty &&
                                          root.user == commentStore.currentUserLogin
                    let isBotAuthor = root.user.hasSuffix("[bot]")
                    let canResolve = isOriginalAuthor || root.outdated || isBotAuthor
                    let isResolvingThis = resolving[root.id] == true

                    // Resolve button — shown to original author always; shown to anyone for outdated or bot-authored threads
                    if canResolve {
                        Divider()
                        HStack {
                            Spacer()
                            Button {
                                pendingResolveThreadId = root.id
                            } label: {
                                if isResolvingThis {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Label("Resolve Conversation", systemImage: "checkmark.circle")
                                        .font(.subheadline)
                                }
                            }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.green)
                            .disabled(isResolvingThis)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                        }
                    }

                    replyField(for: root)
                }
            }
        }
    }

    // MARK: - Date formatting

    private func formatMessageDate(_ date: Date) -> String {
        let age = Date.now.timeIntervalSince(date)
        if age < 3600 {
            let mins = max(1, Int(age / 60))
            return "\(mins)m ago"
        } else if age < 86400 {
            let hours = Int(age / 3600)
            return "\(hours)h ago"
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        }
    }

    // MARK: - Message row

    private func messageRow(_ message: ThreadMessage, resolved: Bool, threadId: String, isLast: Bool) -> some View {
        let isMyComment = !commentStore.currentUserLogin.isEmpty &&
                          message.author == commentStore.currentUserLogin
        let canDelete = isMyComment && !resolved && isLast
        let isDeletingThis = deleting[threadId] == true

        return HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.accentColor.opacity(0.2))
                .frame(width: 26, height: 26)
                .overlay(
                    Text(String(message.author.prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(message.author)
                        .font(.caption).fontWeight(.semibold)
                    Spacer()
                    Text(formatMessageDate(message.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if canDelete {
                        Button {
                            pendingDeleteThreadId = threadId
                        } label: {
                            if isDeletingThis {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "trash")
                                    .font(.caption2)
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isDeletingThis)
                        .help("Delete your comment")
                    }
                }
                CommentBodyView(text: message.body)
                    .foregroundStyle(resolved ? .secondary : .primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Delete comment

    private func deleteComment(threadId: String) async {
        deleting[threadId] = true
        do {
            try await commentStore.deleteComment(threadId: threadId)
        } catch {
            errors[threadId] = error.localizedDescription
        }
        deleting[threadId] = false
    }

    // MARK: - Resolve thread

    private func resolveThread(threadId: String) async {
        resolving[threadId] = true
        do {
            try await commentStore.resolveThread(threadId: threadId)
        } catch {
            errors[threadId] = error.localizedDescription
        }
        resolving[threadId] = false
    }

    // MARK: - Reply field

    @ViewBuilder
    private func replyField(for thread: ReviewThread) -> some View {
        let threadId = thread.id
        let isSubmitting = submitting[threadId] == true
        let text = replyText[threadId] ?? ""

        VStack(alignment: .leading, spacing: 4) {
            if let err = errors[threadId] {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }

            HStack(alignment: .bottom, spacing: 8) {
                Group {
                    GrowingTextView(
                        text: Binding(
                            get: { replyText[threadId] ?? "" },
                            set: { replyText[threadId] = $0 }
                        ),
                        maxLines: maxEditorLines,
                        isDisabled: isSubmitting,
                        onFocusChange: { replyFocused = $0 }
                    )
                    .frame(minHeight: 38)
                }
                .background(Color.secondary.opacity(0.07))
                .cornerRadius(8)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(replyFocused ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25))
                )

                VStack(spacing: 6) {
                    // Clear button
                    if !text.isEmpty {
                        Button {
                            replyText[threadId] = ""
                            isEditing = false
                            replyFocused = false
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }

                    // Send button
                    Button {
                        Task { await submitReply(to: thread) }
                    } label: {
                        if isSubmitting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Color.accentColor)
                                .font(.title3)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isSubmitting || text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: - Submit reply

    private func submitReply(to thread: ReviewThread) async {
        let body = (replyText[thread.id] ?? "").trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        submitting[thread.id] = true
        errors[thread.id] = nil
        do {
            try await commentStore.replyToThread(threadId: thread.id, body: body)
            replyText[thread.id] = ""
            isEditing = false
        } catch {
            errors[thread.id] = error.localizedDescription
        }
        submitting[thread.id] = false
    }
}
