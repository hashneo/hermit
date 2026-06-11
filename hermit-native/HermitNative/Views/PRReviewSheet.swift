import SwiftUI

struct PRReviewSheet: View {

    /// Controls the compose section at the bottom of the sheet.
    /// - `.requestChanges`: standard reviewer flow — GitHub review, red button.
    /// - `.lineComment`: PR-author flow — anchored comment, blue button.
    enum SubmitMode {
        case requestChanges
        case lineComment
    }

    let rfcTitle: String
    let currentUserLogin: String
    var submitMode: SubmitMode = .requestChanges
    var onSubmit: (String) async throws -> Void
    var onDismiss: (Int64) async throws -> Void
    var onRefresh: () async throws -> [PRReview]
    /// Fetches author line-comments (threads). Nil means the caller doesn't support it.
    var onFetchThreads: (() async throws -> [ReviewThread])? = nil
    /// Deletes a thread by ID. Only offered when the thread has one message, is unresolved, and authored by currentUserLogin.
    var onDeleteThread: ((String) async throws -> Void)? = nil
    /// When true (RFC accepted), unresolved threads are hidden and the compose section is suppressed.
    var isAccepted: Bool = false

    @Environment(\.dismiss) private var dismiss

    @State private var reviewText: String = ""
    @State private var isSubmitting = false
    @State private var isLoading = true
    @State private var reviews: [PRReview] = []
    @State private var threads: [ReviewThread] = []
    @State private var loadError: String? = nil
    @State private var submitError: String? = nil
    @State private var isDismissing: Set<Int64> = []
    @State private var pendingDismissID: Int64? = nil
    @State private var isDeletingThread: Set<String> = []
    @State private var pendingDeleteThreadID: String? = nil

    private var changesRequestedReviews: [PRReview] {
        reviews.filter { $0.isChangesRequested }
    }

    private var otherReviews: [PRReview] {
        reviews.filter { !$0.isChangesRequested && !$0.isDismissed && !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Header ──────────────────────────────────────────────
            HStack {
                Text("Reviews")
                    .font(.headline)
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.borderless)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            // ── Content ─────────────────────────────────────────────
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if isLoading {
                        HStack {
                            Spacer()
                            ProgressView("Loading reviews…")
                            Spacer()
                        }
                        .padding(32)
                    } else {
                        if let err = loadError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                Text(err)
                                    .foregroundStyle(.secondary)
                                    .font(.callout)
                            }
                            .padding(16)
                        }

                        // Outstanding CHANGES_REQUESTED
                        if !changesRequestedReviews.isEmpty {
                            sectionHeader("Changes Requested", icon: "exclamationmark.bubble.fill", color: .red)
                            ForEach(changesRequestedReviews) { review in
                                reviewRow(review)
                                Divider().padding(.leading, 16)
                            }
                        }

                        // Other reviews
                        if !otherReviews.isEmpty {
                            sectionHeader("Other Reviews", icon: "bubble.left", color: .secondary)
                            ForEach(otherReviews) { review in
                                reviewRow(review)
                                Divider().padding(.leading, 16)
                            }
                        }

                        // Author line-comments (threads)
                        let visibleThreads = threads.filter {
                            !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            && (!isAccepted || $0.resolved)
                        }
                        if !visibleThreads.isEmpty {
                            sectionHeader("Comments", icon: "text.bubble", color: .secondary)
                            ForEach(visibleThreads) { thread in
                                threadRow(thread)
                                Divider().padding(.leading, 16)
                            }
                        }

                        if !isLoading && reviews.isEmpty && threads.isEmpty && loadError == nil {
                            Text("No reviews yet.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .padding(16)
                        }

                        // ── Compose ────────────────────────────────
                        if !isAccepted {
                            let composeTitle  = submitMode == .lineComment ? "Add Comment" : "Request Changes"
                            let composeIcon   = submitMode == .lineComment ? "bubble.left"  : "pencil.and.list.clipboard"
                            let placeholder   = submitMode == .lineComment
                                ? "Write a comment anchored to the top of this RFC…"
                                : "Describe what must change before this RFC can merge…"
                            let submitLabel   = submitMode == .lineComment ? "Post Comment" : "Request Changes"
                            let submitTint    = submitMode == .lineComment ? Color.accentColor : Color.red
                            sectionHeader(composeTitle, icon: composeIcon, color: .primary)

                            VStack(alignment: .leading, spacing: 10) {
                                ZStack(alignment: .topLeading) {
                                    TextEditor(text: $reviewText)
                                        .frame(minHeight: 100)
                                        .font(.body)
                                    .scrollContentBackground(.hidden)
                                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                                        .cornerRadius(6)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 6)
                                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                        )
                                    if reviewText.isEmpty {
                                        Text(placeholder)
                                            .foregroundStyle(.tertiary)
                                            .font(.body)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 8)
                                            .allowsHitTesting(false)
                                    }
                                }

                                if let err = submitError {
                                    Label(err, systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                }

                                HStack {
                                    Spacer()
                                    Button {
                                        Task { await submit() }
                                    } label: {
                                        HStack(spacing: 6) {
                                            if isSubmitting {
                                                ProgressView().controlSize(.small)
                                            }
                                            Text(submitLabel)
                                                .fontWeight(.semibold)
                                        }
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(submitTint)
                                    .disabled(reviewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSubmitting)
                                }
                            }
                            .padding(16)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .task { await load() }
        .confirmationDialog(
            "Dismiss this review?",
            isPresented: Binding(
                get: { pendingDismissID != nil },
                set: { if !$0 { pendingDismissID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let rid = pendingDismissID {
                Button("Dismiss Review", role: .destructive) {
                    Task { await doDismiss(rid) }
                }
                Button("Cancel", role: .cancel) { pendingDismissID = nil }
            }
        } message: {
            Text("This will withdraw your Request Changes review.")
        }
        .confirmationDialog(
            "Delete this comment?",
            isPresented: Binding(
                get: { pendingDeleteThreadID != nil },
                set: { if !$0 { pendingDeleteThreadID = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let tid = pendingDeleteThreadID {
                Button("Delete Comment", role: .destructive) {
                    Task { await doDeleteThread(tid) }
                }
                Button("Cancel", role: .cancel) { pendingDeleteThreadID = nil }
            }
        } message: {
            Text("This will permanently delete your comment.")
        }
    }

    // MARK: - Sub-views

    @ViewBuilder
    private func sectionHeader(_ title: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(color)
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    private func reviewRow(_ review: PRReview) -> some View {
        HStack(alignment: .top, spacing: 10) {
            stateDot(review.state)
                .frame(width: 16, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(review.user)
                        .fontWeight(.semibold)
                        .font(.callout)
                    Spacer()
                    Text(review.submittedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !review.body.isEmpty {
                    let cleaned = Self.stripHTML(review.body)
                    let blocks = MarkdownParser.parse(cleaned)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                            MarkdownBlockView(block: block)
                        }
                    }
                    .padding(.top, 2)
                }
                if review.isChangesRequested && review.user == currentUserLogin {
                    Button {
                        pendingDismissID = review.id
                    } label: {
                        if isDismissing.contains(review.id) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Dismiss my review", systemImage: "xmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isDismissing.contains(review.id))
                    .padding(.top, 2)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func threadRow(_ thread: ReviewThread) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: thread.resolved ? "checkmark.bubble.fill" : "bubble.left.fill")
                .foregroundStyle(thread.resolved ? Color.secondary : Color.accentColor)
                .frame(width: 16, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(thread.user)
                        .fontWeight(.semibold)
                        .font(.callout)
                    if thread.resolved {
                        Text("resolved")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Text(thread.createdAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    let canDelete = onDeleteThread != nil
                        && !thread.resolved
                        && thread.messages.count == 1
                        && thread.user == currentUserLogin
                    if canDelete {
                        Button {
                            pendingDeleteThreadID = thread.id
                        } label: {
                            if isDeletingThread.contains(thread.id) {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: "trash")
                                    .font(.caption)
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isDeletingThread.contains(thread.id))
                        .help("Delete this comment")
                    }
                }
                // Show all messages in the thread (root + replies)
                ForEach(Array(thread.messages.enumerated()), id: \.element.id) { idx, msg in
                    if idx > 0 {
                        // Replies indented slightly
                        HStack(alignment: .top, spacing: 6) {
                            Rectangle()
                                .fill(Color.secondary.opacity(0.25))
                                .frame(width: 2)
                                .padding(.vertical, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(msg.author)
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.secondary)
                                let blocks = MarkdownParser.parse(msg.body)
                                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                    MarkdownBlockView(block: block)
                                }
                            }
                        }
                        .padding(.top, 4)
                    } else if !msg.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        let blocks = MarkdownParser.parse(msg.body)
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                MarkdownBlockView(block: block)
                            }
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func stateDot(_ state: String) -> some View {
        switch state {
        case "APPROVED":
            Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
        case "CHANGES_REQUESTED", "REQUEST_CHANGES":
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.red)
        case "DISMISSED":
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        default:
            Image(systemName: "bubble.left.fill").foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    /// Strips HTML tags from a string, replacing block-level tags with newlines
    /// and converting common entities. Used to clean GitHub bot review bodies
    /// before Markdown parsing.
    private static func stripHTML(_ input: String) -> String {
        // Replace block-level tags with newlines so paragraph structure is preserved
        var s = input
        let blockTags = ["</p>", "</div>", "</li>", "<br>", "<br/>", "<br />"]
        for tag in blockTags {
            s = s.replacingOccurrences(of: tag, with: "\n", options: .caseInsensitive)
        }
        // Strip all remaining tags
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        // Decode common HTML entities
        s = s.replacingOccurrences(of: "&amp;",  with: "&")
        s = s.replacingOccurrences(of: "&lt;",   with: "<")
        s = s.replacingOccurrences(of: "&gt;",   with: ">")
        s = s.replacingOccurrences(of: "&quot;", with: "\"")
        s = s.replacingOccurrences(of: "&#39;",  with: "'")
        s = s.replacingOccurrences(of: "&nbsp;", with: " ")
        // Collapse runs of 3+ newlines to 2
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() async {
        isLoading = true
        loadError = nil
        async let fetchReviews = onRefresh()
        async let fetchThreads = onFetchThreads?() ?? []
        do {
            let (r, t) = try await (fetchReviews, fetchThreads)
            reviews = r
            threads = t
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func submit() async {
        let body = reviewText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        isSubmitting = true
        submitError = nil
        do {
            try await onSubmit(body)
            reviewText = ""
            if let r = try? await onRefresh() { reviews = r }
            if let t = try? await onFetchThreads?() { threads = t }
        } catch {
            submitError = error.localizedDescription
        }
        isSubmitting = false
    }

    private func doDismiss(_ reviewID: Int64) async {
        pendingDismissID = nil
        isDismissing.insert(reviewID)
        do {
            try await onDismiss(reviewID)
            reviews = (try? await onRefresh()) ?? reviews
        } catch {
            submitError = error.localizedDescription
        }
        isDismissing.remove(reviewID)
    }

    private func doDeleteThread(_ threadID: String) async {
        pendingDeleteThreadID = nil
        isDeletingThread.insert(threadID)
        do {
            try await onDeleteThread?(threadID)
            if let t = try? await onFetchThreads?() { threads = t }
        } catch {
            submitError = error.localizedDescription
        }
        isDeletingThread.remove(threadID)
    }
}
