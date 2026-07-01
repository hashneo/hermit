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

Engineers may already have a GitHub or GitHub Enterprise PAT stored in the local Git Credential Helper through normal Git or GitHub CLI setup. Requiring them to copy the same token into Hermit manually creates avoidable onboarding friction and increases the chance of stale duplicate credentials.

# Decision

We propose using GitHub Personal Access Tokens (PATs) as the only supported authentication method for initial Hermit releases.

Repository configurations will bind to PAT-based credentials, and all GitHub operations for those repositories will use the associated PAT until additional auth models are introduced.

Hermit may source that PAT from the local Git Credential Helper when configuring or refreshing an account. The credential helper is an import/source mechanism, not a separate authentication protocol: Hermit still sends GitHub API requests with `Authorization: Bearer {pat}` and stores the resolved token in the platform-appropriate local secret store.

For GitHub Enterprise accounts, Hermit must use the enterprise host as the credential lookup host. For an enterprise endpoint such as `https://ghe.example.com/api/v3`, Hermit reads the PAT from Git Credential Helper with host `ghe.example.com` and uses that token for API access to the configured enterprise API endpoint.

# Consequences

## Positive

- Fastest path to functional GitHub integration for early product delivery.
- Straightforward implementation in monolith architecture.
- Flexible enough to support immediate internal testing and dogfooding.
- Reuses developers' existing local Git credentials when available, reducing duplicate token entry for GitHub Enterprise accounts.

## Negative

- PAT lifecycle management (rotation, expiration, revocation) becomes an operational requirement.
- Permission boundaries may be broader than ideal compared with GitHub App installation scopes.
- Security posture depends heavily on secret handling and least-privilege token guidance.
- Credential Helper lookup is device-local and host-specific; shared repository exports cannot include or assume another developer's local credential state.

## Neutral

- Authentication interfaces should be designed to allow future provider expansion without breaking repository configuration contracts.
- PAT remains a phase-one choice and does not preclude migration to GitHub App or OAuth later.
- GitHub CLI login may populate Git Credential Helper, but Hermit treats the helper as the integration boundary and does not depend on GitHub CLI session state directly.

# Alternatives Considered

## GitHub App from Day One

Provides stronger org-level governance and finer-grained permission controls, but was not chosen due to greater initial implementation and operational complexity for first release.

## OAuth App Delegated Access

Enables user-level authorization flows, but was not chosen initially because it introduces additional complexity for repository-level automation and token lifecycle handling in this phase.

## Direct GitHub CLI Session Reuse

Reusing `gh auth login` state directly would make onboarding convenient for engineers already using GitHub CLI, but was not chosen because it couples Hermit to a CLI-specific credential format and runtime dependency. Git Credential Helper provides a narrower and more standard local token source while preserving PAT-based API behavior.

# References

- [RFC-002: Repository Configuration and PAT-Based Access](../rfcs/rfc-002-repository-configuration-and-pat-authentication.md)
- [ADR-003: Use GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
