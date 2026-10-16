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
    /// docs-cms document type: "rfc", "adr", "prd", "memo". Carried end to end
    /// so stores/views can group/filter by type (ADR-011). Declared last with a
    /// default in the explicit init below so legacy call sites still compile.
    let documentType: String

    enum RFCSource { case mainBranch, pullRequest(RFCPullRequest) }

    // Explicit init (documentType defaults to "rfc") so legacy call sites that
    // omit the doc type still compile while new sites thread it through (ADR-011).
    init(id: String, title: String, path: String, sha: String, source: RFCSource,
         lifecycleStatus: String?, htmlURL: String, documentType: String = "rfc") {
        self.id = id
        self.title = title
        self.path = path
        self.sha = sha
        self.source = source
        self.lifecycleStatus = lifecycleStatus
        self.htmlURL = htmlURL
        self.documentType = documentType
    }

    static func == (lhs: RFC, rhs: RFC) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}
