---
title: Expose an OpenAPI-First Hermit API for All GitHub Interactions
status: Proposed
created: 2026-04-21T00:23:40Z
deciders: Engineering Team
tags: [api, architecture, github, openapi]
id: adr-007
project_id: hermit
doc_uuid: 7c001fd0-e94f-4a67-8358-f0c5ee620737
---

# Context

Hermit currently relies on GitHub as the source of truth for PR and review lifecycle state. At the same time, product surfaces (web UI and future clients) need a stable, product-specific API contract that supports RFC collaboration workflows without exposing GitHub API complexity directly to clients.

If clients call GitHub APIs directly, behavior will drift across clients, permission handling becomes inconsistent, and Hermit-specific workflow semantics (anchors, sync states, repository policy validation) are hard to enforce.

# Decision

We propose that Hermit provide a full OpenAPI-defined API as the sole client integration surface for GitHub-backed workflows.

Clients (including Hermit web UI) will interact with GitHub exclusively through Hermit API endpoints. Hermit will broker all required GitHub operations internally and map them to Hermit domain models and workflow guarantees.

# Consequences

## Positive

- Establishes one stable API contract for all clients via OpenAPI.
- Hides GitHub API variability and simplifies frontend/client implementation.
- Centralizes authorization, validation, rate-limiting, retries, and observability.
- Enables consistent enforcement of Hermit product rules (single-file RFC, path policy, comment/approval semantics).
- Improves testability with contract-driven development and generated clients.

## Negative

- Increases backend scope because Hermit must proxy and normalize all needed GitHub capabilities.
- Requires ongoing maintenance when GitHub API behavior changes.
- May introduce latency overhead compared with direct client-to-GitHub calls.

## Neutral

- GitHub remains the canonical source of workflow truth (per ADR-003); this decision changes client integration boundaries, not data authority.
- OpenAPI schema versioning becomes a first-class governance process.

# Alternatives Considered

## Mixed Model (Some Calls to Hermit, Some Direct to GitHub)

This was not chosen because it creates fragmented behavior, inconsistent security posture, and duplicated client logic.

## Direct GitHub API Access from Clients

This was not chosen because it leaks provider-specific complexity to clients and undermines Hermit's ability to provide consistent workflow semantics and policy enforcement.

# References

- [ADR-003: Use GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [RFC-001: Hermit High-Level Design and Architecture](../rfcs/rfc-001-hermit-high-level-design-and-architecture.md)
- [RFC-002: Repository Configuration and PAT-Based Access](../rfcs/rfc-002-repository-configuration-and-pat-authentication.md)
- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
