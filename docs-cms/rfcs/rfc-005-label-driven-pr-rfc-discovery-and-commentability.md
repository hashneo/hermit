---
title: Label-Driven PR RFC Discovery and Commentability
status: Draft
author: Steven Taylor
created: 2026-04-21T19:33:49Z
tags: [github, labels, review, rfc, workflow]
id: rfc-005
project_id: hermit
doc_uuid: 825f3864-e1ad-43c5-9594-0b47391a950a
---

# Summary

This RFC proposes a label-driven workflow for discovering commentable docs-cms documents in pull requests. Hermit will use explicit GitHub labels as a workflow-state signal for PR-level document review and combine that signal with Docuchango project metadata from `docs-project.yaml`.

# Motivation

Hermit needs one document review list that includes both:

- canonical RFC documents on the default branch (status management only)
- RFC documents in open PRs that are ready for collaborative commenting
- other docs-cms document types in open PRs so maintainers can triage ADRs, memos, PRDs, and future Docuchango types consistently

At repository scale, scanning every open PR and all changed files on each request is expensive and slow. A label-driven strategy makes the set of candidate PRs explicit, reduces API load, and gives repository owners a clear control point for workflow intent.

# Detailed Design

## Workflow Model

Hermit introduces two source types in the unified RFC list:

- `main_rfc`
  - source: default branch document in `docs-cms/rfcs/`
  - action policy: status transitions only (`draft -> accepted -> implemented`)
  - comments: disabled
- `pr_rfc`
  - source: document changed in an open PR
  - action policy: thread comments enabled
  - comments: enabled only when PR is in commentable state
- `review_session_pr`
  - source: a source document referenced by a Hermit marker file in a PR
  - action policy: thread comments enabled against the new review-session PR
  - comments: enabled when a document needs another review after its original PR has closed

## Label Contract

Use labels with the format:

- `<doc-type>:<state>`

`<doc-type>` is the normalized Docuchango document type discovered from `docs-project.yaml`. Examples:

- `rfc`
- `adr`
- `memo`
- `prd`

`<state>` is one of:

- `needs-review`: document is waiting for review. Hermit auto-applies this when an open, non-draft PR changes a docs-cms document.
- `review`: legacy active-review state. Hermit continues to treat this as queued work for compatibility, but new automation writes `needs-review`.
- `needs-changes`: reviewers have requested author updates.
- `ready`: reviewers consider the document ready for acceptance, merge, or the next workflow step.
- `reviewed`: review is complete. Hermit keeps this as visible GitHub state and does not include the PR in the active review queue.

The state labels are idempotent per document type. When Hermit applies a new state for a document type, it removes older Hermit workflow-state labels for that same type, such as replacing `rfc:review` with `rfc:needs-review`.

Example labels:

- `rfc:needs-review`
- `rfc:needs-changes`
- `rfc:ready`
- `adr:reviewed`

The older `hermit:rfc-ready` label remains a compatibility label for existing RFC submit/review flows, but new automatic docs-cms detection should use `<doc-type>:<state>`.

## Discovery Algorithm

For each configured repository:

1. Query open PRs and skip drafts.
2. Fetch changed files for each open, non-draft PR.
3. Load Docuchango metadata from `docs-project.yaml` and match changed files to configured document types.
4. Auto-apply `<doc-type>:needs-review` labels for matched docs-cms document changes when the label is missing, removing superseded `<doc-type>:review`, `<doc-type>:needs-changes`, `<doc-type>:ready`, or `<doc-type>:reviewed` labels for the same document type.
5. Keep RFC files that satisfy all conditions:
   - path matches the configured RFC document location or index target
   - filename format `rfc-NNN-short-description.md`
   - markdown extension and non-empty content
6. Detect Hermit review-session marker files under `.hermit/reviews/*.json`.
7. For each marker, read `source_path` and `document_type`, render the source document from the PR head SHA, and build a `review_session_pr` entry for the referenced document.
8. Build `pr_rfc` entries for valid RFC files.
9. Merge with `main_rfc` catalog into one response model.

Hermit still validates file path and format even when labels exist. Labels are workflow-state signals, not sole truth.

Closed PRs are inspected only when they already carry an active review workflow label (`<doc-type>:needs-review`, legacy `<doc-type>:review`, or `<doc-type>:needs-changes`). A closed PR with `<doc-type>:reviewed` is treated as completed history, not active review work.

## Review Session PRs

When a reviewer needs to add new comments to a document whose original PR is already closed, Hermit opens a new PR with a conventional title and commit message:

- `docs(review): new review for <doc-name>`

The PR contains a marker file, not a source document rewrite. Marker files live under `.hermit/reviews/` and include:

- `source_path`: docs-cms document path to review
- `document_type`: normalized Docuchango type such as `adr`, `memo`, `prd`, or `rfc`
- `base_branch` and `base_sha`: source branch context used to open the session
- `previous_pr_number`: optional prior PR history

Hermit applies `<doc-type>:needs-review` to the new PR. RFC review-session PRs may also carry the legacy `hermit:rfc-ready` label for compatibility.

## API Changes

Add unified list semantics to RFC catalog APIs (exact path naming may follow RFC-003 conventions):

- include `source_type` (`main_rfc` | `pr_rfc`)
- include `commentable` boolean
- include `status_mutable` boolean
- include optional `pr_number`, `pr_url`, and label snapshot for `pr_rfc`

Add an API to start a review-session PR for an existing docs-cms document:

- `POST /api/v1/repositories/{repositoryId}/review-sessions`
- request: `file_path`, optional `previous_pr_number`
- response: PR number, branch, marker path, source file path, document type, and PR URL

The CLI must expose this flow for validation:

- `hermitctl review start <repository-id> --file <docs-cms-path> [--previous-pr N]`
- expectation flags for console tests: `--expect-pr`, `--expect-file`, and `--expect-doc-type`

No direct GitHub API calls from clients (per ADR-007).

## Data Model Changes

Extend RFC list view model:

- `source_type: string`
- `commentable: bool`
- `status_mutable: bool`
- `pr_context` (nullable struct with PR metadata)

## Caching and Scale

- Cache candidate PR discovery per repository for short TTL (30-120 seconds).
- Cache PR file lists per PR SHA to avoid repeated diff reads.
- Invalidate or refresh on explicit user refresh actions.

## Migration Strategy

1. Keep legacy RFC label configuration with default `hermit:rfc-ready` for existing submit-for-review flows.
2. Implement Docuchango-driven candidate PR discovery and automatic `<doc-type>:needs-review` labels.
3. Introduce merged RFC list response fields.
4. Update UI to gate actions by `commentable` and `status_mutable`.
5. Roll out with docs and operator guidance for label usage.

# Drawbacks

- Requires repository teams to apply explicit state transition labels consistently.
- Incorrect labels can temporarily hide eligible RFCs or expose non-eligible PRs as candidates.
- Adds workflow coupling to GitHub labeling conventions.

# Alternatives

## Scan All Open PRs

Not chosen due to poor scalability and high API load for large repositories.

## Path-Only Search Without Labels

Not chosen because it still requires broad PR enumeration and removes explicit human workflow intent.

## Draft State as Sole Signal

Not chosen because many teams use draft state inconsistently and still need an explicit readiness control for RFC review.

# Adoption Strategy

- Publish a short maintainer playbook for `<doc-type>:<state>` labels.
- Add optional automation (bot/check) to suggest label changes when docs-cms files are modified.
- Expose UI hints when PR documents exist but the workflow state is unclear.

# Unresolved Questions

- Should multiple ready-state labels be supported per repository policy?
- Should label configuration be global or per repository in Hermit config?

# Future Possibilities

- Bidirectional sync of Hermit thread state to complementary labels.
- Label-driven queue prioritization (`priority/p0`, `priority/p1`) for reviewer triage.
- Webhook-driven cache invalidation to reduce polling.
