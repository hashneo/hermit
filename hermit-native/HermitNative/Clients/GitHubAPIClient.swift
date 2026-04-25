import Foundation

// MARK: - Domain models

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

// MARK: - GitHubAPIClient

/// All GitHub REST API interactions for Hermit.
/// Authenticated via PAT from KeychainHelper.
/// Surfaces rate-limit-aware errors and paginates automatically.
actor GitHubAPIClient {

    // MARK: Configuration

    struct Config {
        let baseURL: String    // e.g. "https://api.github.com" or "http://localhost:3000/api/v1"
        let owner: String
        let repo: String
        let docsPath: String   // e.g. "docs-cms/rfcs"
        let rfcLabel: String   // e.g. "hermit:rfc-ready"
        let pat: String        // personal access token
    }

    private let config: Config
    private let session: URLSession
    private var contentCache: [String: (etag: String, data: Data)] = [:]

    /// Builds a client directly from what is currently stored in the Keychain.
    /// Returns nil if required credentials are missing.
    static func fromKeychain() -> GitHubAPIClient? {
        let kc = KeychainHelper.shared
        guard let baseURL  = kc.baseURL,
              let owner    = kc.repoOwner,
              let repo     = kc.repoName,
              let pat      = kc.pat
        else { return nil }
        let config = Config(
            baseURL:  baseURL,
            owner:    owner,
            repo:     repo,
            docsPath: kc.docsPath ?? "docs-cms/rfcs",
            rfcLabel: kc.rfcLabel ?? "hermit:rfc-ready",
            pat:      pat
        )
        return GitHubAPIClient(config: config)
    }

    init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    // MARK: - RFC Discovery (hermit-iud)

    /// Returns RFC files on the main branch plus open PRs labelled as RFC-ready.
    func discoverRFCs() async throws -> (mainBranch: [RFCFile], pullRequests: [RFCPullRequest]) {
        async let mainFiles = listMainBranchRFCs()
        async let prs       = listOpenRFCPullRequests()
        return try await (mainFiles, prs)
    }

    func listMainBranchRFCs() async throws -> [RFCFile] {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/contents/\(config.docsPath)")
        let items = try await get([GitHubContentItem].self, from: url)
        return items
            .filter { $0.type == "file" && $0.name.hasSuffix(".md") }
            .map { RFCFile(id: $0.path, name: $0.name, path: $0.path, sha: $0.sha, htmlURL: $0.htmlUrl ?? "") }
    }

    /// Lists .md file paths under docsPath on a given ref (branch/SHA).
    func listFilesOnRef(docsPath: String, ref: String) async throws -> [String] {
        var url = apiURL("repos/\(config.owner)/\(config.repo)/contents/\(docsPath)")
        url = url.appending(queryItems: [URLQueryItem(name: "ref", value: ref)])
        let items = try await get([GitHubContentItem].self, from: url)
        return items
            .filter { $0.type == "file" && $0.name.hasSuffix(".md") }
            .map { $0.path }
    }

    func listOpenRFCPullRequests() async throws -> [RFCPullRequest] {
        var results: [RFCPullRequest] = []
        var page = 1
        while true {
            var url = apiURL("repos/\(config.owner)/\(config.repo)/pulls")
            url = url.appending(queryItems: [
                URLQueryItem(name: "state", value: "open"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: "\(page)"),
            ])
            let batch = try await get([GitHubPR].self, from: url)
            let rfcPRs = batch
                .filter { pr in pr.labels.contains { $0.name == config.rfcLabel } }
                .map { RFCPullRequest(id: $0.id, number: $0.number, title: $0.title,
                                     body: $0.body ?? "", headSHA: $0.head.sha,
                                     headRef: $0.head.ref, htmlURL: $0.htmlUrl,
                                     state: $0.state, draft: $0.draft,
                                     labels: $0.labels.map(\.name)) }
            results.append(contentsOf: rfcPRs)
            if batch.count < 100 { break }
            page += 1
        }
        return results
    }

    // MARK: - RFC Content Fetching (hermit-ru2)

    /// Fetches raw markdown, using ETag-based in-memory cache.
    /// Handles both GitHub (raw+json Accept) and Gitea (JSON envelope with base64 content).
    func fetchRFCContent(path: String, ref: String) async throws -> String {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/contents/\(path)")
            .appending(queryItems: [URLQueryItem(name: "ref", value: ref)])
        let cacheKey = "\(path)@\(ref)"

        var request = authorizedRequest(url: url)
        // Use raw Accept for GitHub.com; Gitea ignores it and returns JSON envelope.
        if config.baseURL.contains("api.github.com") {
            request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        }
        if let cached = contentCache[cacheKey] {
            request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response) = try await session.data(for: request)
        try checkRateLimit(response)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }

        if http.statusCode == 304, let cached = contentCache[cacheKey] {
            return String(data: cached.data, encoding: .utf8) ?? ""
        }
        try checkStatus(http)

        // Try to decode as raw text first (GitHub.com raw response or plain text).
        // If the response looks like JSON (starts with '{'), decode the envelope and
        // extract the base64 content field (Gitea behaviour).
        let resultData: Data
        let trimmed = data.prefix(1)
        if trimmed.first == UInt8(ascii: "{") {
            // JSON envelope — decode and base64-decode the content field
            struct ContentEnvelope: Decodable {
                let content: String
                let encoding: String?
            }
            let envelope = try JSONDecoder().decode(ContentEnvelope.self, from: data)
            let cleaned = envelope.content.components(separatedBy: .whitespacesAndNewlines).joined()
            guard let decoded = Data(base64Encoded: cleaned) else {
                throw APIError.invalidResponse
            }
            resultData = decoded
        } else {
            resultData = data
        }

        if let etag = http.value(forHTTPHeaderField: "ETag") {
            contentCache[cacheKey] = (etag: etag, data: resultData)
        }
        return String(data: resultData, encoding: .utf8) ?? ""
    }

    // MARK: - PR Review Comment CRUD (hermit-9os)

    func listReviewComments(prNumber: Int) async throws -> [PRReviewComment] {
        var results: [PRReviewComment] = []
        var page = 1
        while true {
            var url = apiURL("repos/\(config.owner)/\(config.repo)/pulls/\(prNumber)/comments")
            url = url.appending(queryItems: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: "\(page)"),
            ])
            let batch = try await get([GitHubReviewComment].self, from: url)
            results.append(contentsOf: batch.map { c in
                PRReviewComment(id: c.id, body: c.body, path: c.path,
                                line: c.line, inReplyToId: c.inReplyToId,
                                user: c.user.login, createdAt: c.createdAt,
                                resolved: false)
            })
            if batch.count < 100 { break }
            page += 1
        }
        return results
    }

    func createReviewComment(prNumber: Int, body: String, commitSHA: String,
                             path: String, line: Int) async throws -> PRReviewComment {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/pulls/\(prNumber)/comments")
        let payload: [String: Any] = [
            "body": body, "commit_id": commitSHA, "path": path,
            "line": line, "side": "RIGHT",
        ]
        let c = try await post(GitHubReviewComment.self, to: url, body: payload)
        return PRReviewComment(id: c.id, body: c.body, path: c.path,
                               line: c.line, inReplyToId: c.inReplyToId,
                               user: c.user.login, createdAt: c.createdAt,
                               resolved: false)
    }

    func replyToReviewComment(prNumber: Int, commentId: Int, body: String) async throws -> PRReviewComment {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/pulls/\(prNumber)/comments")
        let payload: [String: Any] = ["body": body, "in_reply_to": commentId]
        let c = try await post(GitHubReviewComment.self, to: url, body: payload)
        return PRReviewComment(id: c.id, body: c.body, path: c.path,
                               line: c.line, inReplyToId: c.inReplyToId,
                               user: c.user.login, createdAt: c.createdAt,
                               resolved: false)
    }

    // MARK: - PR Approval (hermit-ely)

    func getReviewState(prNumber: Int) async throws -> ReviewState {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/pulls/\(prNumber)/reviews")
        let reviews = try await get([GitHubReview].self, from: url)
        let approved = reviews.contains { $0.state == "APPROVED" }
        let reviewers = reviews.map { $0.user.login }
        return ReviewState(approved: approved, reviewers: reviewers)
    }

    func approvePR(prNumber: Int) async throws {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/pulls/\(prNumber)/reviews")
        let payload: [String: Any] = ["event": "APPROVE", "body": "Approved via Hermit."]
        _ = try await postRaw(to: url, body: payload)
    }

    // MARK: - RFC Publishing (hermit-k60)

    func createBranch(name: String, fromSHA: String) async throws {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/git/refs")
        let payload: [String: Any] = ["ref": "refs/heads/\(name)", "sha": fromSHA]
        _ = try await postRaw(to: url, body: payload)
    }

    func getMainBranchSHA() async throws -> String {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/git/ref/heads/main")
        let ref = try await get(GitHubRef.self, from: url)
        return ref.object.sha
    }

    func commitFile(branch: String, path: String, content: String,
                    message: String, existingSHA: String? = nil) async throws -> String {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/contents/\(path)")
        guard let data = content.data(using: .utf8) else { throw APIError.encodingError }
        var payload: [String: Any] = [
            "message": message,
            "content": data.base64EncodedString(),
            "branch": branch,
        ]
        if let sha = existingSHA { payload["sha"] = sha }
        let result = try await put(GitHubCommitResult.self, to: url, body: payload)
        return result.content.sha
    }

    func createPR(title: String, body: String, headBranch: String,
                  baseBranch: String = "main", label: String) async throws -> RFCPullRequest {
        let url = apiURL("repos/\(config.owner)/\(config.repo)/pulls")
        let payload: [String: Any] = [
            "title": title, "body": body,
            "head": headBranch, "base": baseBranch, "draft": false,
        ]
        let pr = try await post(GitHubPR.self, to: url, body: payload)
        // Add RFC-ready label
        let labelsURL = apiURL("repos/\(config.owner)/\(config.repo)/issues/\(pr.number)/labels")
        _ = try await postRaw(to: labelsURL, body: ["labels": [label]])
        return RFCPullRequest(id: pr.id, number: pr.number, title: pr.title,
                              body: pr.body ?? "", headSHA: pr.head.sha,
                              headRef: pr.head.ref, htmlURL: pr.htmlUrl,
                              state: pr.state, draft: pr.draft,
                              labels: pr.labels.map(\.name) + [label])
    }

    // MARK: - Rate limit handling + pagination (hermit-tqa)

    private func checkRateLimit(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 429 || http.statusCode == 403 {
            let reset = http.value(forHTTPHeaderField: "X-RateLimit-Reset")
                .flatMap(TimeInterval.init).map { Date(timeIntervalSince1970: $0) }
            throw APIError.rateLimited(resetAt: reset)
        }
    }

    private func checkStatus(_ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200...299: return
        case 401, 403:  throw APIError.unauthorized
        case 404:       throw APIError.notFound
        case 422:       throw APIError.unprocessableEntity
        default:        throw APIError.httpError(http.statusCode)
        }
    }

    // MARK: - HTTP helpers

    private func apiURL(_ path: String) -> URL {
        // Trim trailing slash from baseURL to avoid double-slash
        let base = config.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(base)/\(path)")!
    }

    private func authorizedRequest(url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        r.setValue("Bearer \(config.pat)", forHTTPHeaderField: "Authorization")
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Only send the GitHub API version header for github.com — Gitea ignores it but some
        // proxies reject unknown headers, so we only add it for the canonical GitHub host.
        if config.baseURL.contains("api.github.com") {
            r.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        }
        return r
    }

    private func get<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let request = authorizedRequest(url: url)
        let (data, response) = try await session.data(for: request)
        try checkRateLimit(response)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        try checkStatus(http)
        return try JSONDecoder.github.decode(T.self, from: data)
    }

    @discardableResult
    private func post<T: Decodable>(_ type: T.Type, to url: URL, body: [String: Any]) async throws -> T {
        let data = try await postRaw(to: url, body: body)
        return try JSONDecoder.github.decode(T.self, from: data)
    }

    @discardableResult
    private func put<T: Decodable>(_ type: T.Type, to url: URL, body: [String: Any]) async throws -> T {
        var request = authorizedRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try checkRateLimit(response)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        try checkStatus(http)
        return try JSONDecoder.github.decode(T.self, from: data)
    }

    @discardableResult
    private func postRaw(to url: URL, body: [String: Any]) async throws -> Data {
        var request = authorizedRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request)
        try checkRateLimit(response)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        try checkStatus(http)
        return data
    }

    // MARK: - Error types

    enum APIError: LocalizedError {
        case unauthorized
        case notFound
        case rateLimited(resetAt: Date?)
        case httpError(Int)
        case invalidResponse
        case encodingError
        case unprocessableEntity

        var errorDescription: String? {
            switch self {
            case .unauthorized:           return "GitHub token is invalid or expired."
            case .notFound:               return "Resource not found on GitHub."
            case .rateLimited(let d):
                if let d { return "GitHub rate limit exceeded. Resets at \(d.formatted(.dateTime.hour().minute()))." }
                return "GitHub rate limit exceeded."
            case .httpError(let c):       return "GitHub API error (HTTP \(c))."
            case .invalidResponse:        return "Unexpected response from GitHub."
            case .encodingError:          return "Failed to encode file content."
            case .unprocessableEntity:    return "GitHub rejected the request (422)."
            }
        }
    }
}

// MARK: - GitHub API response shapes (private)

private struct GitHubContentItem: Decodable {
    let name: String
    let path: String
    let sha: String
    let type: String
    let htmlUrl: String?
    enum CodingKeys: String, CodingKey {
        case name, path, sha, type, htmlUrl = "html_url"
    }
}

private struct GitHubPR: Decodable {
    let id: Int
    let number: Int
    let title: String
    let body: String?
    let state: String
    let draft: Bool
    let htmlUrl: String
    let labels: [GitHubLabel]
    let head: GitHubBranch
    enum CodingKeys: String, CodingKey {
        case id, number, title, body, state, draft, labels, head
        case htmlUrl = "html_url"
    }
}

private struct GitHubLabel: Decodable { let name: String }

private struct GitHubBranch: Decodable { let sha: String; let ref: String }

private struct GitHubReviewComment: Decodable {
    let id: Int
    let body: String
    let path: String
    let line: Int?
    let inReplyToId: Int?
    let user: GitHubUser
    let createdAt: Date
    enum CodingKeys: String, CodingKey {
        case id, body, path, line, user
        case inReplyToId = "in_reply_to_id"
        case createdAt   = "created_at"
    }
}

private struct GitHubReview: Decodable {
    let state: String
    let user: GitHubUser
}

private struct GitHubUser: Decodable { let login: String }

private struct GitHubRef: Decodable {
    struct Object: Decodable { let sha: String }
    let object: Object
}

private struct GitHubCommitResult: Decodable {
    struct Content: Decodable { let sha: String }
    let content: Content
}

// MARK: - JSONDecoder configured for GitHub dates

extension JSONDecoder {
    static let github: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - URL extension for query items

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        var comps = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        comps.queryItems = (comps.queryItems ?? []) + queryItems
        return comps.url!
    }
}
