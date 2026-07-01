---
title: Repository Configuration and PAT-Based Access
status: Draft
author: Steven Taylor
created: 2026-04-21T00:19:06Z
tags: [configuration, github, integration, rfc, security]
id: rfc-002
project_id: hermit
doc_uuid: dffdba90-b376-41ef-9a4a-b2f3be3dd34a
---

# Summary

This RFC defines how Hermit repositories are configured and connected for RFC collaboration workflows. The initial implementation supports GitHub Personal Access Token (PAT) authentication only, and introduces a repository configuration model that binds each configured repository to an access credential, policy settings, and validation rules. PATs may be entered directly or imported from the local Git Credential Helper.

# Motivation

Hermit depends on GitHub APIs for pull request metadata, markdown source retrieval, comment synchronization, and approval actions. To operate reliably, the system needs a clear repository onboarding and configuration workflow.

Without a standard configuration model, repository access may be inconsistent, permissions may be over-scoped, and operational debugging becomes difficult. This RFC provides a first-phase design that is simple to implement while keeping room for future credential types.

# Detailed Design

Hermit repository configuration is managed inside the monolith and stored as metadata plus secret references.

## Repository Configuration Model

Each configured repository includes:

- Repository identity: `owner`, `name`, and canonical `full_name`.
- Source policy: path conventions for RFC files (default `docs-cms/rfcs/`) and single-file PR validation behavior.
- Credential binding: reference to one PAT secret used for GitHub API operations.
- Access policy: allowed operations (read PRs, write comments, submit review approvals).
- Sync settings: webhook expectation, polling fallback, retry policy, and sync window targets.
- Status metadata: connectivity status, last successful API check, last sync error.

## Configuration Workflow

1. Admin adds repository in Hermit settings.
2. Admin provides GitHub owner/name and PAT, or asks Hermit to read the PAT from the local Git Credential Helper.
3. Hermit validates PAT by calling GitHub endpoints required for Hermit operations.
4. Hermit validates repository visibility and required scopes.
5. Hermit saves repository configuration and encrypted PAT reference.
6. Hermit runs a dry-run sync check and displays readiness state.

## Git Credential Helper Source

Hermit supports Git Credential Helper as a local source for PAT-backed repository credentials. This keeps PAT-based API access as the authentication model while avoiding duplicate token entry when a developer already authenticated Git for the same GitHub host.

Credential helper lookup behavior:

- Hermit calls `git credential fill` with `protocol=https` and the configured host.
- For GitHub.com, the lookup host is `github.com`.
- For GitHub Enterprise, the lookup host is the enterprise hostname, not the API path.
- For an enterprise endpoint such as `https://ghe.example.com/api/v3`, the lookup host is `ghe.example.com`.
- Hermit stores the returned password/token in its own configured secret store and uses it as the repository's bound PAT.

Git Credential Helper state is local to each developer machine. Repository exports and shared config must include account/repository metadata only; they must not include PATs or assume another developer has the same helper entry.

## Validation Rules

- Repository must be reachable with the configured PAT.
- PAT must include required scopes for read/write actions used by Hermit.
- RFC source path must exist or be creatable through repository workflow.
- Repository configuration is marked unhealthy if repeated auth failures occur.

## Runtime Access Behavior

- All GitHub requests for a repository use that repository's bound PAT.
- Requests include request correlation IDs for observability.
- On `401/403` responses, Hermit marks repository auth status degraded and surfaces remediation instructions.
- Secrets are never returned to clients and are redacted from logs.
- If a repository/account is configured to refresh from Git Credential Helper, Hermit may re-read the helper entry for the account host before validation or connectivity probes, then update the local secret reference when the helper token changes.

## API Changes

Initial API surface (illustrative):

- `POST /api/admin/repositories`
  - Creates repository configuration with PAT credential.
- `GET /api/admin/repositories`
  - Lists configured repositories and health status.
- `GET /api/admin/repositories/{id}`
  - Retrieves configuration metadata and validation status.
- `POST /api/admin/repositories/{id}/validate`
  - Re-runs connectivity and scope checks.
- `POST /api/admin/repositories/{id}/rotate-token`
  - Replaces PAT and revalidates repository access.
- `POST /api/admin/repositories/{id}/bind-credential`
  - Binds or refreshes the repository PAT from a local credential source such as Git Credential Helper.

## Data Model Changes

Representative entities:

- `repositories`
  - `id`, `owner`, `name`, `full_name`, `rfc_path_policy`, `status`, `created_at`, `updated_at`.
- `repository_credentials`
  - `repository_id`, `credential_type` (`pat`), `secret_ref`, `source` (`manual`, `git_credential_helper`), `credential_host`, `last_validated_at`, `validation_state`.
- `repository_access_policies`
  - `repository_id`, `can_read_pr`, `can_write_comments`, `can_submit_reviews`, `sync_mode`.
- `repository_health_events`
  - `repository_id`, `event_type`, `severity`, `message`, `created_at`.

## Migration Strategy

No previous repository config subsystem exists. Rollout approach:

1. Introduce repository settings UI and PAT onboarding.
2. Gate active collaboration features on repository health status.
3. Add token rotation and validation endpoints.
4. Prepare abstraction layer for future auth providers (GitHub App, OAuth) without changing repository model contracts.

# Drawbacks

- PAT usage is less centralized than GitHub App installations and may increase token lifecycle overhead.
- Per-user token management can create operational burden for teams.
- Scope management errors can break repository operations until token is rotated/fixed.

# Alternatives

## Alternative 1

GitHub App-only integration from the start.

Comparison: stronger permission model and org governance, but rejected for initial implementation speed and setup complexity in early adoption.

## Alternative 2

OAuth App-based user delegated access.

Comparison: good user-level onboarding ergonomics, but rejected initially because long-lived repository automation behavior is less direct than PAT for first-phase operation.

# Adoption Strategy

- Start with internal repositories and one PAT per repository owner context.
- Provide setup checklist for required scopes and repository permissions.
- For GitHub Enterprise repositories, document the API endpoint and corresponding credential-helper host separately.
- Track health and auth error rates before broad rollout.
- Add runbook for PAT rotation and revocation handling.

# Unresolved Questions

- What exact minimum PAT scopes are required for all Hermit operations?
- Should Hermit support one PAT for multiple repositories under the same owner as a first-class option?
- What token expiration/rotation policy should be enforced by default?
- Should Hermit persist credential-helper source metadata for automatic refresh, or should helper import remain an explicit bind/rotate action?
- At what adoption threshold should GitHub App support become a priority migration path?

# Future Possibilities

- Add GitHub App support while preserving existing repository configuration contracts.
- Add OAuth-based delegated access for user-scoped operations.
- Add policy templates for enterprise repository onboarding.
- Add automatic token expiry alerts and rotation reminders.

# Related Documents

- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
- [RFC-001: Hermit High-Level Design and Architecture](./rfc-001-hermit-high-level-design-and-architecture.md)
- [ADR-001: Adopt Go as the Primary Application Language](../adr/adr-001-golang-base-application.md)
- [ADR-002: Adopt a Single Monolith Application Architecture](../adr/adr-002-single-monolith-application.md)
- [ADR-003: Use GitHub as the Source of Truth](../adr/adr-003-github-source-of-truth.md)
