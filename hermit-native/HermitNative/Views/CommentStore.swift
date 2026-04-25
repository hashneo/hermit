import Foundation
import SwiftUI

// MARK: - CommentStore
// Owns all PR review comments for the currently-viewed RFC.
// Shared via EnvironmentObject between RFCDetailView, GutterMarkdownView and ThreadPanelView.

@MainActor
final class CommentStore: ObservableObject {
    @Published private(set) var comments: [PRReviewComment] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String? = nil

    // Context set when a PR RFC is selected
    private(set) var prNumber: Int?
    private(set) var commitSHA: String?
    private(set) var filePath: String?

    private var client: GitHubAPIClient?

    func configure(client: GitHubAPIClient, prNumber: Int, commitSHA: String, filePath: String) {
        self.client      = client
        self.prNumber    = prNumber
        self.commitSHA   = commitSHA
        self.filePath    = filePath
        comments         = []
        errorMessage     = nil
    }

    func reset() {
        client     = nil
        prNumber   = nil
        commitSHA  = nil
        filePath   = nil
        comments   = []
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

    /// Returns the number of comments anchored to a given source line.
    func count(for line: Int) -> Int {
        comments.filter { $0.line == line }.count
    }

    /// All comments for a given source line, oldest first.
    func comments(for line: Int) -> [PRReviewComment] {
        comments.filter { $0.line == line }.sorted { $0.createdAt < $1.createdAt }
    }

    /// Post a new top-level comment anchored to a line and refresh.
    func postComment(body: String, line: Int) async throws {
        guard let client, let prNumber, let commitSHA, let filePath else {
            throw CommentStoreError.notConfigured
        }
        let new = try await client.createReviewComment(
            prNumber: prNumber,
            body: body,
            commitSHA: commitSHA,
            path: filePath,
            line: line
        )
        comments.append(new)
        // Sort so newly added appears in order
        comments.sort { $0.createdAt < $1.createdAt }
    }
}

enum CommentStoreError: LocalizedError {
    case notConfigured
    var errorDescription: String? { "Comment store not configured — no PR context available." }
}
