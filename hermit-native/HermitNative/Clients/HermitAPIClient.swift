import Foundation
import os.log

// MARK: - hermit-u1k: HermitAPIClient — consumes the Hermit REST API
//
// The sole API client for the Hermit native app.
// All GitHub interactions flow through the Go backend — there is no
// direct GitHub API path in the native client.

// MARK: - Shared logger
//
// Uses OSLog so output appears in Console.app and via:
//   log stream --predicate 'subsystem == "com.hashicorp.hermit"' --level debug
//
// Debug/info messages require the subsystem logging config to be enabled — see
// Resources/com.hashicorp.hermit.plist (installed by make dev).
// Error/fault messages are always captured without any config.

private let _apiLog   = OSLog(subsystem: "com.hashicorp.hermit", category: "APIClient")
private let _mergeLog = OSLog(subsystem: "com.hashicorp.hermit", category: "Merge")

private func hLog(_ msg: String, log: OSLog = _apiLog, type: OSLogType = .debug) {
    os_log("%{public}@", log: log, type: type, msg)
}

struct RepositoryRFCSummary {
    let pendingReviewCount: Int
    let openPRCount: Int
    let prStateCounts: PRStateCounts
}

struct PRStateCounts {
    var ready = 0
    var conflicted = 0
    var failed = 0
    var needsReview = 0

    static let empty = PRStateCounts()

    var total: Int {
        ready + conflicted + failed + needsReview
    }

    mutating func add(_ other: PRStateCounts) {
        ready += other.ready
        conflicted += other.conflicted
        failed += other.failed
        needsReview += other.needsReview
    }
}

// MARK: - Shared API protocol

/// All views and sessions depend on this protocol, not a concrete type.
protocol HermitClientProtocol: Actor {
    // RFC discovery
    func discoverRFCs() async throws -> (mainBranch: [RFCFile], pullRequests: [RFCPullRequest], summary: RepositoryRFCSummary)
    func listMainBranchRFCs() async throws -> [RFCFile]
    func fetchRFCContent(path: String, ref: String) async throws -> String
    func fetchPRRFCContent(prNumber: Int) async throws -> String
    func fetchPRRFCContent(prNumber: Int, filePath: String) async throws -> String
    func fetchPRAuthorLogin(prNumber: Int) async throws -> String
    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String]
    func listPRChangedFiles(prNumber: Int, docsPath: String) async throws -> [String]

    // Review threads
    func listReviewComments(prNumber: Int) async throws -> [ReviewThread]
    func createReviewComment(prNumber: Int, body: String, filePath: String,
                              lineStart: Int, lineEnd: Int,
                              textFingerprint: String) async throws -> ReviewThread
    func replyToReviewComment(prNumber: Int, threadId: String, body: String) async throws -> ReviewThread
    func deleteReviewComment(prNumber: Int, threadId: String) async throws
    func resolveReviewThread(prNumber: Int, threadId: String) async throws
    func unresolveReviewThread(prNumber: Int, threadId: String) async throws
    func getReviewState(prNumber: Int) async throws -> ReviewState
    func approve(prNumber: Int) async throws

    // Merge / branch-update status
    func getMergeStatus(prNumber: Int) async throws -> Bool   // true = branch is behind base
    func updateBranch(prNumber: Int) async throws

    // Current authenticated user
    func fetchCurrentUser() async throws -> String   // returns GitHub login

    // Publishing (branch → commit → PR)
    func getMainBranchSHA() async throws -> String
    func createBranch(name: String, fromSHA: String) async throws
    func commitFile(branch: String, path: String, content: String,
                    message: String) async throws -> String   // returns commit SHA
    func createPR(title: String, body: String,
                  headBranch: String, label: String) async throws -> RFCPullRequest

    // Promote draft RFC to in-review: rewrites frontmatter, ensures label, opens PR.
    func submitForReview(rfcID: String) async throws -> SubmitForReviewResult
    // Open a marker PR for a fresh review session on an already-merged/closed PR document.
    func startReviewSession(filePath: String, previousPRNumber: Int) async throws -> ReviewSessionResult

    // Accept RFC: rewrites frontmatter to "accepted" on the PR branch and squash-merges.
    func acceptRFC(prNumber: Int, filePath: String) async throws -> AcceptRFCResult
    // Merge PR: squash-merges without any frontmatter rewrite (use after CI unblocks).
    func mergePR(prNumber: Int) async throws -> MergePRResult
    // Poll GitHub CI check status for a commit SHA.
    func getCIStatus(commitSHA: String) async throws -> String  // "pending" | "success" | "failure"

    // PR reviews — request changes, list, dismiss.
    func requestChanges(prNumber: Int, body: String) async throws
    func listPRReviews(prNumber: Int) async throws -> [PRReview]
    func dismissReview(prNumber: Int, reviewID: Int64, message: String) async throws

    // Lifecycle transitions on main-branch RFCs (require admin/maintain permission).
    func approveRFC(rfcID: String) async throws -> LifecycleTransitionResult
    func markRFCImplemented(rfcID: String) async throws -> LifecycleTransitionResult

    // Access control — returns the caller's collaborator permission level for the repo.
    func getCallerPermission() async throws -> String
}

// MARK: - HermitAPIClient

/// Calls the Hermit REST API (/api/v1/…) running on the embedded local
/// server (localhost), a discovered local-network server, or a remote URL.
///
/// hermit-anchor metadata, reply threading, and comment resolution are all
/// handled server-side — no GitHub API alignment needed in Swift.
actor HermitAPIClient: HermitClientProtocol {

    struct Config {
        let baseURL: String   // e.g. "http://127.0.0.1:8765"
        let repositoryID: String?
        let owner:   String
        let repo:    String
        let docsPath: String
        let rfcLabel: String
        let pat:     String   // sent as Authorization: Bearer header
    }

    private let config: Config
    private let session: URLSession
    private var resolvedRepoID: String? = nil  // cached after first /repositories lookup

    init(config: Config) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - discoverRFCs

    func discoverRFCs() async throws -> (mainBranch: [RFCFile], pullRequests: [RFCPullRequest], summary: RepositoryRFCSummary) {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/rfcs")
        let data = try await get(u)

        struct RFCItem: Decodable {
            let id: String
            let title: String
            let pr_title: String?
            let path: String
            let source_type: String
            let lifecycle_status: String?
            let pr_number: Int?
            let head_sha: String?
            let head_ref: String?
            let pr_state: String?
            let pr_merged: Bool?
            let mergeable: Bool?
            let mergeable_state: String?
            let document_type: String?
            let labels: [String]?
            let changed_files: Int?
            let additions: Int?
            let deletions: Int?
            let commentable: Bool?
            // hermit-ixk: populated by server for both main-branch and PR items.
            let html_url: String?
        }

        struct Summary: Decodable {
            let pending_review_count: Int
            let open_pr_count: Int
            let pr_states: PRStateCountsPayload?
        }
        struct PRStateCountsPayload: Decodable {
            let ready: Int?
            let conflicted: Int?
            let failed: Int?
            let needs_review: Int?
        }
        struct RFCPage: Decodable {
            let items: [RFCItem]
            let summary: Summary?
        }
        let decoder = JSONDecoder()
        let page = try decoder.decode(RFCPage.self, from: data)
        let items = page.items
        var files: [RFCFile] = []
        var prs: [RFCPullRequest] = []

        for item in items {
            if item.source_type == "pull_request", let prNumber = item.pr_number {
                prs.append(RFCPullRequest(
                    id: prNumber, number: prNumber,
                    title: item.title,
                    prTitle: item.pr_title ?? item.title,
                    prState: item.pr_state ?? "open",
                    prMerged: item.pr_merged ?? false,
                    body: "",
                    headSHA: item.head_sha ?? "",
                    headRef: item.head_ref ?? "",
                    htmlURL: item.html_url ?? "",
                    state: item.pr_state ?? "open",
                    draft: false,
                    mergeable: item.mergeable,
                    mergeableState: item.mergeable_state,
                    documentType: item.document_type ?? "rfc",
                    documentPath: item.path,
                    catalogID: item.id,
                    labels: item.labels ?? [],
                    changedFiles: item.changed_files ?? 0,
                    additions: item.additions ?? 0,
                    deletions: item.deletions ?? 0
                ))
            } else {
                files.append(RFCFile(id: item.id, name: item.title,
                                     path: item.path, sha: item.head_sha ?? "",
                                     htmlURL: item.html_url ?? "",
                                     lifecycleStatus: item.lifecycle_status))
            }
        }
        return (
            files,
            prs,
            RepositoryRFCSummary(
                pendingReviewCount: page.summary?.pending_review_count ?? prs.count,
                openPRCount: page.summary?.open_pr_count ?? prs.count,
                prStateCounts: PRStateCounts(
                    ready: page.summary?.pr_states?.ready ?? 0,
                    conflicted: page.summary?.pr_states?.conflicted ?? 0,
                    failed: page.summary?.pr_states?.failed ?? 0,
                    needsReview: page.summary?.pr_states?.needs_review ?? 0
                )
            )
        )
    }

    // MARK: - listMainBranchRFCs

    func listMainBranchRFCs() async throws -> [RFCFile] {
        let (files, _, _) = try await discoverRFCs()
        return files
    }

    // MARK: - fetchRFCContent

    func fetchRFCContent(path: String, ref: String) async throws -> String {
        let repoID = try await repoID()
        // .urlPathAllowed does not encode '/' — use a custom set that does so the
        // full path is treated as a single path segment by the Go router.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
        let u = url("/api/v1/repositories/\(repoID)/rfcs/\(encodedPath)?ref=\(ref)")
        let data = try await get(u)
        struct RFCDoc: Decodable { let markdown_source: String }
        return (try? JSONDecoder().decode(RFCDoc.self, from: data))?.markdown_source
            ?? String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - fetchPRRFCContent

    func fetchPRRFCContent(prNumber: Int) async throws -> String {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/rfc/render")
        let data = try await get(u)
        struct RFCDoc: Decodable { let markdown_source: String }
        return (try? JSONDecoder().decode(RFCDoc.self, from: data))?.markdown_source
            ?? String(data: data, encoding: .utf8) ?? ""
    }

    func fetchPRRFCContent(prNumber: Int, filePath: String) async throws -> String {
        let repoID = try await repoID()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let catalogID = "pr:\(prNumber):\(filePath)"
        let encodedID = catalogID.addingPercentEncoding(withAllowedCharacters: allowed) ?? catalogID
        let u = url("/api/v1/repositories/\(repoID)/rfcs/\(encodedID)")
        let data = try await get(u)
        struct RFCDoc: Decodable { let markdown_source: String }
        return (try? JSONDecoder().decode(RFCDoc.self, from: data))?.markdown_source
            ?? String(data: data, encoding: .utf8) ?? ""
    }

    func fetchPRAuthorLogin(prNumber: Int) async throws -> String {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/rfc/render")
        let data = try await get(u)
        struct RFCDoc: Decodable { let pr_author_login: String? }
        return (try? JSONDecoder().decode(RFCDoc.self, from: data))?.pr_author_login ?? ""
    }

    // MARK: - listFilesOnRef

    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String] {
        let (files, _, _) = try await discoverRFCs()
        return files.map(\.path)
    }

    // MARK: - listPRChangedFiles

    func listPRChangedFiles(prNumber: Int, docsPath: String) async throws -> [String] {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/rfc/render")
        let data = try await get(u)
        struct Doc: Decodable { let path: String }
        let doc = try JSONDecoder().decode(Doc.self, from: data)
        return doc.path.isEmpty ? [] : [doc.path]
    }

    // MARK: - listReviewComments

    func listReviewComments(prNumber: Int) async throws -> [ReviewThread] {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads")
        let data = try await get(u)
        struct Page: Decodable { let items: [ServerThread] }
        let threads = try Self.iso8601Decoder.decode(Page.self, from: data).items
        return threads.map { $0.toReviewThread() }
    }

    // MARK: - createReviewComment

    func createReviewComment(prNumber: Int, body: String, filePath: String,
                              lineStart: Int, lineEnd: Int,
                              textFingerprint: String) async throws -> ReviewThread {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads")
        let payload: [String: Any] = [
            "body": body,
            "anchor": [
                "line_start": lineStart,
                "line_end": lineEnd,
                "file_path": filePath,
                "text_fingerprint": textFingerprint,
            ] as [String: Any],
        ]
        let data = try await post(u, body: payload)
        let thread = try Self.iso8601Decoder.decode(ServerThread.self, from: data)
        return thread.toReviewThread()
    }

    // MARK: - replyToReviewComment

    func replyToReviewComment(prNumber: Int, threadId: String, body: String) async throws -> ReviewThread {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads/\(threadId)/reply")
        let data = try await post(u, body: ["body": body])
        let thread = try Self.iso8601Decoder.decode(ServerThread.self, from: data)
        return thread.toReviewThread()
    }

    // MARK: - deleteReviewComment

    func deleteReviewComment(prNumber: Int, threadId: String) async throws {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads/\(threadId)")
        try await delete(u)
    }

    // MARK: - resolveReviewThread / unresolveReviewThread

    func resolveReviewThread(prNumber: Int, threadId: String) async throws {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads/\(threadId)/resolve")
        _ = try await post(u, body: [:])
    }

    func unresolveReviewThread(prNumber: Int, threadId: String) async throws {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads/\(threadId)/unresolve")
        _ = try await post(u, body: [:])
    }

    // MARK: - fetchCurrentUser

    func fetchCurrentUser() async throws -> String {
        let u = url("/api/v1/me")
        let data = try await get(u)
        struct Me: Decodable { let login: String }
        return try JSONDecoder().decode(Me.self, from: data).login
    }

    private static let iso8601Decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - getReviewState

    func getReviewState(prNumber: Int) async throws -> ReviewState {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review")
        let data = try await get(u)
        struct State: Decodable { let approved: Bool; let reviewers: [String] }
        let s = try JSONDecoder().decode(State.self, from: data)
        return ReviewState(approved: s.approved, reviewers: s.reviewers)
    }

    // MARK: - approve

    func approve(prNumber: Int) async throws {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review/approve")
        _ = try await post(u, body: [:])
    }

    // MARK: - getMergeStatus / updateBranch

    func getMergeStatus(prNumber: Int) async throws -> Bool {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review/merge-status")
        let data = try await get(u)
        struct Response: Decodable { let behind: Bool }
        return try JSONDecoder().decode(Response.self, from: data).behind
    }

    func updateBranch(prNumber: Int) async throws {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review/update-branch")
        _ = try await put(u, body: [:])
    }

    // MARK: - submitForReview

    func submitForReview(rfcID: String) async throws -> SubmitForReviewResult {
        let repoID = try await repoID()
        // rfcID may be a full path like "docs-cms/rfcs/rfc-008-logging.md".
        // URL-encode the path so it travels as a single path segment.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = rfcID.addingPercentEncoding(withAllowedCharacters: allowed) ?? rfcID
        let u = url("/api/v1/repositories/\(repoID)/rfcs/\(encoded)/submit-for-review")
        let data = try await post(u, body: [:])
        return try JSONDecoder().decode(SubmitForReviewResult.self, from: data)
    }

    // MARK: - startReviewSession

    func startReviewSession(filePath: String, previousPRNumber: Int) async throws -> ReviewSessionResult {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/review-sessions")
        let data = try await post(u, body: [
            "file_path": filePath,
            "previous_pr_number": previousPRNumber,
        ] as [String: Any])
        return try JSONDecoder().decode(ReviewSessionResult.self, from: data)
    }

    // MARK: - acceptRFC

    func acceptRFC(prNumber: Int, filePath: String) async throws -> AcceptRFCResult {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/accept")
        let data = try await post(u, body: ["file_path": filePath])
        return try JSONDecoder().decode(AcceptRFCResult.self, from: data)
    }

    // MARK: - mergePR

    func mergePR(prNumber: Int) async throws -> MergePRResult {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/merge")
        hLog("mergePR: POST \(u.path) for PR #\(prNumber)", log: _mergeLog, type: .info)
        let data = try await post(u, body: [:] as [String: String])
        let rawBody = String(data: data, encoding: .utf8) ?? "<unreadable>"
        hLog("mergePR: response body: \(rawBody)", log: _mergeLog, type: .info)
        do {
            let result = try JSONDecoder().decode(MergePRResult.self, from: data)
            hLog("mergePR: decoded — merged=\(result.merged) blockedByCI=\(result.blockedByCI)", log: _mergeLog, type: .info)
            return result
        } catch {
            hLog("mergePR: JSON decode failed: \(error) — body: \(rawBody)", log: _mergeLog, type: .fault)
            throw error
        }
    }

    // MARK: - getCIStatus

    func getCIStatus(commitSHA: String) async throws -> String {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/ci-status?sha=\(commitSHA)")
        let data = try await get(u)
        struct Response: Decodable { let status: String }
        return (try? JSONDecoder().decode(Response.self, from: data))?.status ?? "pending"
    }

    // MARK: - requestChanges

    func requestChanges(prNumber: Int, body: String) async throws {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review/request-changes")
        _ = try await post(u, body: ["body": body])
    }

    // MARK: - listPRReviews

    func listPRReviews(prNumber: Int) async throws -> [PRReview] {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review/list")
        let data = try await get(u)
        struct Response: Decodable { let items: [PRReview] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(Response.self, from: data))?.items ?? []
    }

    // MARK: - dismissReview

    func dismissReview(prNumber: Int, reviewID: Int64, message: String) async throws {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review/\(reviewID)/dismiss")
        _ = try await put(u, body: ["message": message])
    }

    // MARK: - approveRFC

    func approveRFC(rfcID: String) async throws -> LifecycleTransitionResult {
        let repoID = try await repoID()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = rfcID.addingPercentEncoding(withAllowedCharacters: allowed) ?? rfcID
        let u = url("/api/v1/repositories/\(repoID)/rfcs/\(encoded)/approve")
        let data = try await post(u, body: [:])
        return try JSONDecoder().decode(LifecycleTransitionResult.self, from: data)
    }

    // MARK: - markRFCImplemented

    func markRFCImplemented(rfcID: String) async throws -> LifecycleTransitionResult {
        let repoID = try await repoID()
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        let encoded = rfcID.addingPercentEncoding(withAllowedCharacters: allowed) ?? rfcID
        let u = url("/api/v1/repositories/\(repoID)/rfcs/\(encoded)/mark-implemented")
        let data = try await post(u, body: [:])
        return try JSONDecoder().decode(LifecycleTransitionResult.self, from: data)
    }

    // MARK: - getCallerPermission

    /// Returns the caller's collaborator permission level via the Hermit server.
    /// hermit-cns: previously called api.github.com directly, which silently
    /// failed against Gitea (a self-hosted GitHub-compatible server).  Now routes
    /// through GET /api/v1/repositories/{id}/caller-permission so the Go server
    /// uses the configured Gitea baseURL for all identity + permission lookups.
    /// Returns one of: "admin", "maintain", "write", "triage", "read", "none".
    func getCallerPermission() async throws -> String {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/caller-permission")
        let data = try await get(u)
        struct CallerPermissionResult: Decodable {
            let login: String
            let permission: String
        }
        let result = try JSONDecoder().decode(CallerPermissionResult.self, from: data)
        return result.permission.isEmpty ? "none" : result.permission
    }

    // MARK: - getMainBranchSHA

    func getMainBranchSHA() async throws -> String {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/branches/main")
        let data = try await get(u)
        struct Branch: Decodable { let sha: String }
        let b = try JSONDecoder().decode(Branch.self, from: data)
        return b.sha
    }

    // MARK: - createBranch

    func createBranch(name: String, fromSHA: String) async throws {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/branches")
        _ = try await post(u, body: ["name": name, "sha": fromSHA])
    }

    // MARK: - commitFile

    func commitFile(branch: String, path: String, content: String,
                    message: String) async throws -> String {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/contents")
        let encoded = Data(content.utf8).base64EncodedString()
        let payload: [String: Any] = [
            "branch": branch, "path": path,
            "content": encoded, "message": message,
        ]
        let data = try await post(u, body: payload)
        struct Committed: Decodable { let sha: String }
        let c = try JSONDecoder().decode(Committed.self, from: data)
        return c.sha
    }

    // MARK: - createPR

    func createPR(title: String, body: String,
                  headBranch: String, label: String) async throws -> RFCPullRequest {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests")
        let payload: [String: Any] = [
            "title": title, "body": body,
            "head": headBranch, "base": "main",
            "labels": [label],
        ]
        let data = try await post(u, body: payload)

        struct PR: Decodable {
            let number: Int; let title: String; let body: String
            let headSHA: String; let headRef: String; let htmlURL: String
            let state: String; let draft: Bool; let labels: [String]
        }
        let pr = try JSONDecoder().decode(PR.self, from: data)
        return RFCPullRequest(id: pr.number, number: pr.number,
                              title: pr.title, prTitle: pr.title,
                              prState: "open", prMerged: false, body: pr.body,
                              headSHA: pr.headSHA, headRef: pr.headRef,
                              htmlURL: pr.htmlURL, state: pr.state,
                              draft: pr.draft, mergeable: nil,
                              mergeableState: nil, documentType: "rfc",
                              documentPath: "", catalogID: "pr-\(pr.number)",
                              labels: pr.labels, changedFiles: 0,
                              additions: 0, deletions: 0)
    }

    // MARK: - HTTP helpers

    /// Returns the server-assigned repo ID (e.g. "repo_2001") by fetching
    /// /api/v1/repositories and matching owner+name. Cached after first call.
    private func repoID() async throws -> String {
        if let repositoryID = config.repositoryID, !repositoryID.isEmpty { return repositoryID }
        if let cached = resolvedRepoID { return cached }

        let u = url("/api/v1/repositories")
        let data = try await get(u)

        struct RepoItem: Decodable {
            let id: String
            let owner: String
            let name: String
        }
        struct RepoPage: Decodable { let items: [RepoItem] }
        let page = try JSONDecoder().decode(RepoPage.self, from: data)

        guard let match = page.items.first(where: {
            $0.owner.lowercased() == config.owner.lowercased() &&
            $0.name.lowercased()  == config.repo.lowercased()
        }) else {
            throw HermitAPIError.httpError(statusCode: 404,
                message: "Repository \(config.owner)/\(config.repo) not found on server")
        }
        resolvedRepoID = match.id
        return match.id
    }

    private func url(_ path: String) -> URL {
        URL(string: config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!
    }

    private func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue("Bearer \(config.pat)", forHTTPHeaderField: "Authorization")
        hLog("GET \(url.path)")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            hLog("GET \(url.path) → \(http.statusCode)")
        }
        try checkResponse(resp, data: data)
        return data
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.pat)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        hLog("POST \(url.path)")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            hLog("POST \(url.path) → \(http.statusCode)")
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
                hLog("POST \(url.path) \(http.statusCode) error body: \(body)", type: .error)
            }
        }
        try checkResponse(resp, data: data)
        return data
    }

    private func delete(_ url: URL) async throws {
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(config.pat)", forHTTPHeaderField: "Authorization")
        hLog("DELETE \(url.path)")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse {
            hLog("DELETE \(url.path) → \(http.statusCode)")
        }
        // 204 No Content is success; checkResponse handles errors
        if let http = resp as? HTTPURLResponse, http.statusCode == 204 { return }
        try checkResponse(resp, data: data)
    }

    private func put(_ url: URL, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.pat)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, http.statusCode == 204 { return data }
        try checkResponse(resp, data: data)
        return data
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let msg = Self.extractErrorMessage(from: data) ?? String(data: data, encoding: .utf8) ?? "unknown error"
            throw HermitAPIError.httpError(statusCode: http.statusCode, message: msg)
        }
    }

    /// Pulls the human-readable `message` field out of a Hermit error JSON body.
    /// The raw message may itself embed a deeper GitHub error JSON — strip that too.
    /// Input example: "submit request changes: github request changes failed: 422 {\"message\":\"Review Can not...\",\"errors\":[...]}"
    /// Output:        "Review Can not request changes on your own pull request"
    private static func extractErrorMessage(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? String else { return nil }

        // Try to find and parse an embedded JSON blob in the message (GitHub error payload).
        // GitHub errors arrive as: "... failed: 422 {\"message\":\"...\",\"errors\":[...]}"
        if let braceIdx = msg.range(of: " {", options: .backwards) {
            let jsonPart = String(msg[braceIdx.lowerBound...]).trimmingCharacters(in: .whitespaces)
            if let jsonData = jsonPart.data(using: .utf8),
               let inner = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
                // Prefer the errors array first, then fall back to message
                if let errors = inner["errors"] as? [String], let first = errors.first, !first.isEmpty {
                    return first
                }
                if let innerMsg = inner["message"] as? String, !innerMsg.isEmpty {
                    return innerMsg
                }
            }
            // JSON parse failed — just strip the blob and any trailing HTTP code
            var clean = String(msg[msg.startIndex..<braceIdx.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // Also strip trailing ": NNN" (HTTP status code)
            if let codeRange = clean.range(of: #":\s*\d{3}$"#, options: .regularExpression) {
                clean = String(clean[clean.startIndex..<codeRange.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }
            return clean.isEmpty ? msg : clean
        }
        return msg
    }
}

enum HermitAPIError: LocalizedError {
    case httpError(statusCode: Int, message: String)
    var errorDescription: String? {
        switch self {
        case .httpError(let code, let msg): return "HTTP \(code): \(msg)"
        }
    }
}

extension Error {
    var isHermitLineResolutionFailure: Bool {
        guard let apiError = self as? HermitAPIError else { return false }
        if case .httpError(let statusCode, let message) = apiError {
            return statusCode == 502
                && message.localizedCaseInsensitiveContains("line could not be resolved")
        }
        return false
    }
}

// MARK: - Server thread decoding

/// Mirrors the Go `Thread` type returned by the Hermit server.
private struct ServerThread: Decodable {
    struct ServerAnchor: Decodable {
        let lineStart: Int
        let lineEnd: Int
        let filePath: String?
        let textFingerprint: String
        enum CodingKeys: String, CodingKey {
            case lineStart = "line_start"
            case lineEnd = "line_end"
            case filePath = "file_path"
            case textFingerprint = "text_fingerprint"
        }
    }
    struct ServerMessage: Decodable {
        let id: String
        let author: String
        let body: String
        let createdAt: Date
        enum CodingKeys: String, CodingKey {
            case id, author, body
            case createdAt = "created_at"
        }
    }
    let id: String
    let prNumber: Int
    let status: String
    let outdated: Bool?
    let anchor: ServerAnchor
    let messages: [ServerMessage]
    enum CodingKeys: String, CodingKey {
        case id, status, anchor, messages, outdated
        case prNumber = "pr_number"
    }

    func toReviewThread() -> ReviewThread {
        ReviewThread(
            id: id,
            prNumber: prNumber,
            status: status,
            outdated: outdated ?? false,
            filePath: anchor.filePath ?? "",
            lineStart: anchor.lineStart,
            lineEnd: anchor.lineEnd,
            messages: messages.map {
                ThreadMessage(id: $0.id, author: $0.author, body: Self.stripAnchor($0.body), createdAt: $0.createdAt)
            }
        )
    }

    /// Strip any embedded <!-- hermit-anchor ... --> metadata from a comment body.
    /// The Go backend strips this when fetching, but comments posted directly to
    /// Gitea (or with a newline in the fingerprint) may slip through.
    private static func stripAnchor(_ body: String) -> String {
        // Match <!-- hermit-anchor ... --> lazily, tolerating embedded newlines.
        guard let regex = try? NSRegularExpression(
            pattern: #"<!--\s*hermit-anchor\s+lines:\d+-\d+\s+fp:.+?\s*-->"#,
            options: [.dotMatchesLineSeparators]
        ) else { return body }
        let range = NSRange(body.startIndex..., in: body)
        return regex.stringByReplacingMatches(in: body, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
