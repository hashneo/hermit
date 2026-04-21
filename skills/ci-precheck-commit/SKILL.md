---
name: ci-precheck-commit
description: Run a strict local pre-commit gate aligned with repository quality expectations.
---

# CI Precheck (Commit)

Run this before creating a commit.

## Workflow

1. Confirm working tree state:

```bash
git status
```

2. Run docs validation if `docs-cms/` changed:

```bash
docuchango validate --verbose
```

3. Run project checks as available:

```bash
# Prefer Makefile targets when present
make fmt || true
make lint || true
make test || true
```

4. Fix issues, then re-run relevant checks.

## Verification

- Local checks pass for changed scope.
- No unexpected generated or temporary files are staged.
