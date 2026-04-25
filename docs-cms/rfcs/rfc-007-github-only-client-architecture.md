---
title: GitHub-Only Client Architecture
status: Draft
author: Steven Taylor
created: 2026-04-24T00:00:00Z
tags: [github, api, client, architecture, auth, rfc]
id: rfc-007
project_id: hermit
doc_uuid: a1b2c3d4-0002-4000-8000-100000000007
---

# Summary

This RFC defines the GitHub-only client architecture for the Hermit native app. In the absence of a Hermit backend server, the native app communicates directly with the GitHub REST API using a Personal Access Token (PAT) stored in the system Keychain. This RFC covers authentication, the full API surface consumed, error handling, rate limiting, and the path to migrating to a Hermit backend in the future.

# Motivation

The Hermit Go server defined in rfc-001 through rfc-005 does not yet exist. Rather than block the native app on backend development, the native app adopts a direct GitHub API integration model. This is feasible because:

- The data the native app needs (RFC file content, PR metadata, PR comments) is directly available from the GitHub REST API.
- The writes the native app performs (creating comments, creating PRs) are standard GitHub API operations.
- The PAT-based authentication model matches what the Go server uses internally (rfc-002).

When the Hermit server is built, the `GitHubAPIClient` layer defined here becomes the migration boundary — it will be replaced by a `HermitClient` that calls the Hermit REST API, with no changes required to the rest of the app.

# Detailed Design

## Authentication

### PAT Storage

The PAT is stored in the macOS/iOS system Keychain using `Security.framework`:

```swift
// KeychainHelper.swift
struct KeychainHelper {
    static func store(key: String, value: String, service: String = "com.hashicorp.hermit-native")
    static func load(key: String, service: String = "com.hashicorp.hermit-native") -> String?
    static func delete(key: String, service: String = "com.hashicorp.hermit-native")
}
```

Keys stored:
| Keychain Key | Content |
|---|---|
| `hermit.github.pat` | GitHub Personal Access Token |
| `hermit.openai.key` | OpenAI API key (optional) |
| `hermit.ai.provider` | `"apple"` or `"openai"` |
| `hermit.github.owner` | Default repo owner |
| `hermit.github.repo` | Default repo name |
| `hermit.docs.path` | Path to RFC docs within repo (e.g. `docs-cms/rfcs/`) |

### PAT Scopes Required

The PAT must have the following GitHub scopes:

| Scope | Required For |
|---|---|
| `repo` | Read private repositories, list PRs, read file contents |
| `pull_requests:write` | Create PR review comments, resolve comment threads |
| `contents:write` | Create branches and commit files (RFC creation) |

For public repositories, `public_repo` is sufficient in place of `repo`.

### Request Authentication

All requests include:

```
Authorization: Bearer {pat}
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
User-Agent: Hermit-Native/1.0
```

## GitHubAPIClient Interface

```swift
// Clients/GitHubAPIClient.swift
actor GitHubAPIClient {

    // --- Repository Discovery ---
    func listConfiguredRepositories() -> [Repository]
    // Returns repos from Keychain config; no API call needed for listing

    // --- RFC Discovery ---
    func listMainBranchRFCs(owner: String, repo: String, docsPath: String) async throws -> [RFCCatalogItem]
    // GET /repos/{owner}/{repo}/contents/{docsPath}
    // Filters entries matching ^rfc-[0-9]{3}-[a-z0-9-]+\.md$

    func listOpenRFCPullRequests(owner: String, repo: String) async throws -> [RFCCatalogItem]
    // GET /repos/{owner}/{repo}/pulls?state=open&per_page=100
    // Filters PRs with label "hermit:rfc-ready"
    // For each matching PR: GET /repos/{owner}/{repo}/pulls/{prNumber}/files
    // to identify the RFC markdown file in the diff

    // --- RFC Content ---
    func fetchRFCContent(owner: String, repo: String, path: String, ref: String) async throws -> String
    // GET /repos/{owner}/{repo}/contents/{path}?ref={ref}
    // Returns decoded base64 content (raw markdown)

    // --- Comments (PR Review Comments) ---
    func listPRComments(owner: String, repo: String, prNumber: Int) async throws -> [PRComment]
    // GET /repos/{owner}/{repo}/pulls/{prNumber}/comments

    func createPRComment(owner: String, repo: String, prNumber: Int, body: String, commitId: String, path: String, line: Int) async throws -> PRComment
    // POST /repos/{owner}/{repo}/pulls/{prNumber}/comments

    func replyToPRComment(owner: String, repo: String, prNumber: Int, commentId: Int, body: String) async throws -> PRComment
    // POST /repos/{owner}/{repo}/pulls/{prNumber}/comments/{commentId}/replies

    func resolvePRThread(owner: String, repo: String, threadId: String) async throws
    // PATCH /repos/{owner}/{repo}/pulls/comments/{commentId} is not a resolve endpoint;
    // GitHub does not expose thread resolution via REST. Resolution is posted as a
    // follow-up reply comment: "✓ Resolved" — consistent with how the Go server handles this.

    // --- Reviews ---
    func getPRReviewState(owner: String, repo: String, prNumber: Int) async throws -> ReviewState
    // GET /repos/{owner}/{repo}/pulls/{prNumber}/reviews

    func approvePR(owner: String, repo: String, prNumber: Int, body: String) async throws -> ReviewState
    // POST /repos/{owner}/{repo}/pulls/{prNumber}/reviews { event: "APPROVE" }

    // --- RFC Creation (see rfc-012 for full detail) ---
    func createBranch(owner: String, repo: String, branchName: String, fromSHA: String) async throws
    // POST /repos/{owner}/{repo}/git/refs

    func commitFile(owner: String, repo: String, path: String, content: String, message: String, branch: String) async throws -> String
    // PUT /repos/{owner}/{repo}/contents/{path}
    // Returns commit SHA

    func createPullRequest(owner: String, repo: String, title: String, body: String, head: String, base: String, labels: [String]) async throws -> PullRequest
    // POST /repos/{owner}/{repo}/pulls
    // POST /repos/{owner}/{repo}/issues/{prNumber}/labels

    func ensureLabelExists(owner: String, repo: String, label: String, color: String) async throws
    // GET /repos/{owner}/{repo}/labels/{label} → 404 → POST /repos/{owner}/{repo}/labels

    // --- Utility ---
    func getDefaultBranchSHA(owner: String, repo: String, branch: String) async throws -> String
    // GET /repos/{owner}/{repo}/git/ref/heads/{branch}

    func listRFCDirectory(owner: String, repo: String, docsPath: String, ref: String) async throws -> [String]
    // GET /repos/{owner}/{repo}/contents/{docsPath}?ref={ref}
    // Returns filenames to determine next rfc-NNN number
}
```

## Data Models

```swift
// Models.swift (GitHub-sourced types)

struct RFCCatalogItem: Identifiable, Codable {
    let id: String                  // filename or "pr:{prNumber}:{path}"
    let title: String               // parsed from frontmatter or first H1
    let path: String
    let sourceType: RFCSourceType   // .mainBranch | .pullRequest
    let sourceLabel: String         // "Main branch" | "PR #42"
    let lifecycleStatus: String     // "draft" | "accepted" | "implemented" | "unknown"
    let prNumber: Int?
    let headSHA: String?
    let commentable: Bool           // true for PR RFCs with hermit:rfc-ready label
}

enum RFCSourceType { case mainBranch, pullRequest }

struct PRComment: Identifiable, Codable {
    let id: Int
    let body: String
    let author: String
    let path: String
    let line: Int?
    let commitId: String
    let createdAt: Date
    let updatedAt: Date
    let inReplyToId: Int?
    let htmlUrl: String
}

struct ReviewState: Codable {
    let state: String       // "APPROVED" | "CHANGES_REQUESTED" | "PENDING" | "COMMENTED"
    let reviewer: String
    let submittedAt: Date?
}

struct PullRequest: Codable {
    let number: Int
    let title: String
    let htmlUrl: String
    let headSHA: String
    let headRef: String
}
```

## Rate Limiting

GitHub allows 5,000 API requests per hour for authenticated PAT users. The app's usage pattern is unlikely to approach this, but the client handles rate limit responses defensively:

- All requests check `X-RateLimit-Remaining` in response headers.
- When `remaining < 50`, the client logs a warning and surfaces a non-blocking indicator in the UI.
- When the API returns `HTTP 429` or `HTTP 403` with a rate limit body, the client reads `X-RateLimit-Reset`, waits until that timestamp, then retries once automatically.
- Aggressive polling (background RFC discovery) backs off to a longer interval when remaining requests are low.

```swift
struct RateLimitState {
    var remaining: Int
    var resetAt: Date
    var isWarning: Bool { remaining < 50 }
    var isExhausted: Bool { remaining == 0 }
}
```

## Error Handling

All `GitHubAPIClient` methods throw `GitHubAPIError`:

```swift
enum GitHubAPIError: Error, LocalizedError {
    case unauthorized               // 401 — PAT invalid or expired
    case forbidden(String)          // 403 — insufficient scope
    case notFound(String)           // 404 — repo/file/PR not found
    case rateLimitExceeded(Date)    // 429/403 rate limit; reset time included
    case unprocessableEntity(String)// 422 — e.g. branch already exists
    case serverError(Int, String)   // 5xx
    case networkError(Error)        // URLSession transport errors
    case decodingError(Error)       // JSON decoding failures
}
```

The UI layer maps these to user-facing messages. `unauthorized` prompts re-entry of PAT in Settings.

## Pagination

GitHub list endpoints paginate at 100 items per page. The client follows `Link: <url>; rel="next"` headers automatically:

```swift
func fetchAllPages<T: Decodable>(initialURL: URL) async throws -> [T]
```

RFC directories rarely exceed 100 files; PR lists are bounded by the `per_page=100` maximum. The auto-pagination implementation handles edge cases but is not expected to trigger in practice.

## Caching Strategy

The client is an `actor` (Swift concurrency). It maintains an in-memory session cache:

```swift
private var rfcContentCache: [String: (content: String, fetchedAt: Date)] = [:]
private let contentCacheTTL: TimeInterval = 300 // 5 minutes
```

RFC list endpoints are not cached — they always reflect the live GitHub state. RFC file content (expensive to decode and render) is cached per `{path}:{ref}` key for 5 minutes. A manual pull-to-refresh invalidates the cache.

## Future Migration to Hermit Backend

When the Hermit Go server is ready, the migration path is:

1. Add `HermitClient.swift` implementing the same method signatures as `GitHubAPIClient`.
2. Change `AIProviderFactory` and view models to resolve `HermitClient` instead of `GitHubAPIClient` when a server URL is configured.
3. Remove `GitHubAPIClient` methods that are now handled server-side (comment sync, PR discovery with label filtering, etc.).
4. `GitHubAPIClient` is retained only for RFC creation (branch/commit/PR), which the Hermit server may or may not absorb.

This migration is a pure implementation swap behind the existing interface — no view changes required.

# Drawbacks

- Direct GitHub API coupling means any breaking change to the GitHub API affects the native app immediately (no server-side adapter layer).
- Creating PR review comments via the REST API requires a `commit_id` and `path` — the app must track the head SHA of the PR at the time the user is reading it to create well-formed comments. If the PR is updated while the user is reading, the SHA becomes stale and GitHub will reject the comment. The app must detect this and prompt the user to refresh.
- The GitHub REST API does not expose thread resolution — only the GraphQL API does. The app posts a "✓ Resolved" reply as a workaround, consistent with the existing Go server behaviour.

# Alternatives

## Alternative 1: Use GitHub GraphQL API

GraphQL provides richer data access (e.g. real thread resolution) in fewer round trips. However, it is more complex to build, type, and test in Swift. The REST API covers all required use cases adequately.

## Alternative 2: Cache to local SQLite

Persist the RFC catalog and comment state to an on-device SQLite database for offline access. Adds complexity and a synchronisation problem. Deferred to a future RFC.

# Adoption Strategy

`GitHubAPIClient` is internal to `hermit-native/`. It is not exposed as a framework. Engineers building the native app work within this client layer from day one.

# Unresolved Questions

- Should the PAT be shared with the web UI / Go server config, or is it a separate PAT issued for the native app? Recommendation: separate PAT scoped minimally to required permissions.
- How should the app handle GitHub Enterprise (custom base URL)? The `GitHubAPIClient` should accept a configurable `baseURL` parameter defaulting to `https://api.github.com`.

# Future Possibilities

- OAuth device flow as an alternative to PAT, allowing engineers to sign in via browser rather than copy-pasting tokens.
- GitHub App authentication for organisations that prefer not to issue PATs.
