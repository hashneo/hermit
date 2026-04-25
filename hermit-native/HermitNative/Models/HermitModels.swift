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

struct PRReviewComment: Identifiable, Hashable {
    let id: Int
    let body: String
    let path: String
    let line: Int?
    let inReplyToId: Int?
    let user: String
    let createdAt: Date
    let resolved: Bool
}

struct ReviewState: Equatable {
    let approved: Bool
    let reviewers: [String]
}
