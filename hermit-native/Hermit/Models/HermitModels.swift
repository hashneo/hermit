import Foundation

/// The server's most recent refresh outcome, including failures returned with
/// cached documents. An HTTP success alone does not imply a successful sync.
enum RepositoryAuthState: String, Decodable {
    case healthy
    case authenticationRequired = "authentication_required"
    case accessDenied = "access_denied"
    case refreshFailed = "refresh_failed"
    case unknown

    init(fromRaw value: String) {
        self = RepositoryAuthState(rawValue: value) ?? .unknown
    }
}

struct RepositoryAuthStatus {
    let state: RepositoryAuthState
    let method: String
    let lastValidatedAt: String?
    let lastSuccessfulRefreshAt: String?
    let lastAttemptedRefreshAt: String?
    let lastErrorCode: String?
    let lastErrorMessage: String?
    let remediation: String?

    var isCredentialIssue: Bool {
        state == .authenticationRequired || state == .accessDenied
    }

    var hasRefreshFailure: Bool {
        isCredentialIssue || state == .refreshFailed
    }

    /// Keep server cache timestamps truthful. Failed refreshes must never turn
    /// a cached response into a new successful-sync timestamp.
    func successfulRefreshDate(observedAt: Date, cachedAt: Date?) -> Date? {
        if let raw = lastSuccessfulRefreshAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: raw) { return date }
        }
        return hasRefreshFailure ? cachedAt : observedAt
    }
}

// MARK: - Shared domain models used across HermitAPIClient and all views

struct RFCFile: Identifiable, Hashable {
    let id: String        // SHA of the tree entry
    let name: String
    let path: String
    let sha: String
    let htmlURL: String
    let lifecycleStatus: String?  // "draft", "accepted", "implemented", "unknown"
    let documentType: String  // docs-cms type: "rfc", "adr", "prd", "memo" (ADR-011)

    init(id: String, name: String, path: String, sha: String, htmlURL: String,
         lifecycleStatus: String?, documentType: String = "rfc") {
        self.id = id
        self.name = name
        self.path = path
        self.sha = sha
        self.htmlURL = htmlURL
        self.lifecycleStatus = lifecycleStatus
        self.documentType = documentType
    }
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

// MARK: - Shared PR document filtering (all platforms)

/// Returns the single primary `RFCPullRequest` for each PR in `prs`.
/// Filters to numbered docs-cms documents of the declared type,
/// prefers actionable (non-terminal) lifecycle status, and uses the highest
/// document number as a tiebreaker so superseded/updated files are not picked over
/// the newly proposed one.
func primaryPRDocuments(from prs: [RFCPullRequest]) -> [RFCPullRequest] {
    Dictionary(grouping: prs, by: { $0.number })
        .values
        .compactMap { group -> RFCPullRequest? in
            let rfcs = group.filter { isDocumentPath($0.documentPath, docType: $0.documentType) }
            guard !rfcs.isEmpty else { return nil }
            let actionable = rfcs.filter { !isTerminalStatus($0.lifecycleStatus) }
            return (actionable.isEmpty ? rfcs : actionable)
                .max(by: {
                    if $0.documentType != $1.documentType { return $0.documentType > $1.documentType }
                    let lhs = documentNumberFromPath($0.documentPath, docType: $0.documentType)
                    let rhs = documentNumberFromPath($1.documentPath, docType: $1.documentType)
                    return lhs == rhs ? $0.documentPath > $1.documentPath : lhs < rhs
                })
        }
        .sorted { $0.number < $1.number }
}

/// Returns true when `path` points to a genuine RFC document.
/// Matches filenames like `rfc-001-title.md` but rejects index files
/// (`rfc-index.md`), ADRs, PRDs, and any file without a numeric suffix
/// immediately following the `rfc-` prefix.
func isRFCDocumentPath(_ path: String) -> Bool {
    isDocumentPath(path, docType: "rfc")
}

/// Generic docs-cms document-path check: true when `path` is a numbered
/// `<docType>-NNN-slug.md` file (e.g. adr-003-…, prd-001-…, rfc-076-…, memo-002-…).
/// Rejects index files and files without a numeric suffix after the prefix (ADR-011).
func isDocumentPath(_ path: String, docType: String) -> Bool {
    let type = docType.lowercased()
    guard ["rfc", "adr", "prd", "memo"].contains(type),
          let filename = path.split(separator: "/").last.map(String.init) else { return false }
    return filename.range(of: "^" + type + "-[0-9]{3}-[a-z0-9]+(?:-[a-z0-9]+)*\\.md$",
                          options: .regularExpression) != nil
}

/// Extracts the RFC sequence number from a path like `docs-cms/rfcs/rfc-076-title.md` → 76.
func rfcNumberFromPath(_ path: String) -> Int {
    documentNumberFromPath(path, docType: "rfc")
}

/// Generic docs-cms sequence number from a `<docType>-NNN-…` path (ADR-011).
func documentNumberFromPath(_ path: String, docType: String) -> Int {
    guard let filename = path.split(separator: "/").last.map(String.init) else { return 0 }
    let lower = filename.lowercased()
    let prefix = docType.lowercased() + "-"
    guard lower.hasPrefix(prefix) else { return 0 }
    let digits = lower.dropFirst(prefix.count).prefix(while: { $0.isNumber })
    return Int(digits) ?? 0
}

/// Returns true for lifecycle statuses that mean the RFC is no longer actively
/// being proposed — superseded, implemented, or rejected.
func isTerminalStatus(_ status: String?) -> Bool {
    switch status?.lowercased() {
    case "superseded", "implemented", "rejected": return true
    default: return false
    }
}
