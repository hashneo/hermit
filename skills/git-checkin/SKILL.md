---
name: git-checkin
description: Create focused commits with explicit file staging and clear messages.
---

# Git Check-In Skill

Use this workflow to produce clean, reviewable commits.

## Workflow

1. Inspect changes:

```bash
git status
git diff
```

2. Stage explicit files only (no broad add patterns):

```bash
git add path/to/file1 path/to/file2
```

3. Commit with a concise conventional message:

```bash
git commit -m "docs: add RFC for repository configuration"
```

4. Verify:

```bash
git status
git log -1 --oneline
```

## Verification

- Commit scope matches intended change.
- Message reflects why the change exists.
