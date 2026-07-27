import Foundation

// MARK: - App Review / demo client

/// An in-memory HermitClientProtocol implementation that serves bundled sample
/// RFC documents.  Lets App Review testers and first-time users explore the app
/// without needing a real Hermit server.
///
/// Activated by tapping "Try Demo" on the pairing/setup screen.
/// All read paths work; write paths throw DemoError.readOnly with a clear message.
actor DemoHermitClient: HermitClientProtocol {

    static let shared = DemoHermitClient()
    private init() {}

    // MARK: - Sample catalog

    private static let rfcFiles: [RFCFile] = [
        RFCFile(
            id: "demo-rfc-001",
            name: "RFC-001: API Design Principles",
            path: "docs/rfc-001-api-design.md",
            sha: "demo001sha",
            htmlURL: "",
            lifecycleStatus: "accepted"
        ),
        RFCFile(
            id: "demo-rfc-002",
            name: "RFC-002: Offline Mode",
            path: "docs/rfc-002-offline-mode.md",
            sha: "demo002sha",
            htmlURL: "",
            lifecycleStatus: "draft"
        ),
    ]

    private static let prRFC = RFCPullRequest(
        id: 1,
        number: 1,
        title: "RFC-003: Real-time Collaboration",
        prTitle: "RFC-003: Real-time Collaboration",
        prState: "open",
        prMerged: false,
        body: "Proposes a real-time collaboration layer for concurrent RFC editing.",
        headSHA: "demo003sha",
        headRef: "feat/rfc-003-realtime",
        htmlURL: "",
        state: "in_review",
        draft: false,
        mergeable: true,
        mergeableState: "clean",
        documentType: "rfc",
        documentPath: "docs/rfc-003-realtime.md",
        lifecycleStatus: "in_review",
        catalogID: "demo-rfc-003",
        labels: ["rfc"],
        changedFiles: 1,
        additions: 72,
        deletions: 0,
        issueCommentCount: 1,
        reviewCommentCount: 2
    )

    // MARK: - RFC discovery

    func discoverRFCs() async throws -> (mainBranch: [RFCFile], pullRequests: [RFCPullRequest], summary: RepositoryRFCSummary) {
        (
            mainBranch: Self.rfcFiles,
            pullRequests: [Self.prRFC],
            summary: RepositoryRFCSummary(
                pendingReviewCount: 1,
                openPRCount: 1,
                prStateCounts: PRStateCounts()
            )
        )
    }

    func listMainBranchRFCs() async throws -> [RFCFile] { Self.rfcFiles }

    // MARK: - Content fetching

    func fetchRFCContent(path: String, ref: String) async throws -> String {
        switch path {
        case "docs/rfc-001-api-design.md":   return Self.rfc001
        case "docs/rfc-002-offline-mode.md": return Self.rfc002
        case "docs/rfc-003-realtime.md":     return Self.rfc003
        default: throw DemoError.notFound(path)
        }
    }

    func fetchPRRFCContent(prNumber: Int) async throws -> String { Self.rfc003 }
    func fetchPRRFCContent(prNumber: Int, filePath: String) async throws -> String {
        try await fetchRFCContent(path: filePath, ref: "main")
    }

    func fetchPRAuthorLogin(prNumber: Int) async throws -> String { "demo-author" }
    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String] { [] }
    func listPRChangedFiles(prNumber: Int, docsPath: String) async throws -> [String] {
        ["docs/rfc-003-realtime.md"]
    }

    // MARK: - Review threads (read-only stubs)

    func listReviewComments(prNumber: Int) async throws -> [ReviewThread] { [] }

    func createReviewComment(prNumber: Int, body: String, filePath: String,
                             lineStart: Int, lineEnd: Int,
                             textFingerprint: String) async throws -> ReviewThread {
        throw DemoError.readOnly
    }
    func replyToReviewComment(prNumber: Int, threadId: String, body: String) async throws -> ReviewThread {
        throw DemoError.readOnly
    }
    func deleteReviewComment(prNumber: Int, threadId: String) async throws { throw DemoError.readOnly }
    func resolveReviewThread(prNumber: Int, threadId: String) async throws   { throw DemoError.readOnly }
    func unresolveReviewThread(prNumber: Int, threadId: String) async throws { throw DemoError.readOnly }

    func getReviewState(prNumber: Int) async throws -> ReviewState {
        ReviewState(approved: false, reviewers: [])
    }

    func approve(prNumber: Int) async throws { throw DemoError.readOnly }

    // MARK: - Merge / branch

    func getMergeStatus(prNumber: Int) async throws -> Bool { false }
    func updateBranch(prNumber: Int) async throws { throw DemoError.readOnly }

    // MARK: - User

    func fetchCurrentUser() async throws -> String { "reviewer" }
    func getCallerPermission() async throws -> String { "read" }

    // MARK: - Publishing (all read-only in demo)

    func getMainBranchSHA() async throws -> String { throw DemoError.readOnly }
    func createBranch(name: String, fromSHA: String) async throws { throw DemoError.readOnly }
    func commitFile(branch: String, path: String, content: String,
                    message: String) async throws -> String { throw DemoError.readOnly }
    func createPR(title: String, body: String,
                  headBranch: String, label: String) async throws -> RFCPullRequest { throw DemoError.readOnly }
    func submitForReview(rfcID: String) async throws -> SubmitForReviewResult { throw DemoError.readOnly }
    func startReviewSession(filePath: String, previousPRNumber: Int) async throws -> ReviewSessionResult { throw DemoError.readOnly }
    func acceptRFC(prNumber: Int, filePath: String) async throws -> AcceptRFCResult { throw DemoError.readOnly }
    func mergePR(prNumber: Int) async throws -> MergePRResult { throw DemoError.readOnly }
    func getCIStatus(commitSHA: String) async throws -> String { "success" }
    func requestChanges(prNumber: Int, body: String) async throws { throw DemoError.readOnly }
    func listPRReviews(prNumber: Int) async throws -> [PRReview] { [] }
    func dismissReview(prNumber: Int, reviewID: Int64, message: String) async throws { throw DemoError.readOnly }
    func approveRFC(rfcID: String) async throws -> LifecycleTransitionResult { throw DemoError.readOnly }
    func markRFCImplemented(rfcID: String) async throws -> LifecycleTransitionResult { throw DemoError.readOnly }
}

// MARK: - Error

enum DemoError: LocalizedError {
    case readOnly
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .readOnly:       return "This action isn't available in demo mode."
        case .notFound(let p): return "Demo document not found: \(p)"
        }
    }
}

// MARK: - Sample RFC content

private extension DemoHermitClient {

    static let rfc001 = """
    ---
    id: rfc-001
    title: "API Design Principles"
    status: accepted
    author: alice
    date: 2024-01-15
    ---

    # RFC-001: API Design Principles

    ## Status

    **Accepted** — 2024-02-01

    ## Summary

    This RFC establishes the API design principles that all Hermit services must follow.
    Consistent API design reduces cognitive load for consumers and enables shared tooling.

    ## Background

    Prior to this RFC, each service team made independent decisions about URL structure,
    versioning, error formats, and authentication. This led to inconsistent developer
    experience across the platform.

    ## Proposal

    All REST APIs exposed by Hermit services MUST:

    1. **Version via URL prefix** — use `/v1/`, `/v2/`, etc.
    2. **Return JSON** — `Content-Type: application/json` for all non-binary responses.
    3. **Use standard HTTP status codes** — 200, 201, 400, 401, 403, 404, 409, 422, 500.
    4. **Include a stable error envelope** when returning non-2xx:
       ```json
       { "error": "human-readable message", "code": "MACHINE_CODE" }
       ```
    5. **Authenticate via Bearer token** — `Authorization: Bearer <token>`.

    ### URL Structure

    ```
    /<version>/<resource>/<id>/<sub-resource>
    ```

    Examples:
    - `GET /v1/repos`
    - `GET /v1/repos/42/rfcs`
    - `POST /v1/repos/42/rfcs`

    ## Consequences

    - Existing endpoints that deviate from these rules must be updated by Q2 2024.
    - A linter will be added to CI to enforce compliance on new endpoints.
    - The shared Go middleware package will be extended with standard error helpers.

    ## Alternatives Considered

    **GraphQL**: Rejected — too heavy for our current team size and use cases.

    **gRPC**: Rejected — browser clients need REST; translation layers add complexity.
    """

    static let rfc002 = """
    ---
    id: rfc-002
    title: "Offline Mode"
    status: draft
    author: bob
    date: 2024-03-10
    ---

    # RFC-002: Offline Mode

    ## Status

    **Draft** — open for discussion

    ## Summary

    Add an offline-capable mode so engineers can browse and annotate RFCs without
    a live connection to the Hermit server.

    ## Background

    Hermit is currently fully online-dependent. Engineers on flights, at conferences
    with poor Wi-Fi, or on mobile data cannot read or annotate RFCs.

    Usage analytics show that 23% of RFC views happen outside the office network.

    ## Proposal

    ### Caching layer

    Introduce a local SQLite store that mirrors:
    - RFC document content (markdown text)
    - Review thread payloads
    - PR metadata (title, state, author, labels)

    Cache entries are written on first fetch and refreshed on foreground.
    TTL: 24 hours for content, 5 minutes for thread state.

    ### Conflict resolution

    Annotations made offline are queued as pending writes. On reconnect:
    1. Re-fetch the current server state.
    2. If no server-side change occurred on the same lines, apply the pending writes.
    3. If a conflict is detected, surface a merge UI — never silently drop writes.

    ### UI indicators

    - An "Offline" banner replaces the repo selector when no server is reachable.
    - Stale cache entries show a "Last synced N hours ago" caption.
    - Pending writes show a queue badge in the toolbar.

    ## Open Questions

    - Maximum cache size? Suggest 50 MB with LRU eviction.
    - Should the cache persist across app reinstalls?
    - Is conflict resolution feasible in v1, or should offline writes be read-only?

    ## Next Steps

    1. Spike: measure SQLite read/write performance for typical RFC payload sizes.
    2. Decide on conflict strategy (see Open Questions).
    3. Revise with results before moving to In Review.
    """

    static let rfc003 = """
    ---
    id: rfc-003
    title: "Real-time Collaboration"
    status: in_review
    author: carol
    pr: 1
    date: 2024-04-02
    ---

    # RFC-003: Real-time Collaboration

    ## Status

    **In Review** — PR #1 open

    ## Summary

    Enable multiple engineers to view and annotate the same RFC simultaneously,
    with live cursor presence and conflict-free comment threads.

    ## Background

    RFC review sessions are currently asynchronous: reviewers annotate independently
    and discover each other's comments only on refresh. This causes:
    - Duplicated comments on the same passage
    - Missed context from simultaneous discussions
    - Slower consensus on contentious proposals

    ## Proposal

    ### Presence layer

    A lightweight WebSocket endpoint on the Hermit server:

    ```
    wss://<host>/v1/repos/<id>/rfcs/<path>/presence
    ```

    Each connected client broadcasts:
    - Authenticated user identity (from existing Bearer token)
    - Current cursor line (throttled to 1 update/second)

    ### Conflict-free threads

    All comment creates and resolves flow through an append-only operations log.
    Each operation carries a Lamport timestamp so clients converge without a lock.

    ### UI

    - Viewer avatars in the RFC detail toolbar (up to 5, then "+N more")
    - Highlighted line range showing another reviewer's current selection
    - Toast notification when a comment is posted on the RFC you are reading

    ## Consequences

    - **Server**: new WebSocket handler, operations log table in SQLite.
    - **Client**: reactive presence state, avatar overlays.
    - Adds a persistent connection per open RFC — monitor battery/data impact on iPad.

    ## Alternatives Considered

    **Polling**: Simple but high-frequency traffic and poor UX; rejected.

    **Peer-to-peer (MultipeerConnectivity)**: Requires all reviewers on the same LAN;
    rejected for v1 — a follow-up RFC can revisit for local collaboration scenarios.
    """
}
