---
title: RFC Publishing via GitHub API
status: Draft
author: Steven Taylor
created: 2026-04-24T00:00:00Z
tags: [api, github, publishing, pull-request, rfc, rfc-creation]
id: rfc-012
project_id: hermit
doc_uuid: a1b2c3d4-0007-4000-8000-100000000012
---

# Summary

This RFC defines the publishing flow for newly authored RFCs in the Hermit native app. After an engineer completes the AI-assisted interview (rfc-010) and approves the generated draft, the app creates a GitHub branch, commits the RFC markdown file, and opens a pull request with the `hermit:rfc-ready` label — all directly via the GitHub REST API using the engineer's stored PAT. The PR immediately appears in the Hermit RFC list as a reviewable item.

# Motivation

The value of RFC creation (rfc-010) is only realised when the draft reaches reviewers. The publishing step must be automatic and nearly instant — requiring the engineer to manually commit and push would reintroduce exactly the friction the native app is designed to eliminate.

By creating the branch, file, and PR in a single guided flow from the native app, the engineer goes from "idea captured in voice" to "PR open and ready for review" without ever leaving the app or touching a terminal.

# Detailed Design

## Publishing Flow Overview

```text
RFCPreviewView: "Publish as PR"
       ↓
PublishingSession.publish(draft: RFCDraft)
       ↓
1. Determine next RFC number
       ↓
2. Generate file path and branch name
       ↓
3. Get default branch HEAD SHA
       ↓
4. Create feature branch
       ↓
5. Commit RFC file to branch
       ↓
6. Ensure hermit:rfc-ready label exists
       ↓
7. Create pull request
       ↓
8. Add label to PR
       ↓
PublishingResult: { prNumber, prURL, rfcPath }
       ↓
UI: success toast + RFC list refreshes + new RFC highlighted
```

## Step 1: Determine Next RFC Number

The RFC numbering scheme is `rfc-NNN` where NNN is zero-padded to three digits. The next number is determined by listing the RFC directory on the default branch and finding the highest existing number:

```swift
// Sessions/PublishingSession.swift
func nextRFCNumber(owner: String, repo: String, docsPath: String) async throws -> Int {
    let files = try await githubClient.listRFCDirectory(
        owner: owner, repo: repo, docsPath: docsPath, ref: "heads/main"
    )
    // files: ["rfc-001-design.md", "rfc-005-labels.md", ...]
    let numbers = files.compactMap { filename -> Int? in
        guard let match = filename.firstMatch(of: /^rfc-(\d{3})-/) else { return nil }
        return Int(match.output.1)
    }
    return (numbers.max() ?? 0) + 1
}
```

**Collision risk**: if two engineers publish concurrently, both may calculate the same next number. Mitigated by the fact that GitHub will reject the second `PUT /contents/{path}` with a `422` if the file already exists (no `sha` provided on create). The app detects this, re-fetches the directory, increments to the next available number, and retries once. If the retry also collides, an error is surfaced asking the engineer to retry manually.

## Step 2: File Path and Branch Name

```swift
struct RFCDraft {
    let title: String
    let markdownContent: String
    let author: String
}

func deriveFileInfo(draft: RFCDraft, number: Int, docsPath: String) -> (path: String, branch: String) {
    let slug = draft.title
        .lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .replacingOccurrences(of: #"[^a-z0-9-]"#, with: "", options: .regularExpression)
        .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        .prefix(50)  // cap slug length

    let paddedNumber = String(format: "%03d", number)
    let filename = "rfc-\(paddedNumber)-\(slug).md"
    let path = "\(docsPath.hasSuffix("/") ? docsPath : docsPath + "/")\(filename)"
    let date = ISO8601DateFormatter().string(from: Date()).prefix(10)  // YYYY-MM-DD
    let branch = "rfc/\(paddedNumber)-\(slug)-\(date)"

    return (path: path, branch: String(branch))
}
```

Example output for title "Native Swift App for Hermit":
- Filename: `rfc-006-native-swift-app-for-hermit.md`
- Path: `docs-cms/rfcs/rfc-006-native-swift-app-for-hermit.md`
- Branch: `rfc/006-native-swift-app-for-hermit-2026-04-24`

## Step 3: Get Default Branch HEAD SHA

```swift
// GET /repos/{owner}/{repo}/git/ref/heads/{defaultBranch}
// Response: { object: { sha: "abc123..." } }
let headSHA = try await githubClient.getDefaultBranchSHA(owner: owner, repo: repo, branch: "main")
```

## Step 4: Create Feature Branch

```swift
// POST /repos/{owner}/{repo}/git/refs
// body: { ref: "refs/heads/{branch}", sha: "{headSHA}" }
try await githubClient.createBranch(owner: owner, repo: repo, branchName: branch, fromSHA: headSHA)
```

If the branch already exists (duplicate slug same day), a timestamp suffix is appended: `rfc/006-native-swift-app-2026-04-24-143022`.

## Step 5: Commit RFC File

```swift
// PUT /repos/{owner}/{repo}/contents/{path}
// body: {
//   message: "docs: add rfc-006 native swift app for hermit",
//   content: base64(markdownContent),
//   branch: branch
// }
let commitSHA = try await githubClient.commitFile(
    owner: owner,
    repo: repo,
    path: path,
    content: markdownContent,
    message: "docs: add \(filename.dropLast(3))",  // strip .md
    branch: branch
)
```

The file content is base64-encoded as required by the GitHub Contents API. The commit message follows Conventional Commits format (`docs: add rfc-NNN-slug`).

## Step 6: Ensure Label Exists

The `hermit:rfc-ready` label must exist in the repository for the discovery mechanism (rfc-006) to work:

```swift
// GET /repos/{owner}/{repo}/labels/hermit%3Arfc-ready
// 404 → POST /repos/{owner}/{repo}/labels
//        body: { name: "hermit:rfc-ready", color: "0075ca", description: "RFC ready for Hermit review" }
try await githubClient.ensureLabelExists(
    owner: owner, repo: repo,
    label: "hermit:rfc-ready",
    color: "0075ca"
)
```

This is a cheap idempotent check — the `GET` succeeds in ~1 round trip after the first RFC is published.

## Step 7: Create Pull Request

```swift
// POST /repos/{owner}/{repo}/pulls
// body: {
//   title: "{rfcTitle}",
//   body: "{prBody}",
//   head: "{branch}",
//   base: "main",
//   draft: false
// }
let pr = try await githubClient.createPullRequest(
    owner: owner,
    repo: repo,
    title: draft.title,
    body: generatePRBody(draft: draft),
    head: branch,
    base: "main",
    labels: []  // labels added separately (step 8)
)
```

PR body is generated from the RFC's Summary section:

```swift
func generatePRBody(draft: RFCDraft) -> String {
    // Extract first paragraph after "# Summary" heading from markdownContent
    // Append: "\n\n---\n_Created with Hermit native app_"
}
```

## Step 8: Add Label to PR

```swift
// POST /repos/{owner}/{repo}/issues/{prNumber}/labels
// body: { labels: ["hermit:rfc-ready"] }
try await githubClient.addLabels(
    owner: owner, repo: repo,
    issueNumber: pr.number,
    labels: ["hermit:rfc-ready"]
)
```

The PR API does not support labels on creation for all plan types; adding them via the Issues API post-creation is the reliable path.

## PublishingSession

```swift
// Sessions/PublishingSession.swift
@MainActor
class PublishingSession: ObservableObject {
    enum State {
        case idle
        case numbering       // "Finding next RFC number..."
        case branching       // "Creating branch..."
        case committing      // "Committing RFC file..."
        case openingPR       // "Opening pull request..."
        case labelling       // "Applying hermit:rfc-ready label..."
        case done(PullRequest)
        case failed(Error)
    }

    @Published var state: State = .idle
    @Published var progressMessage: String = ""

    func publish(draft: RFCDraft, owner: String, repo: String, docsPath: String) async {
        // Drives steps 1-8, updating state at each transition
        // Each step updates progressMessage for display in PublishingView
    }
}
```

## Publishing UI

`PublishingView.swift` presents as a sheet over `RFCPreviewView`:

```text
┌────────────────────────────────────────────┐
│ Publishing RFC...                          │
│                                            │
│  ✓ RFC number determined   (rfc-006)       │
│  ✓ Branch created                          │
│  ⟳ Committing file...                      │
│  ○ Opening pull request                    │
│  ○ Applying label                          │
│                                            │
│  [Cancel]                                  │
└────────────────────────────────────────────┘
```

On success, transitions to:

```text
┌────────────────────────────────────────────┐
│  ✓ RFC Published                           │
│                                            │
│  rfc-006 Native Swift App for Hermit       │
│  PR #73 is open and ready for review       │
│                                            │
│  [View in Hermit]   [Open on GitHub ↗]    │
└────────────────────────────────────────────┘
```

"View in Hermit" dismisses the sheet and navigates the RFC list to the newly created PR-backed RFC, which now appears with the `hermit:rfc-ready` label and is immediately commentable.

On failure, the error is shown with a "Retry" button. Steps already completed are not re-executed (idempotent by design — if the branch was created before a failure, the retry will receive a `422` on branch creation, handle it gracefully, and continue from the commit step).

## Frontmatter Generation

The RFC markdown generated by the AI (rfc-010) includes frontmatter. The publishing session validates and enriches it before committing:

```swift
func enrichFrontmatter(markdown: String, number: Int, author: String, path: String) -> String {
    // Parse existing frontmatter (YAML between --- delimiters)
    // Set/override:
    //   id: rfc-{NNN}
    //   author: {author from Keychain or GitHub username}
    //   created: {ISO8601 now}
    //   status: Draft
    //   project_id: hermit
    //   doc_uuid: {UUID().uuidString}
    // Re-serialise and prepend to markdown body
}
```

## Error Handling

| Error | Recovery |
|---|---|
| RFC number collision (422) | Re-fetch directory, increment, retry once |
| Branch already exists (422) | Append timestamp suffix to branch name, retry |
| Insufficient PAT scope (403) | Alert: "Your PAT does not have `contents:write` permission. Update it in Settings." |
| Network error | Retry button; steps completed are safe to re-run |
| PR creation fails — base branch not found | Alert with branch name for manual recovery |

# Drawbacks

- The app creates one commit per RFC file. There is no way to amend or rebase from the native app. If the engineer wants to revise before opening the PR, they must edit the file via the web or terminal.
- The `contents:write` scope required for file creation is powerful — it grants write access to the entire repository tree, not just the RFC docs path. Engineers should use a dedicated PAT scoped to the RFC repository only.
- RFC number assignment is eventually consistent across concurrent users. The collision retry handles the common case but does not eliminate the theoretical race.

# Alternatives

## Alternative 1: Draft PR by Default

Create the PR as a draft (`draft: true`) rather than an open PR, so the engineer must manually mark it ready for review on GitHub. This is safer but contradicts the goal of instant reviewability. Rejected — the `hermit:rfc-ready` label already controls Hermit's discovery independently of GitHub's draft state; engineers can convert back to draft on GitHub if needed.

## Alternative 2: New Hermit Server Endpoint

Add a `POST /api/v1/rfcs` endpoint to the Go server that accepts a markdown body and creates the branch/PR server-side. The native app calls this endpoint instead of GitHub directly. Cleaner separation but blocks on server development. Deferred — when the server exists, this endpoint is the right long-term home for this logic.

# Adoption Strategy

Publishing is the final step of the RFC creation flow and requires no configuration beyond the existing PAT (with `contents:write` scope). Engineers who only need to read and comment do not need the additional PAT scope.

# Unresolved Questions

- Should the app allow editing the PR title and body before submission? Yes — a text field above the "Publish as PR" button in `RFCPreviewView` allows overriding the auto-generated PR title. The PR body is always auto-generated from the Summary section.
- Should the RFC number be derived from the PR number instead of the file listing? Using the file listing is more predictable (numbers are stable even if PRs are closed/reopened) but has the collision risk described above. Using PR numbers would require opening the PR before knowing the number, creating a circular dependency.
- Should the app support pushing updates to an existing RFC draft (additional commits to the same branch)? Yes, but deferred. The initial implementation supports new RFC creation only.

# Future Possibilities

- In-app editing of the committed RFC: after publishing, allow the engineer to edit the markdown and push an additional commit to the branch from within the app.
- PR templates: if the repository has a `.github/PULL_REQUEST_TEMPLATE.md`, incorporate it into the generated PR body.
- Automatic reviewer suggestions: after PR creation, use the GitHub API to suggest reviewers based on `CODEOWNERS` or recent contributors to the RFC directory.