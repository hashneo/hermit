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
        isLoading = false
    }

    /// Returns the number of threads anchored to a given source line.
    func count(for line: Int) -> Int {
        comments.filter { $0.lineStart <= line && $0.lineEnd >= line }.count
    }

    /// All threads for a given source line, oldest first.
    func comments(for line: Int) -> [ReviewThread] {
        comments
            .filter { $0.lineStart <= line && $0.lineEnd >= line }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Post a new thread anchored to a line and refresh.
    /// `lineText` is the raw markdown text of that line, used to compute the fingerprint.
    func postComment(body: String, line: Int, lineText: String = "") async throws {
        guard let client, let prNumber, let filePath else {
            throw CommentStoreError.notConfigured
        }
        let fingerprint = Self.makeFingerprint(lineText)
        let new = try await client.createReviewComment(
            prNumber: prNumber,
            body: body,
            filePath: filePath,
            lineStart: line,
            lineEnd: line,
            textFingerprint: fingerprint
        )
        comments.append(new)
        comments.sort { $0.createdAt < $1.createdAt }
    }

    /// Slugify up to 40 chars of text — mirrors the Go `fingerprint()` function.
    private static func makeFingerprint(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let truncated = trimmed.count > 40 ? String(trimmed.prefix(40)) : trimmed
        let slug = truncated.lowercased().replacingOccurrences(of: " ", with: "-")
        return slug.isEmpty ? "line" : slug
    }
    /// Reply to an existing thread and refresh the local thread.
    func replyToThread(threadId: String, body: String) async throws {
        guard let client, let prNumber else {
            throw CommentStoreError.notConfigured
        }
        let updated = try await client.replyToReviewComment(prNumber: prNumber, threadId: threadId, body: body)
        if let idx = comments.firstIndex(where: { $0.id == threadId }) {
            comments[idx] = updated
        } else {
            comments.append(updated)
        }
    }
}

enum CommentStoreError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "Comment store not configured — no PR context available." }
}
