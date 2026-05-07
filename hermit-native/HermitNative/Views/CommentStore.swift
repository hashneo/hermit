import Foundation
import SwiftUI

// MARK: - CommentStore
// Owns all PR review threads for the currently-viewed RFC.
// Shared via EnvironmentObject between RFCDetailView, GutterMarkdownView and ThreadPanelView.

@MainActor
final class CommentStore: ObservableObject {
    @Published private(set) var comments: [ReviewThread] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil
    /// The GitHub login of the authenticated user. Populated on first load.
    @Published private(set) var currentUserLogin: String = ""

    // Context set when a PR RFC is selected
    private(set) var prNumber: Int?
    private(set) var filePath: String?

    private var client: (any HermitClientProtocol)?

    func configure(client: any HermitClientProtocol, prNumber: Int, filePath: String) {
        self.client   = client
        self.prNumber = prNumber
        self.filePath = filePath
        comments      = []
        errorMessage  = nil
        currentUserLogin = ""
        // Fetch the current user's login eagerly so the delete button is ready
        // before the first popover opens.
        Task {
            if let login = try? await client.fetchCurrentUser(), !login.isEmpty {
                self.currentUserLogin = login
            }
        }
    }

    // Legacy overload kept for call sites that still pass commitSHA.
    func configure(client: any HermitClientProtocol, prNumber: Int, commitSHA: String, filePath: String) {
        configure(client: client, prNumber: prNumber, filePath: filePath)
    }

    func reset() {
        client    = nil
        prNumber  = nil
        filePath  = nil
        comments  = []
        errorMessage = nil
        currentUserLogin = ""
    }

    func load() async {
        guard let client, let prNumber else { return }
        isLoading = true
        errorMessage = nil
        do {
            comments = try await client.listReviewComments(prNumber: prNumber)
        } catch {
            errorMessage = error.localizedDescription
        }
        // Fetch current user identity if not yet known (best-effort; failures are silent).
        if currentUserLogin.isEmpty {
            if let login = try? await client.fetchCurrentUser(), !login.isEmpty {
                currentUserLogin = login
            }
        }
        isLoading = false
    }

    /// Returns the number of threads that overlap the given block line range [blockStart, blockEnd].
    /// A thread overlaps when its anchor intersects the block: thread.lineStart <= blockEnd && thread.lineEnd >= blockStart.
    func count(for line: Int, lineEnd: Int? = nil) -> Int {
        let end = lineEnd ?? line
        return comments.filter { $0.lineStart <= end && $0.lineEnd >= line }.count
    }

    /// All threads overlapping the given block line range, oldest first.
    func comments(for line: Int, lineEnd: Int? = nil) -> [ReviewThread] {
        let end = lineEnd ?? line
        return comments
            .filter { $0.lineStart <= end && $0.lineEnd >= line }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Post a new thread anchored to a block line range and refresh.
    /// `lineEnd` is the last raw file line of the block (e.g. closing fence of a code block).
    /// `lineText` is the raw markdown text of the block's opening line, used to compute the fingerprint.
    func postComment(body: String, line: Int, lineEnd: Int? = nil, lineText: String = "") async throws {
        guard let client, let prNumber, let filePath else {
            throw CommentStoreError.notConfigured
        }
        let end = lineEnd ?? line
        let fingerprint = Self.makeFingerprint(lineText)
        _ = try await client.createReviewComment(
            prNumber: prNumber,
            body: body,
            filePath: filePath,
            lineStart: line,
            lineEnd: end,
            textFingerprint: fingerprint
        )
        await load()
    }

    /// Slugify up to 40 chars of text — mirrors the Go `fingerprint()` function.
    private static func makeFingerprint(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let truncated = trimmed.count > 40 ? String(trimmed.prefix(40)) : trimmed
        let slug = truncated.lowercased().replacingOccurrences(of: " ", with: "-")
        return slug.isEmpty ? "line" : slug
    }
    /// Resolve a thread on GitHub and refresh.
    func resolveThread(threadId: String) async throws {
        guard let client, let prNumber else {
            throw CommentStoreError.notConfigured
        }
        try await client.resolveReviewThread(prNumber: prNumber, threadId: threadId)
        // Optimistically mark resolved in local state; reload will sync.
        comments = comments.map { t in
            guard t.id == threadId else { return t }
            return ReviewThread(
                id: t.id, prNumber: t.prNumber, status: "resolved",
                filePath: t.filePath, lineStart: t.lineStart, lineEnd: t.lineEnd,
                messages: t.messages
            )
        }
        await load()
    }

    /// Reply to an existing thread and refresh the local thread.
    func replyToThread(threadId: String, body: String) async throws {
        guard let client, let prNumber else {
            throw CommentStoreError.notConfigured
        }
        _ = try await client.replyToReviewComment(prNumber: prNumber, threadId: threadId, body: body)
        await load()
    }

    /// Delete the root comment of a thread (only allowed for comments by the current user
    /// on open, unresolved threads — enforced in the UI, not re-checked here).
    func deleteComment(threadId: String) async throws {
        guard let client, let prNumber else {
            throw CommentStoreError.notConfigured
        }
        try await client.deleteReviewComment(prNumber: prNumber, threadId: threadId)
        // Optimistically remove from local state; reload will sync any discrepancy.
        comments.removeAll { $0.id == threadId }
        await load()
    }
}

enum CommentStoreError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "Comment store not configured — no PR context available." }
}
