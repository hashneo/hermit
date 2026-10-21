---
title: Hermit Product Vision
status: Draft
author: Steven Taylor
created: 2026-04-20T23:55:40Z
updated: 2026-10-21T00:00:00Z
target_release: v1.0.0
tags: [collaboration, documents, github, product, pull-requests]
id: prd-001
project_id: hermit
doc_uuid: 3153e2fa-2287-4d1a-9e25-2e7272547996
---

# Executive Summary

Hermit is a desktop workspace for a team's documents and the pull requests that
carry them. GitHub is the source of truth for both. Hermit does two things and
treats both as first-class:

1. **Documents.** Create, find, read and review the team's working documents.
   Documents can be created quickly with a coding agent through an MCP server,
   or through a chat interface in the app. ADRs, RFCs and PRDs go through
   review and approval as rendered documents, with inline comments that behave
   like Google Docs comments and map to GitHub PR comments. Users see all
   documents, grouped by type and status, in a menu on the desktop.
2. **Pull requests.** Triage the open pull requests waiting on you across many
   repositories in one inbox, and act on them quickly. Document pull requests
   are opened in Hermit's document view. Every other pull request is approved
   inline or opened on GitHub.

The two meet in the inbox, so Hermit keeps them clearly apart: a *document
review* happens in Hermit, and a *standard review* of any other pull request is
handled with an inline approval or on GitHub. Review and approval of documents
stay GUI driven, through the toolbars on the documents themselves.

Document types and templates come from
[Docuchango](https://github.com/jrepp/docuchango). Hermit starts with these:

```text
├── adr/     # Architecture Decision Records
├── rfcs/    # Requests for Comments
├── memos/   # Findings, plans, status notes
├── prd/     # Product Requirements Documents
```

# Problem Statement

**Pull requests.** Reviewers who work across many repositories have no quick way
to see every open pull request waiting on them, or to act on one without
opening its repository. A list that mixes document reviews with ordinary code
reviews is also easy to misread: the actions mean different things, and a
document reviewed through GitHub's code view loses the document-first
experience.

**Documents.** Teams review ADRs, RFCs and PRDs in GitHub PRs, but the native
experience is code-centric. Long-form markdown is hard to read as a narrative,
and discussion threads do not feel like collaborative writing. Product, design
and engineering stakeholders need a document-first review workflow that keeps
GitHub governance.

Creating documents is high friction. Starting from a blank template while
context-switched from other work means fewer documents get written. Coding
agents already hold the context for a decision or a finding, but there is no
direct path from that context to a correctly formatted document and a review
PR.

Teams also lose track of what exists. There is no single place to see every
ADR, RFC, PRD and memo with its status, without browsing repository trees and
PR lists.

# Goals and Objectives

## Primary Goals

Pull requests:

- Give reviewers one inbox of open pull requests across repositories.
- Let a reviewer approve a standard pull request inline.
- Make a document review and a standard review unmistakably different.

Documents:

- Support the document types configured for a repository, starting with ADR,
  RFC, memo and PRD.
- Let a user or a coding agent create a new document quickly through an MCP
  server or an in-app chat.
- Run ADRs, RFCs and PRDs through PR-based review and approval, with one
  document per PR.
- Render markdown from the PR branch in a document-first reading view, with
  inline, anchored comments that synchronize with GitHub PR comments and
  resolution state.
- Give users a desktop menu that shows all documents grouped by type and status.
- Keep review and approval GUI driven, through toolbars on the document.

## Success Metrics

Existing metrics, now applying to every reviewed document type:

- Metric 1: 95% of document PRs submitted through Hermit contain exactly one
  document.
- Metric 2: 90% of comments created in Hermit are mirrored to GitHub PR comments.
- Metric 3: 90% of mirrored comment resolution state changes remain consistent
  between Hermit and GitHub.
- Metric 4: Median comment-to-resolution time improves by 30% compared with a
  PR-only baseline.

New metrics, targets to be set before the beta:

- Metric 5: Time from "start a document" to an open review PR, for agent-created
  and chat-created documents.
- Metric 6: Share of agent- and chat-created documents that pass
  `docuchango validate` without manual correction.
- Metric 7: Time for a user to find a specific document through the desktop menu.
- Metric 8: Time for a reviewer to triage and act on the open pull requests
  waiting on them, and the share of rows they correctly identify as a document
  review or a standard review.

# User Stories

## As a document author

- I want to describe an idea or decision to my coding agent or to the in-app
  chat and get a correctly formatted ADR, RFC, PRD or memo.
- So that I can start a review without filling in a blank template.

## As a coding agent

- I want an MCP server that exposes document creation, validation and
  submission for the supported types.
- So that I can write up a decision or finding from the context I already have.

## As a document reviewer

Reviewing an ADR, RFC or PRD that is open in a pull request.

- I want to read the rendered document and leave inline comments anchored to the
  exact text I mean.
- So that the author gets clear feedback they can act on quickly, and the
  discussion stays in the pull request.

## As a document approver

Approving or rejecting an ADR, RFC or PRD.

- I want to approve or request changes from the toolbar on the document, after
  reading it.
- So that I can finish a document review without switching to GitHub.

## As any team member

- I want a desktop menu of all documents grouped by type and status.
- So that I can see what exists and what needs attention without browsing
  repositories or PR lists.

## As an engineering manager

Tracking a document pull request toward merge.

- I want comments, resolution and review state in Hermit to match the pull
  request on GitHub.
- So that merge readiness is transparent and auditable.

## As a reviewer with pull requests across many repositories

Working through my open pull requests of every kind.

- I want one list of every open pull request waiting on me, with each row clearly
  marked as a document review or a standard pull request.
- So that I can clear my queue without opening each repository, and without
  mistaking one kind of review for the other.

## As the approver of a standard pull request

Approving a pull request that is not a document, such as a code change.

- I want to approve it from the inbox row, after seeing its size and CI state.
- So that I can unblock the author quickly, with the detailed review done on
  GitHub when I need it.

# Requirements

## Terminology: Two Kinds of Review

Hermit distinguishes two kinds of review, and the product must never blur them.

| | Document review | Standard review |
|---|---|---|
| What | One ADR, RFC or PRD, plus allowlisted companion files (FR-1) | Any other open pull request |
| Opens in | Hermit's rendered document view | The pull request on GitHub |
| Comments | Anchored inline comments mirrored to GitHub threads (FR-3, FR-4) | Not in Hermit |
| Approval | Document toolbar only (FR-9, FR-11) | Inline from the inbox row (FR-D5) |
| State tracked | Threads, resolution, review state (FR-6, FR-10) | Review decision only |

The word "Review" is never used alone in the interface. A document review is
labelled "Document review" and a standard review "Pull request".

## Document Types

| Type | Folder | Review and approval | Status values |
|------|--------|---------------------|---------------|
| ADR | `adr/` | Yes, through PR | Docuchango ADR statuses (template default: Proposed) |
| RFC | `rfcs/` | Yes, through PR | Docuchango RFC statuses (template default: Draft) |
| PRD | `prd/` | Yes, through PR | Docuchango PRD statuses (template default: Draft) |
| Memo | `memos/` | No. Create and browse only. | None in the Docuchango memo template |

Document discovery, filename conventions and validation follow ADR-004 and the
repository's `docs-project.yaml`. Types beyond these four are added through
Docuchango configuration, not Hermit code.

## Functional Requirements

### Authoring

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-A1 | Hermit must provide an MCP server, delivered as a `hermit mcp` subcommand of the Hermit binary, that lets a coding agent create a document of any supported type from its Docuchango template. The subcommand is a thin stdio shim over the running Hermit server's API and holds no credentials. HTTP transport for remote or shared servers follows later. | Must Have |
| FR-A2 | Hermit must provide an in-app chat interface that creates a document of any supported type. It is delivered after FR-A1. It uses a provider abstraction: on-device models by default where available, an optional bring-your-own-key provider, and a plain template form with no AI when neither is available. | Must Have |
| FR-A3 | Created documents must pass Docuchango validation: filename convention, required frontmatter, and a unique id and document uuid. | Must Have |
| FR-A4 | Submitting a created ADR, RFC or PRD must open a PR containing exactly that one document. | Must Have |
| FR-A5 | Author review of a generated draft must precede submission. An agent or chat must not publish a document without user confirmation. | Must Have |

### Document review and approval

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-1 | Hermit must accept a review submission only when the PR diff contains exactly one Docuchango document of a reviewable type (ADR, RFC or PRD), plus companion files from an allowlist: the review-session marker under `.hermit/reviews/` and Docuchango index and changelog files. Any other changed file makes the PR ineligible for the review list. | Must Have |
| FR-2 | Hermit must render markdown from the PR branch version of the document, not the base branch. | Must Have |
| FR-3 | Document reviewers must be able to create inline comments anchored to sections, lines or text ranges in the rendered view. | Must Have |
| FR-4 | Every Hermit comment must create or map to a GitHub PR comment thread. | Must Have |
| FR-5 | Hermit must display comment threads in context and provide a document-style side panel for navigation. | Should Have |
| FR-6 | Users must be able to resolve and reopen comments from Hermit, synchronized with GitHub where supported. | Must Have |
| FR-7 | Hermit must reflect GitHub comment updates (replies, edits, resolution state) within a short sync window. | Should Have |
| FR-8 | Hermit must show merge readiness by surfacing the unresolved comment count for the document. | Should Have |
| FR-9 | Document approvers must be able to submit GitHub PR approval from the document toolbar. | Must Have |
| FR-10 | Hermit must display the current PR review state (approved, changes requested, pending) and keep it synchronized with GitHub. | Must Have |
| FR-11 | Review actions must be available through the toolbars on the document view, not from document menu or inbox rows. | Must Have |
| FR-12 | Authors may edit the document, including force-pushes, while it is under review. Hermit must re-anchor each comment after the head changes: match the text fingerprint first, then the line hint. A comment that cannot be reattached confidently stays visible in the comments panel with its original quoted text, labelled outdated. A low-confidence match is shown as moved and needs user confirmation. Hermit must never drop a thread. | Must Have |
| FR-13 | When Hermit and GitHub disagree on comment or review state, GitHub wins (ADR-003). Hermit shows an optimistic pending-sync state until GitHub confirms, and records the conflict in the event log. | Must Have |
| FR-14 | A merged document can be reviewed again only by an explicit user action that opens a review-session PR (RFC-005). When Hermit sees a reviewed document's PR merge, it sets the document's `reviewed` label. | Should Have |
| FR-15 | Hermit must allow read-only access to public repositories without a PAT. Writes, including comments, approvals and document creation, always require a PAT. Unauthenticated provider traffic must be rate limited and cached (ADR-010). | Should Have |

### Document menu

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-M1 | The desktop app must provide a drop-down menu listing all documents across configured repositories. | Must Have |
| FR-M2 | The menu must group documents by type, and within each ADR, RFC and PRD group by lifecycle status. Memos form their own group with no status grouping. Review state (needs review, changes requested, approved) appears as a badge on a document, not as a grouping. | Must Have |
| FR-M3 | Selecting a document must open it in the rendered document view. | Must Have |
| FR-M4 | The menu must show documents from the default branch and documents under review in open PRs. | Should Have |
| FR-M5 | The menu must show when its data is cached or failed to refresh. | Should Have |

### Pull request inbox

| ID | Requirement | Priority |
|----|-------------|----------|
| FR-D1 | The desktop app must provide an inbox listing open pull requests across all configured repositories. Merged and closed pull requests do not appear in it. | Must Have |
| FR-D2 | The inbox must show two visually distinct kinds of row. A document review row shows the document title, type, lifecycle status, unresolved-thread count and review state, with one primary action, "Open document". A standard row shows the pull request title, repository, author, size and CI or merge state, with the actions "Approve" and "Open on GitHub". | Must Have |
| FR-D3 | Every row must carry a kind label and icon, and the two kinds must be grouped into separate sections. The two kinds must never present the same button label or the same action. | Must Have |
| FR-D4 | A row is a document review only when the pull request passes FR-1. Any other pull request, including a code change that happens to touch one document, is a standard row. | Must Have |
| FR-D5 | Approving a standard pull request inline must submit a GitHub approval through the Hermit API (ADR-007, ADR-009), reusing the existing pull request approval operation, and requires a PAT. Document review rows never offer inline approval. | Must Have |
| FR-D6 | The inbox must order rows by whether the pull request is waiting on the current user (requested reviewer or review requested), then by age. Any count shown must state its unit, for example "7 documents, 9 pull requests". | Should Have |
| FR-D7 | The inbox must show per-repository data health: loaded, cached, or failed to refresh, with a recovery action. | Should Have |
| FR-D8 | A merged document that needs another review must not appear in the inbox. It is reached from the document menu through an explicit new review (FR-14). | Must Have |

The inbox is for acting on open pull requests. The document menu (FR-M1 to
FR-M5) is for finding documents by type and status. They share data but not a
purpose.

## Non-Functional Requirements

| ID | Requirement | Target |
|----|-------------|--------|
| NFR-1 | Markdown rendering latency | First render < 2s for documents up to 10,000 words |
| NFR-2 | Comment sync reliability | 99.5% successful sync operations over 30 days |
| NFR-3 | Sync freshness | Remote updates visible in Hermit within 10 seconds median |
| NFR-4 | Availability | 99.9% monthly uptime for collaboration features |
| NFR-5 | Security and permissions | GitHub auth scopes limited to required PR and comment operations. Anonymous access is read-only on public repositories (FR-15). |
| NFR-6 | Agent safety | The MCP server and chat interface must not expose credentials to the model or write outside the document and PR operations above. |

# Design

## User Interface

- **Document view.** A central rendered markdown surface for long-form reading,
  inline comment markers at anchored positions, and a comments panel with open
  and resolved threads. Review state, unresolved count and sync state appear as
  badges. Approve, request-changes and resolve actions live in the document
  toolbar.
- **Document menu.** A desktop drop-down with documents grouped by type and
  status. It is for finding and opening documents, not for performing review
  actions.
- **Pull request inbox.** A cross-repository list of open pull requests in two
  sections. Document reviews come first, each row led by the document title and
  its review state. Standard pull requests follow, each row led by the PR title
  and showing size, CI state and an inline Approve. Descriptions, diff
  statistics and file counts are secondary detail, not the primary content of a
  row.
- **Authoring chat.** An in-app conversational interface that asks for the
  content a document type needs, produces a draft for the author to review, and
  submits it as a PR. This builds on RFC-010 (AI-assisted authoring), RFC-011
  (voice) and RFC-012 (publishing through the GitHub API).

## Technical Architecture

- GitHub PAT authentication per ADR-005, behind the Hermit API per ADR-007 and
  ADR-009.
- Docuchango project discovery and validation per ADR-004 and ADR-011.
- PR discovery and commentable state through labels per ADR-008 and RFC-005.
- A Hermit MCP server that exposes document creation, validation and submission
  through the same Hermit API the apps use.
- A renderer that fetches markdown from the PR head commit.
- A comment anchor model that maps rendered content to source locations.
- Bidirectional synchronization between Hermit threads and GitHub PR threads,
  with an event log for audit.

## Data Model

Core entities:

- Document: repository, type, path, id, status, PR number (if under review),
  head SHA, rendered snapshot metadata.
- CommentThread: thread ID, anchor metadata, author, status, linked GitHub
  thread ID.
- CommentMessage: body, author, timestamp, source system, edit history.
- SyncEvent: event type, direction, status, retries, error details.

# Out of Scope

- Multi-document submissions in a single review PR.
- Non-markdown document formats.
- Rendering or commenting on code diffs. Standard pull requests get an inline
  approval and a link to GitHub, nothing more.
- Real-time collaborative editing of the markdown source.
- Review and approval of memos. Memos are created and browsed only.
- Blocking force-pushes. Hermit cannot enforce this; branch protection can.

# Dependencies

- Docuchango document types, templates and validation.
- GitHub authentication and API access for PRs and review comments.
- Markdown rendering compatible with GitHub-flavored markdown.
- Background or event-driven infrastructure for comment synchronization.
- A model and tool-calling path for the in-app chat, and an MCP server
  implementation, neither of which exists in the repository today.
- Product design input for anchor UX and the document menu.

# Timeline

To be re-planned. The original milestones (MVP 2026-07-01, v1.0.0 launch
2026-09-02) have passed, and the scope has changed. A new schedule should follow
the resolution of the open questions below.

# Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Anchor drift when markdown changes significantly between comments | High | Resilient anchor strategy combining text ranges, line hints and fuzzy reattachment |
| GitHub API rate limits during high collaboration periods | High | Batch sync, backoff and retry, queue-based throttling (ADR-010) |
| Ambiguity between Hermit resolution and GitHub thread models | Medium | Canonical state machine and reconciliation rules; GitHub is canonical per ADR-003 |
| Reviewer adoption friction compared with the GitHub UI | Medium | Deep links between Hermit threads and GitHub PR threads |
| Agent-created documents are low quality or invalid | Medium | Template-driven creation, Docuchango validation before submission, mandatory author confirmation (FR-A5) |
| Agent access leaks credentials or writes too broadly | High | MCP tools limited to document operations; credentials stay in the Hermit server (NFR-6) |
| Document menu duplicates the PR-centric inbox | Medium | Different jobs: the menu finds documents by type and status, the inbox acts on open pull requests (FR-D1 to FR-D8) |
| Users confuse a document review with a standard review | High | Separate sections, kind labels and icons, different button labels, and a rule that "Review" is never used alone (FR-D2, FR-D3) |
| Inline approval of a standard pull request without reading it | Medium | Show size, CI state and requested-reviewer status on the row, and apply an approval guard once the open question below is decided |
| Anonymous reads exhaust the unauthenticated GitHub rate limit (60 requests per hour per IP) | Medium | Serve anonymous reads from the ADR-010 cache and queue, and cap upstream calls per anonymous session |
| Fuzzy re-anchoring attaches a comment to the wrong paragraph | Medium | Attach only on a confident match; otherwise show the comment as moved and ask the user to confirm (FR-12) |
| PRD-001 and ADR-005 disagree on authentication (anonymous read vs PAT only) | Low | Amend ADR-005 to allow anonymous read on public repositories before implementing FR-15 |

# Open Questions

- What is the full list of lifecycle statuses for ADR, RFC and PRD in
  Docuchango, and how does each map to a menu group? Review state is a separate
  badge driven by labels and PR review decision.
- What confidence threshold decides between an automatic re-anchor and a
  "moved, please confirm" comment (FR-12)?
- Which tools does the `hermit mcp` subcommand expose beyond create, validate and
  submit, and how does it find the running Hermit server?
- Which on-device and bring-your-own-key providers does the in-app chat support
  at launch?
- What caps apply to anonymous read sessions (FR-15)?
- What guards apply to inline approval of a standard pull request: a size cap,
  green CI, a confirmation step, or none?
- How is "waiting on me" computed from GitHub data (requested reviewer, team
  review requests, mentions), and what if the signal is unavailable?
- Do draft pull requests appear in the inbox?
- Should the inbox include repositories the user has not configured in Hermit,
  such as every repository in an organization?
- Should standard rows also offer request changes inline, or only approve?

## Decided

- The inbox lists all open pull requests across repositories, and makes the
  difference between a document review and a standard review unmistakable.
- Inline approval is offered only for standard pull requests. Document reviews
  are approved from the document toolbar.
- Merged and closed pull requests are not in the inbox.
- Memos are create and browse only, with no review states.
- Review state and lifecycle status are separate axes.
- The MCP server is a `hermit mcp` subcommand, and the in-app chat follows it.
- GitHub wins on state conflicts (ADR-003).
- A merged document is reviewed again through an explicit review-session PR.
- Review PRs contain one document plus an allowlist of companion files.
- Authors can edit during review, and Hermit re-anchors comments without ever
  dropping a thread.
- Anonymous read-only access to public repositories is allowed.

# Appendix

Vision statement:

Hermit is a desktop workspace for a team's documents and the pull requests that
carry them. Reviewers triage the open pull requests waiting on them across
repositories in one inbox, where document reviews and standard reviews are
clearly separate, and standard pull requests can be approved inline. Documents
(initially ADRs, RFCs, memos and PRDs) can be created quickly with coding agents
through an MCP server or an in-app chat. ADRs, RFCs and PRDs flow through review
and approval using GitHub PRs, and users can see all documents, grouped by type
and status, in a desktop menu. Review and approval of documents remain GUI
driven through the toolbars on the documents.

Previous vision (April 2026): take an RFC document, submit it as a single-file
PR, and let GitHub users comment on it as though it was a Google document.
