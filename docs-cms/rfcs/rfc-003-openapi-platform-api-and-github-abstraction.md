---
title: OpenAPI Platform API and GitHub Abstraction Layer
status: Draft
author: Steven Taylor
created: 2026-04-21T00:23:58Z
tags: [api, architecture, github, openapi, rfc]
id: rfc-003
project_id: hermit
doc_uuid: d01c7a0d-8d71-430d-83b3-412fec7ea474
---

# Summary

This RFC defines Hermit's API-first integration boundary: all product clients interact with Hermit through a versioned OpenAPI contract, and Hermit internally brokers all GitHub operations. Clients do not call GitHub APIs directly for RFC workflows.

# Motivation

Hermit needs a consistent, product-oriented API that supports repository configuration, RFC rendering, comment lifecycle management, and review approvals while preserving GitHub as the canonical source of truth.

A direct-to-GitHub client model would fragment behavior across clients and make it difficult to enforce product constraints such as single-file RFC eligibility, docs-cms path policy, and synchronized comment/approval state semantics.

# Detailed Design

## API Boundary

- External boundary: Hermit OpenAPI REST API (`/api/v1/...`) is the only supported client integration surface.
- Internal boundary: GitHub provider adapters translate Hermit domain actions into GitHub API calls/webhook handling.

## Domain-Centered API Groups

- Repositories
  - Configure repository access, source policies, and health.
- RFC Documents
  - Evaluate PR eligibility, fetch/render RFC content from head SHA.
- Threads and Comments
  - Create, reply, resolve, reopen, list thread state.
- Reviews
  - Read review status, approve via Hermit API.
- Sync and Health
  - Expose sync status, conflict markers, and diagnostics.

## OpenAPI Requirements

- Hermit maintains an OpenAPI 3.x specification in-repo as the canonical API contract.
- Every public endpoint must be described in OpenAPI before implementation is considered complete.
- API versioning uses path-based versioning (`/api/v1`) with backward-compatible additions in minor releases.
- Error schema must be standardized with machine-readable `code`, `message`, `details`, and `correlation_id`.

## GitHub Abstraction Model

- GitHub remains canonical state authority (per ADR-003).
- Hermit stores projections/caches and reconciliation metadata.
- Provider adapter layer handles:
  - request construction and auth
  - retries/backoff
  - rate-limit handling
  - idempotency and deduplication
  - webhook-to-domain event mapping

## Representative Endpoints

- `POST /api/v1/repositories`
- `GET /api/v1/repositories/{repositoryId}`
- `POST /api/v1/repositories/{repositoryId}/validate`
- `GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc`
- `GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc/render`
- `GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/threads`
- `POST /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/threads`
- `POST /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/threads/{threadId}/resolve`
- `POST /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/review/approve`

## Security and Auth

- Client-to-Hermit authentication is managed by Hermit auth mechanisms.
- Hermit-to-GitHub authentication uses repository-bound credentials (initially PAT per ADR-005).
- Secrets are never exposed via API responses.
- All mutation endpoints require audit logging with actor identity and correlation ID.

## Observability and Reliability

- Every external API request and internal provider action carries a correlation ID.
- Sync status fields include `state`, `last_synced_at`, `last_error_code`, `retry_count`.
- Webhook lag and adapter error rates are tracked as first-class metrics.

## Data Model Changes

Adds/extends API contract and metadata entities:

- `api_contract_versions`
- `api_audit_events`
- `provider_operations_log`
- `sync_reconciliation_records`

Existing entities from RFC-001 and RFC-002 remain primary for domain data.

## Migration Strategy

1. Define initial OpenAPI spec for existing RFC-001/RFC-002 workflows.
2. Route web UI calls to Hermit API exclusively.
3. Remove any direct client GitHub calls from frontend code.
4. Add conformance tests to verify implemented routes match OpenAPI contract.
5. Add schema/version governance for non-backward-compatible changes.

# Drawbacks

- Additional backend abstraction layer increases implementation scope.
- API contract governance introduces process overhead.
- Some GitHub-specific features may be slower to expose through normalized domain endpoints.

# Alternatives

## Alternative 1

Frontend uses Hermit for some flows and direct GitHub calls for others.

Comparison: reduced backend scope short-term, but rejected due to inconsistent behavior, security concerns, and fragmented product semantics.

## Alternative 2

Expose a thin GitHub pass-through API rather than a domain API.

Comparison: lower transformation logic, but rejected because it leaks provider details and does not enforce Hermit workflow constraints.

# Adoption Strategy

- Publish OpenAPI spec and generated client for UI integration.
- Add API review gate requiring OpenAPI updates for endpoint changes.
- Prioritize endpoint completeness for repository configuration, RFC render, comments, and approvals.
- Train contributors on contract-first workflow.

# Unresolved Questions

- Which parts of OpenAPI should be split into separate files/modules for maintainability?
- What is the deprecation policy and support window for API versions?
- Should GraphQL be introduced later for UI aggregation patterns?
- What performance SLO should be attached to high-frequency thread endpoints?

# Future Possibilities

- Add typed SDK generation for web and CLI clients from OpenAPI.
- Introduce additional provider adapters beyond GitHub while preserving API contract.
- Add API policy checks (linting/spectral) in CI.
- Add event streaming endpoints for live collaboration updates.

# Related Documents

- [ADR-007: Expose an OpenAPI-First Hermit API for All GitHub Interactions](../adr/adr-007-openapi-first-hermit-api-for-github-interactions.md)
- [ADR-003: Use GitHub as the Source of Truth](../adr/adr-003-github-source-of-truth.md)
- [ADR-005: Use Personal Access Tokens for Initial GitHub Authentication](../adr/adr-005-use-pat-for-initial-github-authentication.md)
- [RFC-001: Hermit High-Level Design and Architecture](./rfc-001-hermit-high-level-design-and-architecture.md)
- [RFC-002: Repository Configuration and PAT-Based Access](./rfc-002-repository-configuration-and-pat-authentication.md)
