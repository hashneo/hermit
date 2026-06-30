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
    /// When true, resolved and outdated threads are hidden from gutter badges and the thread panel.
    /// Users can toggle this off to see historical/resolved comments.
    @Published var hideNoise: Bool = true

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
            let all = try await client.listReviewComments(prNumber: prNumber)
            // Only show threads that belong to this RFC's file. If filePath is
            // not set (shouldn't happen in practice) fall back to showing all.
            if let fp = filePath, !fp.isEmpty {
                comments = all.filter { $0.filePath == fp }
            } else {
                comments = all
            }
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

    /// Sorted list of line numbers that have at least one thread (resolved or not).
    /// Uses effectiveLine(for:blockRanges:) so orphaned threads are counted on their nearest block.
    func commentedLines(blockRanges: [(start: Int, end: Int)]) -> [Int] {
        let lines = Set(visibleComments.map { effectiveLine(for: $0, blockRanges: blockRanges) })
        return lines.sorted()
    }

    /// Returns the number of threads that overlap or are snapped to the given block line range.
    func count(for line: Int, lineEnd: Int? = nil, blockRanges: [(start: Int, end: Int)] = []) -> Int {
        comments(for: line, lineEnd: lineEnd, blockRanges: blockRanges).count
    }

    /// All threads that belong to the given block, oldest first.
    /// A thread "belongs" to the block whose start line equals effectiveLine(thread).
    /// This guarantees each thread appears on exactly one gutter badge regardless
    /// of how wide the block's line range is.
    func comments(for line: Int, lineEnd: Int? = nil, blockRanges: [(start: Int, end: Int)] = []) -> [ReviewThread] {
        guard !blockRanges.isEmpty else {
            // No block layout info — fall back to simple line overlap.
            let end = lineEnd ?? line
            return visibleComments
                .filter { !$0.outdated && $0.lineStart <= end && $0.lineEnd >= line }
                .sorted { $0.createdAt < $1.createdAt }
        }
        return visibleComments
            .filter { effectiveLine(for: $0, blockRanges: blockRanges) == line }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// The subset of comments shown based on the current hideNoise setting.
    var visibleComments: [ReviewThread] {
        guard hideNoise else { return comments }
        return comments.filter { !$0.resolved && !$0.outdated }
    }

    /// Given a thread, returns the block start line it should be displayed on.
    /// Outdated threads always snap — their lineStart is from the old diff and
    /// should never be matched by normal line-range overlap.
    /// Non-outdated threads use normal overlap first, then snap if unmatched.
    func effectiveLine(for thread: ReviewThread, blockRanges: [(start: Int, end: Int)], fallbackRange: (Int, Int)? = nil) -> Int {
        // Only attempt normal overlap for threads that are not outdated.
        if !thread.outdated {
            for r in blockRanges {
                if thread.lineStart <= r.end && thread.lineEnd >= r.start {
                    return r.start
                }
            }
        }
        // Outdated threads, or non-outdated threads that missed every block:
        // snap to the nearest block by minimum distance.
        guard !blockRanges.isEmpty else { return thread.lineStart }
        return blockRanges.min(by: {
            min(abs($0.start - thread.lineStart), abs($0.end - thread.lineStart)) <
            min(abs($1.start - thread.lineStart), abs($1.end - thread.lineStart))
        })!.start
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
        do {
            _ = try await client.createReviewComment(
                prNumber: prNumber,
                body: body,
                filePath: filePath,
                lineStart: line,
                lineEnd: end,
                textFingerprint: fingerprint
            )
        } catch {
            guard error.isHermitLineResolutionFailure else { throw error }
            let result = try await client.startReviewSession(
                filePath: filePath,
                previousPRNumber: prNumber
            )
            throw ReviewSessionRedirectError(result: result)
        }
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
                outdated: t.outdated,
                filePath: t.filePath, lineStart: t.lineStart, lineEnd: t.lineEnd,
                messages: t.messages
            )
        }
        await load()
    }

    func unresolveThread(threadId: String) async throws {
        guard let client, let prNumber else {
            throw CommentStoreError.notConfigured
        }
        try await client.unresolveReviewThread(prNumber: prNumber, threadId: threadId)
        // Optimistically mark open in local state; reload will sync.
        comments = comments.map { t in
            guard t.id == threadId else { return t }
            return ReviewThread(
                id: t.id, prNumber: t.prNumber, status: "open",
                outdated: t.outdated,
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
