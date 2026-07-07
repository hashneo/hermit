import Foundation

// MARK: - Shared domain models used across HermitAPIClient and all views

struct RFCFile: Identifiable, Hashable {
    let id: String        // SHA of the tree entry
    let name: String
    let path: String
    let sha: String
    let htmlURL: String
    let lifecycleStatus: String?  // "draft", "accepted", "implemented", "unknown"
}

struct RFCPullRequest: Identifiable {
    let id: Int
    let number: Int
    let title: String
    let prTitle: String
    let prState: String
    let prMerged: Bool
    let body: String
    let headSHA: String
    let headRef: String
    let htmlURL: String
    let state: String
    let draft: Bool
    let mergeable: Bool?
    let mergeableState: String?
    let documentType: String
    let documentPath: String
    let lifecycleStatus: String?
    let catalogID: String
    let labels: [String]
    let changedFiles: Int
    let additions: Int
    let deletions: Int
    let issueCommentCount: Int
    let reviewCommentCount: Int
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
    let outdated: Bool
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

    /// The first blockquoted line from the first message body, if any.
    /// Hermit embeds the anchored text as a GitHub-style blockquote ("> text")
    /// when posting via Quote & Comment. Returns nil if no quote is present.
    var quotedAnchorText: String? {
        let firstLine = body.components(separatedBy: "\n").first(where: { !$0.isEmpty }) ?? ""
        guard firstLine.hasPrefix("> ") else { return nil }
        return String(firstLine.dropFirst(2))
    }
}

// Legacy alias kept temporarily so callers can migrate incrementally.
typealias PRReviewComment = ReviewThread

struct ReviewState: Equatable {
    let approved: Bool
    let reviewers: [String]
}

/// A formal GitHub PR review (APPROVED, CHANGES_REQUESTED, COMMENTED, DISMISSED).
struct PRReview: Decodable, Identifiable {
    let id: Int64
    let state: String          // "APPROVED" | "CHANGES_REQUESTED" | "COMMENTED" | "DISMISSED"
    let body: String
    let user: String
    let submittedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case state
        case body
        case user          = "user"
        case submittedAt   = "submitted_at"
    }

    var isChangesRequested: Bool { state == "CHANGES_REQUESTED" || state == "REQUEST_CHANGES" }
    var isApproved: Bool { state == "APPROVED" }
    var isDismissed: Bool { state == "DISMISSED" }
}

struct SubmitForReviewResult: Decodable {
    let prNumber: Int
    let htmlURL: String
    let branch: String

    enum CodingKeys: String, CodingKey {
        case prNumber = "pr_number"
        case htmlURL  = "html_url"
        case branch
    }
}

struct ReviewSessionResult: Decodable, Equatable {
    let prNumber: Int
    let htmlURL: String
    let branch: String
    let filePath: String
    let markerPath: String
    let documentType: String
    let previousPRNumber: Int?

    enum CodingKeys: String, CodingKey {
        case prNumber = "pr_number"
        case htmlURL = "html_url"
        case branch
        case filePath = "file_path"
        case markerPath = "marker_path"
        case documentType = "document_type"
        case previousPRNumber = "previous_pr_number"
    }
}

struct ReviewSessionRedirectError: LocalizedError {
    let result: ReviewSessionResult

    var errorDescription: String? {
        "Opened review-session PR #\(result.prNumber) for this merged PR."
    }
}

struct AcceptRFCResult: Decodable {
    let merged: Bool
    let blockedByCI: Bool
    let commitSHA: String

    enum CodingKeys: String, CodingKey {
        case merged      = "merged"
        case blockedByCI = "blocked_by_ci"
        case commitSHA   = "commit_sha"
    }

    init(merged: Bool, blockedByCI: Bool, commitSHA: String) {
        self.merged = merged
        self.blockedByCI = blockedByCI
        self.commitSHA = commitSHA
    }
}

struct MergePRResult: Decodable {
    let merged: Bool
    let blockedByCI: Bool
    let commitSHA: String?

    enum CodingKeys: String, CodingKey {
        case merged      = "merged"
        case blockedByCI = "blocked_by_ci"
        case commitSHA   = "commit_sha"
    }

    init(merged: Bool, blockedByCI: Bool, commitSHA: String? = nil) {
        self.merged = merged
        self.blockedByCI = blockedByCI
        self.commitSHA = commitSHA
    }
}

struct LifecycleTransitionResult: Decodable {
    let rfcID: String
    let newStatus: String
    let commitSHA: String

    enum CodingKeys: String, CodingKey {
        case rfcID     = "rfc_id"
        case newStatus = "new_status"
        case commitSHA = "commit_sha"
    }
}
