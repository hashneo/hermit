import SwiftUI

// MARK: - hermit-lem: ThreadPanelView — PR comment thread list with reply and resolve
// hermit-3lm: ComposeCommentView — comment compose sheet with text and voice toggle
// hermit-2ni: Stale SHA detection and refresh prompt
// hermit-3ey: PR approval button and confirmation flow

struct ThreadPanelView: View {
    let prNumber: Int
    let selectedText: String
    /// The 1-based raw markdown source line the user tapped, if any.
    var selectedLine: Int? = nil

    @State private var comments: [PRReviewComment] = []
    @State private var isLoading = false
    @State private var showCompose = false
    @State private var showApproveConfirm = false
    @State private var reviewState: ReviewState? = nil
    @State private var staleSHADetected = false  // hermit-2ni

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("PR #\(prNumber)")
                    .font(.headline)
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
                    Button("Refresh") { Task { await load() } }
                        .font(.caption).buttonStyle(.bordered).controlSize(.mini)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1))
            }

            // Selected text context
            if !selectedText.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if let line = selectedLine {
                        Text("Line \(line)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Text("\"\(selectedText.prefix(80))\"")
                        .font(.caption).italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12).padding(.top, 6)
            }

            // Comment list
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).padding()
            } else if comments.isEmpty {
                Text("No comments yet.")
                    .foregroundStyle(.secondary).font(.subheadline)
                    .frame(maxWidth: .infinity).padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(comments) { comment in
                            CommentRow(comment: comment)
                            Divider()
                        }
                    }
                }
            }

            Spacer()
            Divider()

            Button {
                showCompose = true
            } label: {
                Label("Add Comment", systemImage: "bubble.left.and.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(12)
        }
        .sheet(isPresented: $showCompose) {
            ComposeCommentView(
                selectedText: selectedText,
                selectedLine: selectedLine,
                onSubmit: { _ in showCompose = false }
            )
        }
        .confirmationDialog("Approve PR #\(prNumber)?",
                            isPresented: $showApproveConfirm,
                            titleVisibility: .visible) {
            Button("Approve", role: .none) { Task { await approvePR() } }
            Button("Cancel", role: .cancel) {}
        }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        // Stub: full wiring via injected client
        isLoading = false
    }

    private func approvePR() async {
        // Stub: call client.approvePR(prNumber:)
    }
}

// MARK: - Comment row

private struct CommentRow: View {
    let comment: PRReviewComment
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(comment.user).font(.caption).bold()
                Spacer()
                Text(comment.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
            }
            if let line = comment.line {
                Text("Line \(line)").font(.caption2).foregroundStyle(.secondary)
            }
            Text(comment.body).font(.subheadline)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}

// MARK: - hermit-3lm: ComposeCommentView

struct ComposeCommentView: View {
    let selectedText: String
    var selectedLine: Int? = nil
    var onSubmit: ((String) -> Void)? = nil

    @State private var commentText = ""
    @State private var useVoice = false
    @StateObject private var voiceEngine = VoiceEngine()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if !selectedText.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        if let line = selectedLine {
                            Text("Line \(line)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text("Commenting on: \"\(selectedText.prefix(80))\"")
                            .font(.caption).italic().foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Voice / text toggle
                Picker("Input mode", selection: $useVoice) {
                    Label("Text", systemImage: "keyboard").tag(false)
                    Label("Voice", systemImage: "mic").tag(true)
                }
                .pickerStyle(.segmented)

                if useVoice {
                    VoiceInputPanel(
                        voiceEngine: voiceEngine,
                        onTranscription: { text in
                            commentText += (commentText.isEmpty ? "" : " ") + text
                        }
                    )
                } else {
                    TextEditor(text: $commentText)
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                }

                Spacer()
            }
            .padding()
            .navigationTitle("Add Comment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Submit") {
                        onSubmit?(commentText)
                        dismiss()
                    }
                    .disabled(commentText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}

// MARK: - Inline voice input panel (used by ComposeCommentView)

private struct VoiceInputPanel: View {
    @ObservedObject var voiceEngine: VoiceEngine
    var onTranscription: (String) -> Void

    var body: some View {
        VStack(spacing: 12) {
            WaveformView(amplitude: voiceEngine.amplitude)
            HStack {
                if voiceEngine.state == .recording {
                    Button("Stop") { voiceEngine.stopRecording() }
                        .buttonStyle(.borderedProminent).tint(.red)
                } else {
                    Button("Record") { Task { try? await voiceEngine.startRecording() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
