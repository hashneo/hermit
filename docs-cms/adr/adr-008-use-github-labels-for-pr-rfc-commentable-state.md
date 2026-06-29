---
title: Use GitHub Labels to Determine Commentable PR RFC State
status: Proposed
created: 2026-04-21T19:33:49Z
deciders: Engineering Team
tags: [architecture, github, labels, workflow]
id: adr-008
project_id: hermit
doc_uuid: 1d3235d5-1b21-4697-b4ce-ff3d17fee579
---

# Context

Hermit needs to present a unified RFC list containing both default-branch RFC documents and RFCs currently under PR review. PR RFCs should be commentable, while main-branch RFCs should remain non-commentable and status-managed.

Without an explicit selection signal, discovering commentable PR RFCs requires scanning large numbers of open PRs and their file changes, which does not scale well and increases GitHub API cost and latency.

# Decision

Hermit will use GitHub labels as the candidate and workflow-state signal for PR RFC commentable state.

For v1:

- Compatibility RFC label: `hermit:rfc-ready`
- Docuchango workflow labels: `<doc-type>:<state>`, such as `rfc:needs-review`, `adr:needs-review`, `rfc:needs-changes`, and `rfc:reviewed`.
- Hermit evaluates open, non-draft PRs for changed docs-cms documents and auto-applies `<doc-type>:needs-review` when a changed document is reviewable.
- Hermit treats `<doc-type>:needs-review`, legacy `<doc-type>:review`, and `<doc-type>:needs-changes` as active review queue states.
- Hermit treats `<doc-type>:reviewed` as completed review history; it does not keep a closed PR in the active review queue.
- When Hermit applies a new workflow state for a document type, it removes older Hermit workflow-state labels for that same document type so the label state is idempotent.
- Hermit will still validate RFC file path and naming conventions before enabling commentability.

Main-branch RFCs remain non-commentable and support status transitions only.

# Consequences

## Positive

- Greatly reduces PR discovery scope and API load.
- Adds explicit workflow intent controlled by maintainers.
- Produces predictable commentability behavior in unified RFC list UX.
- Aligns with GitHub-native operational workflows and governance.

## Negative

- Depends on consistent label hygiene by repository maintainers.
- Mislabeling can cause temporary false positives or false negatives.
- Introduces label convention dependency across repositories.

## Neutral

- GitHub remains source of truth for PR state (ADR-003).
- Hermit still enforces RFC path/filename validity independent of labels.

# Alternatives Considered

## Scan All Open PRs and Filter by File Path

Rejected due to scalability, latency, and API consumption concerns for repositories with large PR volumes.

## Use Draft/Ready-for-Review State Only

Rejected because draft state alone does not encode RFC workflow intent and is used inconsistently across teams.

# References

- [ADR-003: Use GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [ADR-004: RFC Document Source and Format](./adr-004-rfc-doc-source-and-format.md)
- [ADR-007: OpenAPI-First Hermit API for GitHub Interactions](./adr-007-openapi-first-hermit-api-for-github-interactions.md)
- [RFC-005: Label-Driven PR RFC Discovery and Commentability](../rfcs/rfc-005-label-driven-pr-rfc-discovery-and-commentability.md)
