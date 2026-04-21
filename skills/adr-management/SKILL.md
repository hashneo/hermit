---
name: adr-management
description: Create, update, and supersede ADRs in docs-cms using project naming and validation rules.
---

# ADR Management Skill

Use this workflow when making or documenting architectural decisions.

## Core Rule

For major architectural changes, capture the decision in an ADR first and keep status as `Proposed` until human review confirms acceptance.

## Workflow

1. Check existing ADRs:

```bash
ls docs-cms/adr/
```

2. Copy template and create the next ADR file:

```bash
cp docs-cms/templates/adr-000-template.md docs-cms/adr/adr-NNN-short-title.md
```

3. Fill required frontmatter:

- `title`
- `status` (default `Proposed`)
- `created`
- `deciders`
- `tags`
- `id`
- `project_id`
- `doc_uuid`

4. Fill core sections:

- Context
- Decision
- Consequences
- Alternatives Considered
- References

5. Validate docs:

```bash
docuchango validate --verbose
```

6. If replacing an accepted ADR, create a new ADR and mark links:

- new ADR: `supersedes: adr-XXX`
- old ADR: `status: Superseded`, `superseded_by: adr-NNN`

## Verification

- New ADR appears under `docs-cms/adr/`.
- `docuchango validate --verbose` passes.

## Related Docs

- `docs-cms/templates/adr-000-template.md`
- `docs-cms/adr/`
