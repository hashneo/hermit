import Foundation

// MARK: - Shared domain models used across HermitAPIClient and all views

struct RFCFile: Identifiable, Hashable {
    let id: String        // SHA of the tree entry
    let name: String
    let path: String
    let sha: String
    let htmlURL: String
}

struct RFCPullRequest: Identifiable {
    let id: Int
    let number: Int
    let title: String
    let body: String
    let headSHA: String
    let headRef: String
    let htmlURL: String
    let state: String
    let draft: Bool
    let labels: [String]
}

struct ThreadMessage: Identifiable, Hashable {
    let id: String
    let author: String
    let body: String
    let createdAt: Date
}

struct ReviewThread: Identifiable, Hashable {
    let id: String
    let prNumber: Int
    let status: String       // "open", "resolved"
    let filePath: String
    let lineStart: Int
    let lineEnd: Int
    let messages: [ThreadMessage]

    /// Convenience: first message body (the top-level comment).
    var body: String { messages.first?.body ?? "" }
    /// Convenience: author of the first message.
    var user: String { messages.first?.author ?? "" }
    /// Convenience: creation date of the first message.
    var createdAt: Date { messages.first?.createdAt ?? Date() }
    /// The source line this thread is anchored to (line_start).
    var line: Int { lineStart }
    var resolved: Bool { status == "resolved" }
}

// Legacy alias kept temporarily so callers can migrate incrementally.
typealias PRReviewComment = ReviewThread

struct ReviewState: Equatable {
    let approved: Bool
    let reviewers: [String]
}
