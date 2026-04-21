---
title: Source RFC Documents from docs-cms and Enforce Docuchango Format
status: Proposed
created: 2026-04-21T00:17:13Z
deciders: Engineering Team
tags: [architecture, docs, rfc]
id: adr-004
project_id: hermit
doc_uuid: 684cdf16-ecf6-42f8-9869-94da80b01d3a
---

# Context

Hermit is a document-first collaboration product for RFC review, and its workflows depend on consistent RFC structure, metadata, and discoverability.

The project already uses Docuchango with a `docs-cms` layout and templates for ADRs, RFCs, memos, and PRDs. To avoid ambiguous sources and schema drift, Hermit needs a canonical location and format for RFC documents.

# Decision

We propose that Hermit source RFC documents from the Docuchango `docs-cms` path and require RFC files to conform to Docuchango RFC format.

For this project, canonical RFC files live under `docs-cms/rfcs/` and must:

- Follow filename convention `rfc-NNN-short-description.md`.
- Include required frontmatter fields defined by Docuchango templates/schema.
- Pass `docuchango validate` before they are treated as valid RFC inputs.

# Consequences

## Positive

- Establishes one unambiguous source path for RFC content used by Hermit.
- Ensures consistent metadata (id, status, project_id, doc_uuid) across RFC documents.
- Reduces parsing and ingestion complexity in the application.
- Improves interoperability with existing docs workflows and validation tools.

## Negative

- RFC authors must follow Docuchango conventions, which adds process constraints.
- Existing ad hoc RFC files outside `docs-cms/rfcs/` require migration or are excluded.
- Future format changes in Docuchango may require synchronized updates in Hermit logic.

## Neutral

- Hermit may index additional document types later, but RFC ingestion remains path- and schema-gated.
- Local caching for performance is allowed, but source content remains the repository `docs-cms/rfcs/` documents.

# Alternatives Considered

## Allow RFC Files Anywhere in Repository

This offers flexibility for teams with mixed repo structures, but was not chosen because discovery and validation become inconsistent, and it increases ambiguity about which files are canonical RFCs.

## Use a Hermit-Specific RFC Format

A custom format could optimize Hermit internals, but was not chosen because it duplicates existing Docuchango capabilities and creates unnecessary divergence in project documentation practices.

# References

- [PRD-001: Hermit Vision - RFC PR Collaboration Experience](../prd/prd-001-hermit-rfc-collaboration-vision.md)
- [RFC-001: Hermit High-Level Design and Architecture](../rfcs/rfc-001-hermit-high-level-design-and-architecture.md)
- [ADR-003: Use GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [docs-cms Project Config](../docs-project.yaml)
