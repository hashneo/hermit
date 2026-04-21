---
title: Adopt HashiCorp Helios as the UI Design System Baseline
status: Proposed
created: 2026-04-21T00:21:29Z
deciders: Engineering Team
tags: [architecture, design-system, frontend]
id: adr-006
project_id: hermit
doc_uuid: 2a52331e-c4e9-4a96-b6ce-40ca2200c177
---

# Context

Hermit requires a consistent, high-quality user interface for document-centric RFC collaboration, including rendered markdown reading, inline comments, and approval actions.

Without a shared design system, the UI may drift in visual language, accessibility behavior, and component quality. As a HashiCorp project, Hermit should align with established internal standards where possible.

# Decision

We propose adopting the HashiCorp Helios design system as the baseline for Hermit UI design and implementation.

Hermit frontend work should prioritize Helios design guidance, component patterns, and interaction principles from:

- https://helios.hashicorp.design/

Custom UI patterns are allowed when required by Hermit-specific workflows, but they should remain visually and behaviorally consistent with Helios conventions.

# Consequences

## Positive

- Improves consistency with HashiCorp brand and product UX standards.
- Speeds up UI implementation by reusing established patterns and components.
- Supports better accessibility and interaction quality through proven design guidance.
- Reduces design debt and ad hoc UI decisions over time.

## Negative

- Some document-centric interactions may need custom implementation beyond existing Helios components.
- Team members must learn Helios patterns and constraints.
- Upstream design system changes may require periodic alignment work.

## Neutral

- This decision sets a design baseline, not a strict prohibition on custom components.
- Hermit-specific UI behavior still requires product and UX validation.

# Alternatives Considered

## Build a Fully Custom Design Language

This allows maximum flexibility for document collaboration UX, but was not chosen because it increases design and engineering overhead and risks inconsistency with HashiCorp product standards.

## Use Generic Third-Party UI Library as Primary Design System

This could accelerate initial component development, but was not chosen because it does not provide the same organizational alignment and brand consistency as Helios.

# References

- [HashiCorp Helios Design System](https://helios.hashicorp.design/)
- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
- [RFC-001: Hermit High-Level Design and Architecture](../rfcs/rfc-001-hermit-high-level-design-and-architecture.md)
