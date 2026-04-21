---
title: Hermit High-Level Design and Architecture
status: Draft
author: Steven Taylor
created: 2026-04-21T00:11:45Z
tags: [architecture, design, github, monolith, rfc]
id: rfc-001
project_id: hermit
doc_uuid: fde66c9e-108a-472f-9b99-25c95ff73bca
---

# Summary

This RFC defines the high-level design for Hermit as a Go-based monolith that delivers Google Docs-like RFC collaboration while using GitHub as the system of record. Hermit provides a document-first UI for single-file RFC PR review, inline commenting, and in-app approval actions, and synchronizes those actions with GitHub PR comments and review state.

# Motivation

The PRD and ADRs establish that Hermit must make RFC collaboration easier than native code-centric PR review while preserving governance and traceability in GitHub.

Specifically, the system must support:

- Single markdown file RFC submission and validation.
- Rendered markdown from the PR head branch.
- Inline comments that feel like document comments.
- Bi-directional synchronization of comments, resolution state, and approvals.
- Direct approval actions from Hermit GUI.

This RFC translates those product and architecture decisions into an implementable system blueprint.

# Detailed Design

Hermit is implemented as a modular monolith with clear internal boundaries. All modules are compiled and deployed as one application binary.

## System Components

- Web UI: document-first RFC reading and commenting interface.
- API layer: authenticated endpoints for RFC metadata, comment actions, and approval actions.
- GitHub integration module: API clients and webhook handlers for PRs, comments, and reviews.
- Markdown rendering module: renders RFC markdown from the PR head SHA into a stable display model.
- Anchoring module: maps UI selections to anchors (line, range, text fingerprint) and reattaches anchors after content changes.
- Comment service: manages Hermit thread state and links each thread to GitHub thread identifiers.
- Review service: exposes PR review status and sends approve/request-changes actions to GitHub.
- Sync engine: handles outbound writes, inbound webhook updates, retries, and reconciliation.
- Persistence layer: stores cached projections, anchors, sync events, and local metadata (non-canonical).

## Architectural Principles

- GitHub is canonical for PR state, review decisions, and authoritative comment thread lifecycle.
- Hermit local state is projection and cache; reconciliation resolves to GitHub truth.
- Internal module boundaries in the monolith are explicit to preserve future extraction options.
- All write operations to GitHub are idempotent where possible and include correlation IDs for tracing.

## Primary Workflows

### 1) RFC Intake and Eligibility

1. User selects a repository and PR.
2. Hermit validates the PR diff includes exactly one markdown file (FR-1).
3. If valid, Hermit creates/updates RFCDocument projection keyed by repo, PR number, file path, and head SHA.
4. If invalid, Hermit blocks collaboration workflow and returns actionable error details.

### 2) Render and Read Experience

1. Renderer fetches markdown content for the RFC file at the PR head commit.
2. Renderer converts markdown into a structured render model and HTML output.
3. UI displays rendered RFC with comment markers and side panel thread navigation.

### 3) Inline Comment Creation and Sync

1. Reviewer selects text or position in rendered RFC.
2. Anchoring module creates normalized anchor payload (line hints + text fingerprint).
3. Hermit creates local thread/message records in pending-sync state.
4. Sync engine posts comment thread/message to corresponding GitHub PR context.
5. On success, local records store linked GitHub thread/comment IDs and move to synced state.

### 4) Resolution and Reconciliation

1. User resolves or reopens a comment in Hermit.
2. Hermit sends equivalent update to GitHub when API semantics allow.
3. Webhook events update local projections.
4. If conflicts occur, Hermit applies GitHub canonical state and annotates sync log.

### 5) Approvals from Hermit GUI

1. Approver views current GitHub review status in Hermit.
2. Approver submits Approve (or Request Changes in later phase) from Hermit.
3. Hermit posts PR review action to GitHub.
4. Resulting GitHub review state is reflected back in Hermit via immediate response and webhook confirmation.

## API Changes

Initial internal API surface (names illustrative):

- `GET /api/repos/{owner}/{repo}/prs/{number}/rfc`
  - Returns RFC eligibility, file metadata, head SHA, and render readiness.
- `GET /api/repos/{owner}/{repo}/prs/{number}/rfc/render`
  - Returns rendered content and anchor map.
- `GET /api/repos/{owner}/{repo}/prs/{number}/threads`
  - Returns thread list with Hermit and GitHub linkage.
- `POST /api/repos/{owner}/{repo}/prs/{number}/threads`
  - Creates new thread with anchor and initial message.
- `POST /api/repos/{owner}/{repo}/prs/{number}/threads/{threadId}/resolve`
  - Resolves thread and schedules sync.
- `POST /api/repos/{owner}/{repo}/prs/{number}/review/approve`
  - Submits GitHub PR approval on behalf of authenticated approver.
- `POST /api/webhooks/github`
  - Receives GitHub webhook events for PR, comment, and review updates.

## Data Model Changes

Representative entities in monolith datastore:

- `rfc_documents`
  - `repo_owner`, `repo_name`, `pr_number`, `file_path`, `head_sha`, `render_version`, `eligibility_status`.
- `comment_threads`
  - `thread_id`, `rfc_document_id`, `anchor_payload`, `status`, `github_thread_id`, `last_synced_at`.
- `comment_messages`
  - `message_id`, `thread_id`, `author_id`, `body`, `source_system`, `github_comment_id`, `created_at`.
- `review_states`
  - `rfc_document_id`, `github_review_state`, `last_review_event_id`, `updated_at`.
- `sync_events`
  - `event_id`, `entity_type`, `entity_id`, `direction`, `action`, `status`, `attempt_count`, `error`, `created_at`.

Data ownership model:

- GitHub-owned canonical fields: review state, official PR thread state, PR mergeability signals.
- Hermit-owned fields: UI anchor metadata, local projection timestamps, sync diagnostics.

## Migration Strategy

No legacy Hermit system exists. Migration strategy is phased rollout:

1. Phase 0 - Foundation
   - Establish monolith skeleton, GitHub auth, webhook intake, base persistence schema.
2. Phase 1 - MVP collaboration
   - Single-file RFC validation, render view, inline comment create/read, one-way sync to GitHub.
3. Phase 2 - Full sync lifecycle
   - Reconciliation from webhooks, resolve/reopen behavior, robust retry/error handling.
4. Phase 3 - Review actions
   - In-GUI approval submission and synchronized review state indicators.

# Drawbacks

- Monolith centralizes risk if module boundaries degrade over time.
- Dependence on GitHub API semantics may limit idealized document UX behavior.
- Anchor resilience for evolving markdown content is complex and may require iterative tuning.
- Synchronization and reconciliation logic increases implementation complexity for early versions.

# Alternatives

Alternative designs considered against the selected architecture.

## Alternative 1

Microservices-first architecture with separate renderer, sync worker, and API services.

Comparison: better independent scaling but rejected due to significantly higher initial delivery and operational complexity for current product scope.

## Alternative 2

Hermit-managed canonical workflow state with periodic push to GitHub.

Comparison: offers product flexibility but rejected because it conflicts with ADR-003 and introduces unacceptable state divergence and governance ambiguity.

# Adoption Strategy

- Internal dogfood with one repository and selected approvers.
- Publish author/reviewer guidance for Hermit workflow and fallback actions in GitHub.
- Define operational dashboards for sync success, webhook lag, and unresolved thread counts.
- Add release criteria aligned with PRD success metrics before broad rollout.

# Unresolved Questions

- Should Hermit use GitHub App, OAuth App, or a hybrid model for authentication and least-privilege scopes?
- What canonical anchor strategy provides the best tradeoff between precision and resilience on force-push updates?
- Should "Request Changes" and dismissal workflows be included in MVP or post-MVP?
- What is the target behavior when GitHub APIs support comments differently for rendered markdown contexts versus code line comments?

# Future Possibilities

- Extract sync engine into dedicated worker process if throughput or reliability needs increase.
- Add structured approval policies and required reviewer rules surfaced in Hermit UI.
- Support richer comment types (suggestions, checklists, annotation categories).
- Extend beyond RFC markdown to additional doc types once single-file RFC flow is stable.

# Related Documents

- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
- [ADR-001: Adopt Go as the Primary Application Language](../adr/adr-001-golang-base-application.md)
- [ADR-002: Adopt a Single Monolith Application Architecture](../adr/adr-002-single-monolith-application.md)
- [ADR-003: Use GitHub as the Source of Truth](../adr/adr-003-github-source-of-truth.md)
