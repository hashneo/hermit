---
name: pr-resolve
description: Triage and resolve pull request comments with minimal, traceable follow-up commits.
---

# PR Resolve Skill

Use this when a PR has review comments.

## Workflow

1. Collect comment context:

```bash
gh pr view --comments
```

2. Group feedback by theme (bug, style, docs, tests).

3. Implement focused fixes and re-run relevant checks.

4. Commit and push follow-up changes.

5. Reply to comments with what changed and why.

## Verification

- All actionable comments addressed or explicitly discussed.
- New commits are scoped and easy to review.
