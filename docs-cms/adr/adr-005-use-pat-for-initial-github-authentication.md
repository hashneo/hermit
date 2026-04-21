---
title: Use Personal Access Tokens for Initial GitHub Authentication
status: Proposed
created: 2026-04-21T00:19:06Z
deciders: Engineering Team
tags: [architecture, github, security]
id: adr-005
project_id: hermit
doc_uuid: 1bae097c-876b-48c1-9c49-78bf2fe6f5bc
---

# Context

Hermit requires authenticated GitHub API access to read PR state, fetch RFC markdown from branches, create and reconcile comments, and submit approvals from the GUI.

Multiple authentication models are possible (GitHub App, OAuth, PAT). For initial delivery, the team needs a practical approach that minimizes implementation and onboarding complexity while supporting required operations.

# Decision

We propose using GitHub Personal Access Tokens (PATs) as the only supported authentication method for initial Hermit releases.

Repository configurations will bind to PAT-based credentials, and all GitHub operations for those repositories will use the associated PAT until additional auth models are introduced.

# Consequences

## Positive

- Fastest path to functional GitHub integration for early product delivery.
- Straightforward implementation in monolith architecture.
- Flexible enough to support immediate internal testing and dogfooding.

## Negative

- PAT lifecycle management (rotation, expiration, revocation) becomes an operational requirement.
- Permission boundaries may be broader than ideal compared with GitHub App installation scopes.
- Security posture depends heavily on secret handling and least-privilege token guidance.

## Neutral

- Authentication interfaces should be designed to allow future provider expansion without breaking repository configuration contracts.
- PAT remains a phase-one choice and does not preclude migration to GitHub App or OAuth later.

# Alternatives Considered

## GitHub App from Day One

Provides stronger org-level governance and finer-grained permission controls, but was not chosen due to greater initial implementation and operational complexity for first release.

## OAuth App Delegated Access

Enables user-level authorization flows, but was not chosen initially because it introduces additional complexity for repository-level automation and token lifecycle handling in this phase.

# References

- [RFC-002: Repository Configuration and PAT-Based Access](../rfcs/rfc-002-repository-configuration-and-pat-authentication.md)
- [ADR-003: Use GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
