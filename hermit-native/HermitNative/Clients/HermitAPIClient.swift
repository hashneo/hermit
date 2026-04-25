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
    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String]
    func listPRChangedFiles(prNumber: Int, docsPath: String) async throws -> [String]

    // Review comments
    func listReviewComments(prNumber: Int) async throws -> [PRReviewComment]
    func createReviewComment(prNumber: Int, body: String, commitSHA: String,
                              path: String, line: Int) async throws -> PRReviewComment
    func replyToReviewComment(prNumber: Int, commentId: Int, body: String) async throws -> PRReviewComment
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

    init(config: Config) {
        self.config = config
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - discoverRFCs

    func discoverRFCs() async throws -> (mainBranch: [RFCFile], pullRequests: [RFCPullRequest]) {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/rfcs")
        let data = try await get(u)

        struct RFCItem: Decodable {
            let id: String
            let title: String
            let path: String
            let sha: String
            let prNumber: Int?
            let prTitle: String?
            let headSHA: String?
            let headRef: String?
            let htmlURL: String?
            let state: String?
            let draft: Bool?
            let labels: [String]?
        }

        let items = try JSONDecoder().decode([RFCItem].self, from: data)
        var files: [RFCFile] = []
        var prs: [RFCPullRequest] = []

        for item in items {
            if let prNumber = item.prNumber {
                prs.append(RFCPullRequest(
                    id: prNumber, number: prNumber,
                    title: item.prTitle ?? item.title,
                    body: "",
                    headSHA: item.headSHA ?? "",
                    headRef: item.headRef ?? "",
                    htmlURL: item.htmlURL ?? "",
                    state: item.state ?? "open",
                    draft: item.draft ?? false,
                    labels: item.labels ?? []
                ))
            } else {
                files.append(RFCFile(id: item.id, name: item.title,
                                     path: item.path, sha: item.sha,
                                     htmlURL: item.htmlURL ?? ""))
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
        let repoID = encodedRepoID()
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let u = url("/api/v1/repositories/\(repoID)/rfcs/\(encodedPath)?ref=\(ref)")
        let data = try await get(u)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - listFilesOnRef

    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String] {
        let (files, _) = try await discoverRFCs()
        return files.map(\.path)
    }

    // MARK: - listPRChangedFiles

    func listPRChangedFiles(prNumber: Int, docsPath: String) async throws -> [String] {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/rfc")
        let data = try await get(u)
        struct Doc: Decodable { let path: String }
        let doc = try JSONDecoder().decode(Doc.self, from: data)
        return doc.path.isEmpty ? [] : [doc.path]
    }

    // MARK: - listReviewComments

    func listReviewComments(prNumber: Int) async throws -> [PRReviewComment] {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads")
        let data = try await get(u)

        struct ThreadItem: Decodable {
            let id: Int
            let body: String
            let path: String
            let line: Int?
            let inReplyToId: Int?
            let user: String
            let createdAt: String
            let resolved: Bool
        }

        let items = try JSONDecoder().decode([ThreadItem].self, from: data)
        let fmt = ISO8601DateFormatter()
        return items.map { t in
            PRReviewComment(id: t.id, body: t.body, path: t.path, line: t.line,
                            inReplyToId: t.inReplyToId, user: t.user,
                            createdAt: fmt.date(from: t.createdAt) ?? Date(),
                            resolved: t.resolved)
        }
    }

    // MARK: - createReviewComment

    func createReviewComment(prNumber: Int, body: String, commitSHA: String,
                              path: String, line: Int) async throws -> PRReviewComment {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads")
        let payload: [String: Any] = [
            "body": body, "path": path, "line": line, "commit_sha": commitSHA,
        ]
        let data = try await post(u, body: payload)

        struct Created: Decodable {
            let id: Int; let body: String; let path: String; let line: Int?
            let inReplyToId: Int?; let user: String; let createdAt: String; let resolved: Bool
        }
        let c = try JSONDecoder().decode(Created.self, from: data)
        let fmt = ISO8601DateFormatter()
        return PRReviewComment(id: c.id, body: c.body, path: c.path, line: c.line,
                               inReplyToId: c.inReplyToId, user: c.user,
                               createdAt: fmt.date(from: c.createdAt) ?? Date(),
                               resolved: c.resolved)
    }

    // MARK: - replyToReviewComment

    func replyToReviewComment(prNumber: Int, commentId: Int, body: String) async throws -> PRReviewComment {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads/\(commentId)/replies")
        let data = try await post(u, body: ["body": body])

        struct Reply: Decodable {
            let id: Int; let body: String; let path: String; let line: Int?
            let inReplyToId: Int?; let user: String; let createdAt: String; let resolved: Bool
        }
        let r = try JSONDecoder().decode(Reply.self, from: data)
        let fmt = ISO8601DateFormatter()
        return PRReviewComment(id: r.id, body: r.body, path: r.path, line: r.line,
                               inReplyToId: r.inReplyToId, user: r.user,
                               createdAt: fmt.date(from: r.createdAt) ?? Date(),
                               resolved: r.resolved)
    }

    // MARK: - getReviewState

    func getReviewState(prNumber: Int) async throws -> ReviewState {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review")
        let data = try await get(u)
        struct State: Decodable { let approved: Bool; let reviewers: [String] }
        let s = try JSONDecoder().decode(State.self, from: data)
        return ReviewState(approved: s.approved, reviewers: s.reviewers)
    }

    // MARK: - approve

    func approve(prNumber: Int) async throws {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review/approve")
        _ = try await post(u, body: [:])
    }

    // MARK: - getMainBranchSHA

    func getMainBranchSHA() async throws -> String {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/branches/main")
        let data = try await get(u)
        struct Branch: Decodable { let sha: String }
        let b = try JSONDecoder().decode(Branch.self, from: data)
        return b.sha
    }

    // MARK: - createBranch

    func createBranch(name: String, fromSHA: String) async throws {
        let repoID = encodedRepoID()
        let u = url("/api/v1/repositories/\(repoID)/branches")
        _ = try await post(u, body: ["name": name, "sha": fromSHA])
    }

    // MARK: - commitFile

    func commitFile(branch: String, path: String, content: String,
                    message: String) async throws -> String {
        let repoID = encodedRepoID()
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
        let repoID = encodedRepoID()
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

    private func encodedRepoID() -> String {
        "\(config.owner)%2F\(config.repo)"
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
