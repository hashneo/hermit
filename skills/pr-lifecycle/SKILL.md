---
name: pr-lifecycle
description: Standard pull request lifecycle from branch prep through review-ready status.
---

# PR Lifecycle Skill

Use this to create and maintain a high-quality PR.

## Workflow

1. Prepare branch and checks:

```bash
git status
docuchango validate --verbose
```

2. Push branch:

```bash
git push -u origin <branch-name>
```

3. Open PR with clear title/body:

```bash
gh pr create --title "docs: add API abstraction RFC" --body "..."
```

4. Monitor feedback and CI, then iterate.

5. Keep PR description updated as scope evolves.

## Verification

- PR contains focused commits.
- Description explains intent, scope, and validation.
