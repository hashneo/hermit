import Foundation

// Run with the production domain models, without app startup or saved accounts:
// swiftc hermit-native/Hermit/Models/HermitModels.swift hermit-native/tests/model_tests.swift -o /tmp/hermit-model-tests
@main
struct ModelTests {
    static func document(_ type: String, number: Int, pr: Int, status: String = "draft") -> RFCPullRequest {
        let path = "docs-cms/\(type)/\(type)-\(String(format: "%03d", number))-example.md"
        return RFCPullRequest(
            id: pr, number: pr, title: "Example", prTitle: "PR", prState: "open", prMerged: false,
            body: "", headSHA: "sha", headRef: "branch", htmlURL: "", state: "open", draft: false,
            mergeable: true, mergeableState: "clean", documentType: type, documentPath: path,
            lifecycleStatus: status, catalogID: path, labels: [], changedFiles: 1,
            additions: 1, deletions: 0, issueCommentCount: 0, reviewCommentCount: 0
        )
    }

    static func main() {
        let candidates = [
            document("rfc", number: 1, pr: 1),
            document("rfc", number: 2, pr: 1, status: "superseded"),
            document("adr", number: 3, pr: 2),
            document("prd", number: 4, pr: 3),
            document("memo", number: 5, pr: 4),
        ]
        let selected = primaryPRDocuments(from: candidates)
        precondition(selected.map(\.documentType) == ["rfc", "adr", "prd", "memo"])
        precondition(selected[0].documentPath.contains("rfc-001-"), "Prefer actionable documents")
        precondition(primaryPRDocuments(from: candidates.reversed()).map(\.catalogID) == selected.map(\.catalogID))
        precondition(!isDocumentPath("adr-003-example.md", docType: "rfc"))
        precondition(!isDocumentPath("rfc-1oops.md", docType: "rfc"))
        precondition(!isDocumentPath("rfc-index.md", docType: "rfc"))
        precondition(documentNumberFromPath("docs/adr-012-example.md", docType: "adr") == 12)

        print("Native document model tests passed")
    }
}
