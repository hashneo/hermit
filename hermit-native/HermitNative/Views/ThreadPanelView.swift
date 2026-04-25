import SwiftUI

// MARK: - hermit-lem: ThreadPanelView — PR comment thread list filtered to selected line
// hermit-3lm: ComposeCommentView — comment compose sheet with text and voice toggle
// hermit-2ni: Stale SHA detection and refresh prompt
// hermit-3ey: PR approval button and confirmation flow

struct ThreadPanelView: View {
    let prNumber: Int
    /// The 1-based raw markdown source line the user tapped, if any.
    var selectedLine: Int? = nil

    @EnvironmentObject private var commentStore: CommentStore

    @State private var showApproveConfirm = false
    @State private var reviewState: ReviewState? = nil
    @State private var staleSHADetected = false  // hermit-2ni

    // Comments for the currently selected line (or all if no line selected)
    private var visibleComments: [PRReviewComment] {
        if let line = selectedLine {
            return commentStore.comments(for: line)
        }
        return commentStore.comments.sorted { $0.createdAt < $1.createdAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PR #\(prNumber)")
                        .font(.headline)
                    if let line = selectedLine {
                        Text("Line \(line)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                // hermit-3ey: approve button
                if let rv = reviewState, !rv.approved {
                    Button("Approve") { showApproveConfirm = true }
                        .buttonStyle(.bordered)
                        .tint(.green)
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            // hermit-2ni: stale SHA banner
            if staleSHADetected {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("PR was updated — refresh to see latest.")
                        .font(.caption)
                    Spacer()
                    Button("Refresh") { Task { await commentStore.load() } }
                        .font(.caption).buttonStyle(.bordered).controlSize(.mini)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
            }

            // Comment list
            if commentStore.isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if visibleComments.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: selectedLine != nil ? "bubble.left" : "bubble.left.and.bubble.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(selectedLine != nil ? "No comments on this line." : "No comments yet.")
                        .foregroundStyle(.secondary).font(.subheadline)
                    if selectedLine == nil {
                        Text("Tap a block in the RFC to anchor a comment.")
                            .foregroundStyle(.tertiary).font(.caption)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 32)
                .padding(.horizontal, 16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleComments) { comment in
                            CommentRow(comment: comment)
                            Divider()
                        }
                    }
                }
            }

            if let err = commentStore.errorMessage {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(8)
            }

            Spacer()
        }
        .confirmationDialog("Approve PR #\(prNumber)?",
                            isPresented: $showApproveConfirm,
                            titleVisibility: .visible) {
            Button("Approve", role: .none) { Task { await approvePR() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func approvePR() async {
        // Stub: call client.approvePR(prNumber:)
    }
}

// MARK: - Comment row

private struct CommentRow: View {
    let comment: PRReviewComment

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                // Avatar placeholder
                Circle()
                    .fill(Color.accentColor.opacity(0.2))
                    .frame(width: 28, height: 28)
                    .overlay(
                        Text(String(comment.user.prefix(1)).uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(comment.user)
                            .font(.caption)
                            .fontWeight(.semibold)
                        Spacer()
                        Text(comment.createdAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let line = comment.line {
                        Text("Line \(line)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            Text(comment.body)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 36)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}
