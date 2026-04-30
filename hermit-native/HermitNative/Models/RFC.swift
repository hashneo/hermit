import Foundation

// MARK: - RFC domain models (shared across sessions and views)

struct RFC: Identifiable, Hashable {
    let id: String           // SHA
    let title: String
    let path: String
    let sha: String
    let source: RFCSource
    /// Normalised lifecycle status from frontmatter: "draft", "accepted",
    /// "implemented", "superseded", "rejected", "unknown", or nil for PR RFCs.
    let lifecycleStatus: String?
    /// hermit-ixk: full GitHub/Gitea web URL for sharing (e.g.
    /// https://github.com/owner/repo/blob/main/docs-cms/rfcs/rfc-001.md).
    /// Empty string when the server did not return html_url (older builds).
    let htmlURL: String

    enum RFCSource { case mainBranch, pullRequest(RFCPullRequest) }

    /// The web URL for this RFC on GitHub/Gitea.
    /// For main-branch RFCs this is sourced from RFCFile.htmlURL.
    /// For PR RFCs this is sourced from RFCPullRequest.htmlURL.
    /// Empty string when not available.
    let htmlURL: String

    static func == (lhs: RFC, rhs: RFC) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
