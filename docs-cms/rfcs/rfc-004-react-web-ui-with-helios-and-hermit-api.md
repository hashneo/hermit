---
title: React Web UI with Helios Design System and Hermit API Integration
status: Draft
author: Steven Taylor
created: 2026-04-21T00:24:50Z
tags: [frontend, helios, react, rfc, web]
id: rfc-004
project_id: hermit
doc_uuid: da10626c-4188-4223-8204-d8c6e8a0234c
---

# Summary

This RFC defines the Hermit client application as a React-based web UI aligned to the HashiCorp Helios design system and integrated exclusively through Hermit's OpenAPI platform API. The UI will provide a document-first RFC collaboration experience, including inline comments, thread resolution, and PR approval actions.

# Motivation

Hermit needs a cross-platform, low-friction collaboration interface suitable for broad adoption across engineering, product, and design stakeholders. A web client best supports shareable workflows and immediate access without local installation.

This RFC aligns UI implementation with two architectural decisions:

- ADR-006: Helios as the design baseline.
- ADR-007: all GitHub-backed workflow interactions happen through Hermit APIs, not direct GitHub API calls.

# Detailed Design

## Frontend Platform

- Single-page application built with React.
- Component and interaction patterns follow HashiCorp Helios guidance.
- The UI is structured by feature modules (repository setup, RFC reader, threads, approvals, status).
- Rendering and state updates prioritize long-form document readability and collaboration context.

## UX and Information Architecture

Primary screens:

- Repository Configuration
  - Add repository, bind PAT credential, validate access, review health.
- RFC Workspace
  - Render RFC content from selected PR head.
  - Show inline comment markers and side thread panel.
  - Display sync/reconciliation status and unresolved counts.
- Review and Approval
  - Surface current review state from Hermit API.
  - Submit PR approval directly in Hermit UI.

## Design System Conformance

- Use Helios primitives/components for layout, forms, lists, badges, alerts, and action controls.
- Accessibility and interaction behavior follow Helios standards as baseline.
- When custom components are required (for document anchor interactions), styles and interaction patterns must remain Helios-consistent.

## API Integration Contract

- The UI consumes Hermit OpenAPI endpoints only.
- No direct browser calls to GitHub REST/GraphQL APIs.
- Generated typed API client is preferred to reduce drift from OpenAPI schema.
- Error handling uses standardized API error payload shape.

Representative endpoint usage:

- Repository settings: `POST/GET /api/v1/repositories`
- RFC eligibility/render: `GET /api/v1/repositories/{repositoryId}/pull-requests/{prNumber}/rfc` and `/render`
- Thread actions: `GET/POST /threads`, `POST /threads/{threadId}/resolve`
- Review actions: `POST /review/approve`

## State Management

- UI state separates:
  - server state (fetched via Hermit API)
  - local interaction state (selection anchors, panel filters, unsent drafts)
- Sync-sensitive views display optimistic updates with rollback/reconcile on API failure.
- Thread status and review state refresh on relevant event polling cadence until real-time events are added.

## Performance and Reliability Expectations

- Initial RFC render view should load within PRD target bounds when backend response is healthy.
- Thread operations should provide immediate user feedback and clear pending/synced indicators.
- Degraded API/repository auth states should be surfaced with actionable remediation guidance.

## API Changes

No new API domain is required beyond RFC-003. UI work depends on API completeness for:

- repository config and health
- RFC render payloads with anchor metadata
- full thread lifecycle endpoints
- approval submission and review state retrieval

Gaps discovered during UI implementation should be proposed as additive OpenAPI updates.

## Data Model Changes

Frontend-specific persisted state may include optional user preferences:

- panel layout preference
- thread filter defaults
- last-viewed repository/PR context

No canonical workflow data ownership moves to frontend.

## Migration Strategy

1. Phase 1 - UI foundation
   - Set up React app shell, Helios baseline styles/components, auth/session plumbing.
2. Phase 2 - Repository and RFC read flows
   - Implement repository setup and RFC render/read views.
3. Phase 3 - Collaboration interactions
   - Add inline comment creation, thread panel interactions, resolve/reopen flows.
4. Phase 4 - Approval flow and hardening
   - Add in-app approval action, status views, error states, and accessibility polish.

# Drawbacks

- React web UI introduces frontend build/runtime complexity compared with a simple server-rendered UI.
- Helios conformance may require additional adaptation for document-annotation interactions.
- UI delivery pace depends on timely completion of API endpoints and schema stability.

# Alternatives

## Alternative 1

Native desktop client (for example, Swift app) as primary interface.

Comparison: stronger native integration on one platform, but rejected due to limited cross-platform reach and higher adoption friction.

## Alternative 2

Server-rendered web pages with minimal client interactivity.

Comparison: simpler initial architecture, but rejected because rich document annotation and thread interaction patterns require more dynamic UI behavior.

# Adoption Strategy

- Start with internal beta users working on RFC-heavy repositories.
- Publish usage guide for repository setup, RFC review workflow, and approval actions.
- Track UX and reliability metrics: render time, comment sync success, approval completion from UI.
- Iterate on Helios-consistent UX refinements from user feedback.

# Unresolved Questions

- What real-time mechanism should be used first for thread updates (polling, SSE, or websockets)?
- Which React routing and state libraries are preferred by the team for long-term maintainability?
- What minimum browser support matrix is required for v1?
- Should markdown rendering include optional split-view source mode in MVP?

# Future Possibilities

- Add live collaboration indicators and presence.
- Add richer thread workflows (labels, triage views, bulk resolution).
- Add keyboard-driven review mode for power users.
- Add reusable UI SDK patterns for other Hermit clients.

# Related Documents

- [ADR-006: Adopt HashiCorp Helios as the UI Design System Baseline](../adr/adr-006-adopt-hashicorp-helios-design-system.md)
- [ADR-007: Expose an OpenAPI-First Hermit API for All GitHub Interactions](../adr/adr-007-openapi-first-hermit-api-for-github-interactions.md)
- [RFC-003: OpenAPI Platform API and GitHub Abstraction Layer](./rfc-003-openapi-platform-api-and-github-abstraction.md)
- [RFC-001: Hermit High-Level Design and Architecture](./rfc-001-hermit-high-level-design-and-architecture.md)
- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
