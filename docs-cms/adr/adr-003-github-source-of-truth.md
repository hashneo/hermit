---
title: Use GitHub as the Source of Truth
status: Proposed
created: 2026-04-21T00:10:47Z
deciders: Engineering Team
tags: [architecture, github, integration]
id: adr-003
project_id: hermit
doc_uuid: 477b182a-4d4d-4e39-b2d3-7592242e6a36
---

# Context

Hermit provides a document-first collaboration experience for RFCs, but the review lifecycle ultimately depends on GitHub pull requests, comments, approvals, and merge workflows.

To avoid conflicting states and duplicated governance, the system needs a clear authority for canonical data such as PR status, review decisions, comment thread state, and branch content.

# Decision

We propose using GitHub as the source of truth for RFC PR workflow state.

Hermit will act as a collaboration interface and synchronization layer that reads from and writes to GitHub, while treating GitHub records as canonical when state conflicts occur.

# Consequences

## Positive

- Aligns with existing team workflow, permissions, and audit history in GitHub.
- Reduces risk of divergent review state between Hermit and GitHub.
- Simplifies compliance and traceability by relying on an existing system of record.
- Enables users to fall back to native GitHub UI without losing workflow continuity.

## Negative

- Product behavior is constrained by GitHub API capabilities and limitations.
- Temporary API failures or rate limits in GitHub can impact Hermit functionality.
- Some document-style UX interactions may require reconciliation logic to map onto GitHub primitives.

## Neutral

- Hermit may maintain cached or derived local views for performance, but these are not authoritative.
- Conflict resolution and retry strategies become a core part of synchronization design.

# Alternatives Considered

## Hermit as Primary Source of Truth

Having Hermit own canonical workflow state could enable more product-specific semantics, but was not chosen because it introduces governance duplication and increases risk of drift from GitHub PR reality.

## Dual Source of Truth with Bidirectional Reconciliation

Treating both Hermit and GitHub as co-equal authorities was considered, but not chosen due to high complexity in conflict resolution, poor debuggability, and increased chance of inconsistent approval or comment states.

# References

- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
- [ADR-001: Adopt Go as the Primary Application Language](./adr-001-golang-base-application.md)
- [ADR-002: Adopt a Single Monolith Application Architecture](./adr-002-single-monolith-application.md)
