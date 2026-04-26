import SwiftUI

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
    @EnvironmentObject private var commentStore: CommentStore

    @State private var replyText: [String: String] = [:]   // threadId → draft
    @State private var submitting: [String: Bool]  = [:]   // threadId → isSubmitting
    @State private var errors:     [String: String] = [:]  // threadId → error

    private var threads: [ReviewThread] {
        commentStore.comments(for: line)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .foregroundStyle(Color.accentColor)
                Text("Line \(line)")
                    .font(.subheadline).fontWeight(.semibold)
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(threads) { thread in
                            threadSection(thread)
                            Divider()
                        }
                    }
                }
            }
        }
        .frame(width: 340)
        .frame(maxHeight: 480)
    }

    // MARK: - Thread section

    @ViewBuilder
    private func threadSection(_ thread: ReviewThread) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Messages
            ForEach(thread.messages) { message in
                messageRow(message, resolved: thread.resolved)
            }

            // Status badge
            if thread.resolved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text("Resolved")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            } else {
                // Reply field
                replyField(for: thread)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Message row

    private func messageRow(_ message: ThreadMessage, resolved: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
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
                    Text(message.createdAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                CommentBodyView(text: message.body)
                    .foregroundStyle(resolved ? .secondary : .primary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Reply field

    @ViewBuilder
    private func replyField(for thread: ReviewThread) -> some View {
        let threadId = thread.id
        let isSubmitting = submitting[threadId] == true
        let errorMsg = errors[threadId]

        VStack(alignment: .leading, spacing: 4) {
            if let err = errorMsg {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
            }

            HStack(alignment: .bottom, spacing: 8) {
                TextField("Reply…", text: Binding(
                    get: { replyText[threadId] ?? "" },
                    set: { replyText[threadId] = $0 }
                ), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .disabled(isSubmitting)

                Button {
                    Task { await submitReply(to: thread) }
                } label: {
                    if isSubmitting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting || (replyText[threadId] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
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
        } catch {
            errors[thread.id] = error.localizedDescription
        }
        submitting[thread.id] = false
    }
}
