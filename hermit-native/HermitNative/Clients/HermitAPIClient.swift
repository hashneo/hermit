import Foundation

// MARK: - hermit-u1k: HermitAPIClient — consumes the Hermit REST API
//
// Replaces direct GitHub API calls for all production paths.
// GitHubAPIClient is retained as a debug/standalone fallback.
//
// All views call AppState.makeAPIClient() which returns a HermitAPIClient
// when a server is available, or GitHubAPIClient in debug-standalone mode.

// MARK: - Shared API protocol

/// Common interface implemented by both HermitAPIClient and GitHubAPIClient.
/// Views depend on this protocol — not on a concrete type — so the server
/// mode switch is invisible to UI code.
protocol HermitClientProtocol: Actor {
    func discoverRFCs() async throws -> (mainBranch: [RFCFile], pullRequests: [RFCPullRequest])
    func fetchRFCContent(path: String, ref: String) async throws -> String
    func listReviewComments(prNumber: Int) async throws -> [PRReviewComment]
    func createReviewComment(prNumber: Int, body: String, commitSHA: String,
                              path: String, line: Int) async throws -> PRReviewComment
    func listPRChangedFiles(prNumber: Int, docsPath: String) async throws -> [String]
    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String]
    func approve(prNumber: Int) async throws
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
        // List RFCs via the Hermit repository RFC listing endpoint
        let repoID = "\(config.owner)%2F\(config.repo)"
        let url = url("/api/v1/repositories/\(repoID)/rfcs")
        let data = try await get(url)

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
                let pr = RFCPullRequest(
                    id: prNumber,
                    number: prNumber,
                    title: item.prTitle ?? item.title,
                    body: "",
                    headSHA: item.headSHA ?? "",
                    headRef: item.headRef ?? "",
                    htmlURL: item.htmlURL ?? "",
                    state: item.state ?? "open",
                    draft: item.draft ?? false,
                    labels: item.labels ?? []
                )
                prs.append(pr)
            } else {
                files.append(RFCFile(id: item.id, name: item.title,
                                     path: item.path, sha: item.sha,
                                     htmlURL: item.htmlURL ?? ""))
            }
        }
        return (files, prs)
    }

    // MARK: - fetchRFCContent

    func fetchRFCContent(path: String, ref: String) async throws -> String {
        let repoID = "\(config.owner)%2F\(config.repo)"
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? path
        let u = url("/api/v1/repositories/\(repoID)/rfcs/\(encodedPath)?ref=\(ref)")
        let data = try await get(u)
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - listReviewComments

    func listReviewComments(prNumber: Int) async throws -> [PRReviewComment] {
        let repoID = "\(config.owner)%2F\(config.repo)"
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

        let decoder = JSONDecoder()
        let items = try decoder.decode([ThreadItem].self, from: data)
        let fmt = ISO8601DateFormatter()

        return items.map { t in
            PRReviewComment(
                id: t.id,
                body: t.body,
                path: t.path,
                line: t.line,
                inReplyToId: t.inReplyToId,
                user: t.user,
                createdAt: fmt.date(from: t.createdAt) ?? Date(),
                resolved: t.resolved
            )
        }
    }

    // MARK: - createReviewComment

    func createReviewComment(prNumber: Int, body: String, commitSHA: String,
                              path: String, line: Int) async throws -> PRReviewComment {
        let repoID = "\(config.owner)%2F\(config.repo)"
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/threads")
        let payload: [String: Any] = [
            "body": body,
            "path": path,
            "line": line,
            "commit_sha": commitSHA,
        ]
        let data = try await post(u, body: payload)

        struct Created: Decodable {
            let id: Int
            let body: String
            let path: String
            let line: Int?
            let inReplyToId: Int?
            let user: String
            let createdAt: String
            let resolved: Bool
        }
        let c = try JSONDecoder().decode(Created.self, from: data)
        let fmt = ISO8601DateFormatter()
        return PRReviewComment(
            id: c.id, body: c.body, path: c.path, line: c.line,
            inReplyToId: c.inReplyToId, user: c.user,
            createdAt: fmt.date(from: c.createdAt) ?? Date(),
            resolved: c.resolved
        )
    }

    // MARK: - listPRChangedFiles

    func listPRChangedFiles(prNumber: Int, docsPath: String) async throws -> [String] {
        let repoID = "\(config.owner)%2F\(config.repo)"
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/rfc")
        let data = try await get(u)
        struct Doc: Decodable { let path: String }
        let doc = try JSONDecoder().decode(Doc.self, from: data)
        return doc.path.isEmpty ? [] : [doc.path]
    }

    // MARK: - listFilesOnRef

    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String] {
        // Fall back to discoverRFCs for the ref — the server lists all RFC files
        let (files, _) = try await discoverRFCs()
        return files.map(\.path)
    }

    // MARK: - approve

    func approve(prNumber: Int) async throws {
        let repoID = "\(config.owner)%2F\(config.repo)"
        let u = url("/api/v1/repositories/\(repoID)/pull-requests/\(prNumber)/review/approve")
        _ = try await post(u, body: [:])
    }

    // MARK: - Helpers

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
