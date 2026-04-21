---
title: Adopt Go as the Primary Application Language
status: Proposed
created: 2026-04-21T00:05:57Z
deciders: Engineering Team
tags: [architecture, backend, golang]
id: adr-001
project_id: hermit
doc_uuid: 508948c0-b531-4ebc-98ea-38f824507c9a
---

# Context

Hermit is being built as a collaboration application for RFC review workflows, including markdown rendering, inline comment interactions, and synchronization with GitHub pull request comments and approvals.

The platform needs a backend that is reliable under concurrent usage, easy to deploy as a single service, and efficient for API workloads, background synchronization jobs, and integration with GitHub webhooks.

The team needs to select a primary implementation language before architecture and service boundaries are finalized.

# Decision

We propose adopting Go (Golang) as the primary language for the Hermit backend application.

Go will be the default choice for core API services, GitHub integration/sync workers, and supporting internal modules unless a specific component has a justified exception.

# Consequences

## Positive

- Strong support for concurrent workloads using goroutines and channels.
- Single static binaries simplify deployment and operations.
- Fast startup and low memory overhead are suitable for webhook-driven and API-oriented services.
- Strong standard library support for HTTP, JSON, context propagation, and testing.

## Negative

- Team members with limited Go experience may require onboarding time.
- UI-heavy or scripting-oriented workflows may still require additional languages/tools.
- Some advanced framework conveniences available in other ecosystems may need custom implementation.

## Neutral

- The decision sets a default, but does not prevent selective polyglot components when justified.
- Existing CI and tooling must be configured for Go formatting, linting, and test coverage.

# Alternatives Considered

## Node.js/TypeScript

Node.js/TypeScript offers strong developer ergonomics and broad ecosystem support, especially for web-first teams. It was not chosen as the default because we prioritize static binaries, predictable concurrency behavior, and lower runtime overhead for synchronization-heavy backend workloads.

## Python

Python offers rapid development and rich libraries, but was not chosen as the primary backend language because performance characteristics and concurrency patterns are less aligned with the expected long-running sync and webhook processing profile for Hermit.

# References

- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
- [Go Project](https://go.dev/)
