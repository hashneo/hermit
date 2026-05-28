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

We propose that Hermit source RFC documents from Docuchango docs projects discovered in the repository and require RFC files to conform to Docuchango RFC format.

Hermit discovers the docs project by reading `docs-project.yaml` from the repository root, `docs-cms/`, or `docs/`. When present, that config is authoritative for RFC discovery:

- `structure.doc_types` entries with `schema: rfc` define RFC folders.
- Legacy `structure.rfc_dir` remains the RFC folder when custom document types are not configured.
- `subprojects` are followed so monorepos and submodules can expose their own docs projects.
- `indexes[].targets` are used as additional document discovery patterns for indexed RFC lanes.

If no Docuchango project config is present, Hermit falls back to the configured repository docs path for compatibility.

Canonical RFC files must:

- Follow filename convention `rfc-NNN-short-description.md`.
- Include required frontmatter fields defined by Docuchango templates/schema.
- Pass `docuchango validate` before they are treated as valid RFC inputs.

# Consequences

## Positive

- Establishes one unambiguous source of RFC discovery: the Docuchango project config committed with the repository.
- Supports repositories with nested docs projects, submodules, and indexed document lanes.
- Ensures consistent metadata (id, status, project_id, doc_uuid) across RFC documents.
- Reduces Hermit-specific path policy by reusing Docuchango project metadata.
- Improves interoperability with existing docs workflows and validation tools.

## Negative

- RFC authors must follow Docuchango conventions, which adds process constraints.
- Existing ad hoc RFC files outside configured Docuchango RFC lanes require migration or explicit index targets.
- Future format changes in Docuchango may require synchronized updates in Hermit logic.

## Neutral

- Hermit may index additional document types later, but RFC ingestion remains project-config- and schema-gated.
- Local caching for performance is allowed, but source content remains the repository Docuchango documents.

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
