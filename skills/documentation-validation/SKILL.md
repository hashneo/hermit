---
name: documentation-validation
description: Validate docs-cms content with docuchango and fix schema/format issues before commit.
---

# Documentation Validation Skill

Use this workflow whenever files in `docs-cms/` are added or changed.

## When to Use

- Creating or updating ADRs
- Creating or updating RFCs
- Creating or updating PRDs or memos
- Before committing documentation changes

## Workflow

1. Run validation:

```bash
docuchango validate --verbose
```

2. If there are issues, run auto-fix:

```bash
docuchango fix
docuchango validate --verbose
```

3. Apply manual fixes for anything not auto-corrected:

- missing or invalid frontmatter fields
- broken relative links
- invalid status values
- malformed IDs or UUIDs

4. Re-run validation until clean.

## Verification

- Validation output reports `All documents valid`.

## Related Docs

- `docs-cms/docs-project.yaml`
- `docs-cms/README.md`
