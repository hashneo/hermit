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

This RFC proposes a label-driven workflow for discovering commentable RFCs in pull requests without scanning all open PRs. Hermit will use explicit GitHub labels as a candidate signal for PR-level RFC review state and combine that signal with RFC file validation under `docs-cms/rfcs/`.

# Motivation

Hermit needs one RFC list that includes both:

- canonical RFC documents on the default branch (status management only)
- RFC documents in open PRs that are ready for collaborative commenting

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

Use one required workflow label on PRs:

- `hermit:rfc-ready`

Optional labels (future-friendly, not required for v1):

- `hermit:rfc-blocked`
- `hermit:rfc-needs-author-update`

For v1, Hermit treats `hermit:rfc-ready` as the single positive signal.

## Discovery Algorithm

For each configured repository:

1. Query candidate PRs by label and open state:
   - `is:pr is:open label:hermit:rfc-ready -is:draft`
2. For candidate PRs only, fetch changed files.
3. Keep files that satisfy all conditions:
   - path under `docs-cms/rfcs/`
   - filename format `rfc-NNN-short-description.md`
   - markdown extension and non-empty content
4. Build `pr_rfc` entries for valid files.
5. Merge with `main_rfc` catalog into one response model.

Hermit still validates file path and format even when label exists. Label is a filter signal, not sole truth.

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

1. Add label configuration with default `hermit:rfc-ready`.
2. Implement label-filtered candidate PR discovery.
3. Introduce merged RFC list response fields.
4. Update UI to gate actions by `commentable` and `status_mutable`.
5. Roll out with docs and operator guidance for label usage.

# Drawbacks

- Requires repository teams to apply labels consistently.
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

- Publish a short maintainer playbook for applying `hermit:rfc-ready`.
- Add optional automation (bot/check) to suggest label changes when RFC files are modified.
- Expose UI hints when PR RFC exists but required label is missing.

# Unresolved Questions

- Should Hermit auto-apply `hermit:rfc-ready` when eligibility checks pass?
- Should multiple ready labels be supported per repository policy?
- Should label configuration be global or per repository in Hermit config?

# Future Possibilities

- Bidirectional sync of Hermit thread state to complementary labels.
- Label-driven queue prioritization (`priority/p0`, `priority/p1`) for reviewer triage.
- Webhook-driven cache invalidation to reduce polling.