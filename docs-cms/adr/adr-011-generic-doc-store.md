---
title: Generic Doc Store for All Docuchango Document Types
status: Proposed
created: 2026-07-16T00:00:00Z
updated: 2026-10-14T00:00:00Z
deciders: Engineering Team
tags: [architecture, catalog, docs, native]
id: adr-011
project_id: hermit
doc_uuid: 571fff1f-6e6c-48a0-9c40-bc9a443f2397
---

# Context

Hermit's docs-cms (Docuchango) catalog contains several document types — ADR, RFC, PRD, and memo, plus ad-hoc guides — but the product surface is RFC-centric:

- **Server.** The catalog response (`CatalogItem`) already carries a `document_type` for every item and the Docuchango machinery (`docuchangoDocumentMatcher`, `normalizeDocuchangoDocType`, `docuchangoReviewTypeSortOrder`) already understands all configured types. The **PR-side** review listing (`ListReviewReadyRFCs`) already emits ADR/PRD/memo items. However the **main-branch** listing is hard-filtered to `rfc-NNN` filenames (`isDocuchangoRFCFilename`, the `^rfc-[0-9]{3}-…\.md$` regex), so ADRs, PRDs, and memos never appear in the browsable catalog regardless of the client.
- **Native.** The Swift models (`RFC`, `RFCFile`, `RFCPullRequest`) are RFC in name only — nearly every field is generic-document. Two real gaps exist: (1) `RFCFile` and the unified `RFC` carry **no `documentType`**, so main-branch items silently drop the type at decode time; (2) the on-device cache `RepoRFCCache` is keyed by repository, not by document type, so callers cannot ask "show me this repo's ADRs" cleanly. Three helpers encode RFC-specific filename semantics (`primaryPRDocuments` filters to `rfc`; `isRFCDocumentPath`; `rfcNumberFromPath`).

A "store that can deal with any docs-cms doc type cleanly" therefore requires three coordinated changes: the server must stop hiding non-RFC documents, the native models must retain `documentType`, and the on-device store must be doc-type-aware.

# Decision

Generalize the RFC catalog into a **doc-type-aware document store** across server and native, in a foundation pass that keeps the existing `RFC*` Swift symbols as aliases (a cosmetic `RFC`→`Doc` rename is deferred to a later PR to limit churn).

1. **Server: serve all configured doc types on the main branch.** Replace the `isDocuchangoRFCFilename` gate on the main-branch path with the existing `docuchangoDocumentMatcher` plus a generic `prefix-NNN-slug.md` check. The Docuchango project config (`document_folders` / `*_dir` / `doc_types`) already enumerates which folders to scan; the server walks every configured folder instead of only `docs-cms/rfcs`. Existing repository `docs_path` values remain compatible: project-config discovery scans all declared document folders regardless of the fallback path.

2. **Native: retain `documentType` end to end.** Add `documentType: String` to `RFCFile` and to the unified `RFC`, and stop dropping it in `discoverRFCs()` decoding. Thread it through the cache wrappers so it persists across launches.

3. **Native: introduce a doc-type-aware store.** Expose `DocStore` as an alias of `RepoRFCCache`, retaining one cache entry per repository and providing document-type-filtered sections and a per-repo aggregate. The persisted UserDefaults key migrates from `hermit.menuBar.rfcProjectionCache.v1` to `…docProjectionCache.v2` (versioned so old caches do not decode as the wrong shape). Existing `RFCSections` and `RepoRFCCache` names remain available for this pass.

4. **Native: generalize the RFC filename helpers.** Replace `isRFCDocumentPath`/`rfcNumberFromPath`/`primaryPRDocuments` with doc-type-parameterized equivalents (`isDocumentPath(_:docType:)`, `documentNumberFromPath(_:docType:)`) keyed off the same `prefix-NNN` convention the server's `fallbackDocuchangoDocTypes` already assumes (adr/memo/prd/rfc).

5. **Wire/HTTP stability.** The route paths (`/api/v1/.../rfcs`) and Go package name (`internal/rfc`) are **not** renamed in this pass — they remain compatible wire contracts. Only the catalog *contents* broaden. A future ADR can rename the route/package if desired.

# Consequences

## Positive

- ADRs, PRDs, and memos become first-class browsable documents, not just reviewable PR payloads.
- The native store can answer per-type queries cleanly (`docs(for: repo, type: "adr")`), enabling type-filtered/grouped UI without bespoke logic.
- Server and native converge on one document taxonomy already defined by Docuchango, removing the implicit "RFC is special" assumption.

## Negative

- One cache-format migration: the v1 UserDefaults projection cache is invalidated in favor of v2 (a cold re-fetch on first launch after upgrade).
- Broadening the main-branch catalog increases the number of files enumerated and frontmatter-fetched per refresh; mitigated by the existing workset SQLite cache and per-repo TTLs.
- Keeping `RFC*` aliases is a transitional compromise — callers must learn that `RFC` now means "any document" until the rename PR lands.

## Neutral

- GitHub remains source of truth (ADR-003); this only changes *which* documents under it are surfaced.
- The PAT/auth model (ADR-005) and the Docuchango doc-source/format (ADR-004) are unchanged.

# Alternatives Considered

## Keep main-branch listing RFC-only; only generalize the native cache

Rejected: a doc-type-keyed store that the server can only fill with RFCs delivers no user-visible multi-doctype value and would mislead callers into thinking ADR/PRD queries can succeed.

## Full `RFC`→`Doc` rename in the same pass

Deferred: the rename touches ~25 types and ~12 functions across native with no behavioral change. Bundling it with the semantic changes inflates the diff and review surface. Doing semantics first (this ADR) and cosmetics next keeps each PR reviewable.

## Re-key the store by document type only (no repo)

Rejected: every existing caller (dashboard, viewer, recents) is repo-scoped first; `(repoID, documentType)` preserves that access pattern while adding the type dimension.

# References

- [ADR-003: GitHub as the Source of Truth](./adr-003-github-source-of-truth.md)
- [ADR-004: RFC Doc Source and Format](./adr-004-rfc-doc-source-and-format.md)
- [ADR-009: Hermit API as Canonical Native Client Interface](./adr-009-hermit-api-as-canonical-native-client-interface.md)