---
title: Adopt a Single Monolith Application Architecture
status: Proposed
created: 2026-04-21T00:10:17Z
deciders: Engineering Team
tags: [architecture, backend, monolith]
id: adr-002
project_id: hermit
doc_uuid: db18f102-3339-4c89-85a7-42354ad5db6a
---

# Context

Hermit is an early-stage product focused on one cohesive workflow: RFC submission, markdown rendering from PR branches, document-style commenting, and GitHub PR synchronization for comments and approvals.

The initial product scope is tightly integrated, and the team needs to deliver quickly while maintaining operational simplicity. Splitting into multiple services too early would increase coordination overhead, deployment complexity, and integration burden.

# Decision

We propose building Hermit as a single monolith application for the initial product phases.

The monolith will include web/API endpoints, markdown rendering, comment lifecycle management, and GitHub synchronization logic within one deployable unit.

# Consequences

## Positive

- Faster iteration with a single codebase and deployment artifact.
- Simpler local development and CI/CD workflows.
- Easier end-to-end tracing and debugging across product flows.
- Lower infrastructure and operational overhead in the early stages.

## Negative

- Over time, the codebase may become harder to scale organizationally if module boundaries are not maintained.
- Scaling specific high-load subsystems independently is limited compared with service decomposition.
- A single deployment can increase blast radius if not protected by robust testing and release practices.

## Neutral

- Internal modular boundaries are still required to keep future extraction options open.
- Background jobs may run in the same application process initially, with potential separation later if needed.

# Alternatives Considered

## Microservices from the Start

Microservices provide independent scaling and team autonomy, but were not chosen because early-stage Hermit scope does not justify the added complexity of service boundaries, inter-service contracts, orchestration, and observability overhead.

## Modular Monolith plus Dedicated Worker Service

This hybrid approach was considered, but not chosen for day one because current workload does not yet require separate deployment of background processing. We can revisit this once sync throughput or reliability constraints demand isolation.

# References

- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
- [ADR-001: Adopt Go as the Primary Application Language](./adr-001-golang-base-application.md)
