import Foundation

// MARK: - RFC domain models (shared across sessions and views)

struct RFC: Identifiable, Hashable {
    let id: String           // SHA
    let title: String
    let path: String
    let sha: String
    let source: RFCSource

    enum RFCSource { case mainBranch, pullRequest(RFCPullRequest) }

    static func == (lhs: RFC, rhs: RFC) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
