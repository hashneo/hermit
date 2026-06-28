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

## Label Contract

Use labels with the format:

- `<doc-type>:<state>`

`<doc-type>` is the normalized Docuchango document type discovered from `docs-project.yaml`. Examples:

- `rfc`
- `adr`
- `memo`
- `prd`

`<state>` is one of:

- `review`: document is in active review. Hermit may auto-apply this when an open, non-draft PR changes a docs-cms document.
- `needs-changes`: reviewers have requested author updates.
- `ready`: reviewers consider the document ready for acceptance, merge, or the next workflow step.

Example labels:

- `rfc:review`
- `rfc:needs-changes`
- `rfc:ready`
- `adr:review`

The older `hermit:rfc-ready` label remains a compatibility label for existing RFC submit/review flows, but new automatic docs-cms detection should use `<doc-type>:<state>`.

## Discovery Algorithm

For each configured repository:

1. Query open PRs and skip drafts.
2. Fetch changed files for each open, non-draft PR.
3. Load Docuchango metadata from `docs-project.yaml` and match changed files to configured document types.
4. Auto-apply `<doc-type>:review` labels for matched docs-cms document changes when the label is missing.
5. Keep RFC files that satisfy all conditions:
   - path matches the configured RFC document location or index target
   - filename format `rfc-NNN-short-description.md`
   - markdown extension and non-empty content
6. Build `pr_rfc` entries for valid RFC files.
7. Merge with `main_rfc` catalog into one response model.

Hermit still validates file path and format even when labels exist. Labels are workflow-state signals, not sole truth.

## API Changes

Add unified list semantics to RFC catalog APIs (exact path naming may follow RFC-003 conventions):

- include `source_type` (`main_rfc` | `pr_rfc`)
- include `commentable` boolean
- include `status_mutable` boolean
- include optional `pr_number`, `pr_url`, and label snapshot for `pr_rfc`

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
2. Implement Docuchango-driven candidate PR discovery and automatic `<doc-type>:review` labels.
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

- Should Hermit remove stale state labels when a document moves from `review` to `needs-changes` or `ready`?
- Should multiple ready-state labels be supported per repository policy?
- Should label configuration be global or per repository in Hermit config?

# Future Possibilities

- Bidirectional sync of Hermit thread state to complementary labels.
- Label-driven queue prioritization (`priority/p0`, `priority/p1`) for reviewer triage.
- Webhook-driven cache invalidation to reduce polling.
