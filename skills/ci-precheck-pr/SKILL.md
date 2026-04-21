---
name: ci-precheck-pr
description: Pre-PR quality and readiness checks before opening or updating a pull request.
---

# CI Precheck (PR)

Run this before opening/updating a PR.

## Workflow

1. Ensure branch is current:

```bash
git status
git branch --show-current
```

2. Run checks for modified scope:

```bash
docuchango validate --verbose
make lint || true
make test || true
```

3. Review what PR contains:

```bash
git log --oneline --decorate -10
git diff main...HEAD
```

4. Ensure no secrets or local-only files are included.

## Verification

- Branch is clean and push-ready.
- Validation/tests for changed areas are complete.
