import Foundation

// MARK: - hermit-u1k: HermitAPIClient — consumes the Hermit REST API
//
// The sole API client for the Hermit native app.
// All GitHub interactions flow through the Go backend — there is no
// direct GitHub API path in the native client.

// MARK: - Shared API protocol

/// All views and sessions depend on this protocol, not a concrete type.
protocol HermitClientProtocol: Actor {
    // RFC discovery
    func discoverRFCs() async throws -> (mainBranch: [RFCFile], pullRequests: [RFCPullRequest])
    func listMainBranchRFCs() async throws -> [RFCFile]
    func fetchRFCContent(path: String, ref: String) async throws -> String
    func fetchPRRFCContent(prNumber: Int) async throws -> String
    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String]
    func listPRChangedFiles(prNumber: Int, docsPath: String) async throws -> [String]

    // Review threads
    func listReviewComments(prNumber: Int) async throws -> [ReviewThread]
    func createReviewComment(prNumber: Int, body: String, filePath: String,
                              lineStart: Int, lineEnd: Int,
                              textFingerprint: String) async throws -> ReviewThread
    func replyToReviewComment(prNumber: Int, threadId: String, body: String) async throws -> ReviewThread
    func getReviewState(prNumber: Int) async throws -> ReviewState
    func approve(prNumber: Int) async throws

    // Publishing (branch → commit → PR)
    func getMainBranchSHA() async throws -> String
    func createBranch(name: String, fromSHA: String) async throws
    func commitFile(branch: String, path: String, content: String,
                    message: String) async throws -> String   // returns commit SHA
    func createPR(title: String, body: String,
                  headBranch: String, label: String) async throws -> RFCPullRequest
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

    func discoverRFCs() async throws -> (mainBranch: [RFCFile], pullRequests: [RFCPullRequest]) {
        let repoID = try await repoID()
        let u = url("/api/v1/repositories/\(repoID)/rfcs")
        let data = try await get(u)

        struct RFCItem: Decodable {
            let id: String
            let title: String
            let path: String
            let source_type: String
            let lifecycle_status: String?
            let pr_number: Int?
            let head_sha: String?
            let commentable: Bool?
        }

        struct RFCPage: Decodable { let items: [RFCItem] }
        let decoder = JSONDecoder()
        let items = try decoder.decode(RFCPage.self, from: data).items
        var files: [RFCFile] = []
        var prs: [RFCPullRequest] = []

        for item in items {
            if item.source_type == "pull_request", let prNumber = item.pr_number {
                prs.append(RFCPullRequest(
                    id: prNumber, number: prNumber,
                    title: item.title,
                    body: "",
                    headSHA: item.head_sha ?? "",
                    headRef: "",
                    htmlURL: "",
                    state: "open",
                    draft: false,
                    labels: []
                ))
            } else {
                files.append(RFCFile(id: item.id, name: item.title,
                                     path: item.path, sha: item.head_sha ?? "",
                                     htmlURL: "", lifecycleStatus: item.lifecycle_status))
            }
        }
        return (files, prs)
    }

    // MARK: - listMainBranchRFCs

    func listMainBranchRFCs() async throws -> [RFCFile] {
        let (files, _) = try await discoverRFCs()
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

    // MARK: - listFilesOnRef

    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String] {
        let (files, _) = try await discoverRFCs()
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
                              title: pr.title, body: pr.body,
                              headSHA: pr.headSHA, headRef: pr.headRef,
                              htmlURL: pr.htmlURL, state: pr.state,
                              draft: pr.draft, labels: pr.labels)
    }

    // MARK: - HTTP helpers

    /// Returns the server-assigned repo ID (e.g. "repo_2001") by fetching
    /// /api/v1/repositories and matching owner+name. Cached after first call.
    private func repoID() async throws -> String {
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
        let (data, resp) = try await session.data(for: req)
        try checkResponse(resp, data: data)
        return data
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(config.pat)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try checkResponse(resp, data: data)
        return data
    }

    private func checkResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown error"
            throw HermitAPIError.httpError(statusCode: http.statusCode, message: msg)
        }
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
    let anchor: ServerAnchor
    let messages: [ServerMessage]
    enum CodingKeys: String, CodingKey {
        case id, status, anchor, messages
        case prNumber = "pr_number"
    }

    func toReviewThread() -> ReviewThread {
        ReviewThread(
            id: id,
            prNumber: prNumber,
            status: status,
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
