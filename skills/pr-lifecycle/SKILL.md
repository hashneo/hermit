---
name: pr-lifecycle
description: End-to-end PR workflow for Hermit — from create through CI, Copilot review, thread resolution, and merge.
---

# pr-lifecycle

## Step 1 — Pre-flight

Run the branch safety gate (see `git-checkin` Step 0a), then:

```bash
git fetch origin
git log --oneline origin/main..HEAD   # confirm scope
git diff --stat origin/main...HEAD    # confirm files
```

Run `ci-precheck-pr`. Do not open a PR if checks fail.

## Step 2 — Push branch

```bash
git push -u origin $(git branch --show-current)
```

## Step 3 — Create PR

Write the PR body to `.tmp/pr-body.md` using the Write file tool:

```markdown
## Summary
<what this PR does and why>

## Changes
- <key change 1>
- <key change 2>

## Testing
- <how it was tested>
- `go test ./...` — pass
- CI: backend / openapi / ui — pass

## Notes
<breaking changes, follow-ups, related issues>
```

Create the PR:
```bash
gh pr create \
  --base main \
  --title "<type>(<scope>): <summary>" \
  --body-file .tmp/pr-body.md
rm .tmp/pr-body.md
```

Verify:
```bash
gh pr view --json number,url,baseRefName
```

> **Gate:** base branch must be `main`. If it isn't, re-create with `--base main`.

## Step 4 — Wait for CI and Copilot review

```bash
gh pr checks    # poll until backend / openapi / ui all pass
```

Copilot will automatically post a review. Wait for it to appear before proceeding.

## Step 5 — Fetch all review comments

```bash
PR_NUMBER=$(gh pr view --json number --jq '.number')
gh api repos/hashneo/hermit/pulls/$PR_NUMBER/comments --paginate \
  | python3 -c "
import sys,json
# --paginate emits one JSON array per page; merge all into one list
import re,io
text=sys.stdin.read()
all_items=[]
for block in re.findall(r'\[.*?\]', text, re.DOTALL):
    try: all_items.extend(json.loads(block))
    except: pass
print(json.dumps(all_items))
" > .tmp/pr-comments-$PR_NUMBER.json
```

Also fetch inline review threads:
```bash
gh api graphql -f query='{ repository(owner:"hashneo",name:"hermit") {
  pullRequest(number: '$PR_NUMBER') {
    reviewThreads(first:50) { nodes { id isResolved comments(first:1) {
      nodes { body path line } } } } } } }' > .tmp/pr-threads.json
```

## Step 6 — Triage each comment

| Fix | Reply only |
|---|---|
| Real bug or correctness issue | Wrong assumption about the codebase |
| Dead code, unused variable | Out-of-scope suggestion |
| Test coverage gap | Intentional design decision |
| Simple improvement (≤30 lines) | Style preference disagreement |

## Step 7 — Apply fixes and commit

For each fix:
```bash
# Edit files
git add <file>   # explicit only
git commit -m "fix(<scope>): address review comment — <brief description>"
git push origin $(git branch --show-current)
```

## Step 8 — Reply to every comment

- **Fixed:** "Fixed in <commit SHA> — <one sentence explaining the change>."
- **Disagreed:** Factual explanation citing ADR, RFC, or concrete constraint.

No comment may be left without a reply.

## Step 9 — Resolve all threads

Resolve every thread via the GitHub UI or GraphQL:
```bash
# Get unresolved thread IDs
gh api graphql -f query='{ repository(owner:"hashneo",name:"hermit") {
  pullRequest(number: '$PR_NUMBER') { reviewThreads(first:100) {
    nodes { id isResolved isOutdated } } } } }' | \
  python3 -c "
import sys,json
threads=json.load(sys.stdin)['data']['repository']['pullRequest']['reviewThreads']['nodes']
for t in threads:
  if not t['isResolved'] and not t['isOutdated']: print(t['id'])
" | while read id; do
  gh api graphql -f query="mutation { resolveReviewThread(input:{threadId:\"$id\"}) { thread { isResolved } } }"
done
```

**All threads must be resolved before merge.**

## Step 10 — Iterate

After pushing fixes, wait for CI to re-run:
```bash
gh pr checks   # confirm backend / openapi / ui still pass
```

Check for new Copilot comments triggered by the push. Repeat Steps 5–9 if found.

## Step 11 — Merge

```bash
gh pr merge $PR_NUMBER --squash
```

If auto-merge is needed (threads resolving in background):
```bash
gh pr merge $PR_NUMBER --squash --auto
```

> Do not self-merge unless explicitly instructed.

## Step 12 — Cleanup

```bash
# Capture the branch name BEFORE switching away from it
MERGED_BRANCH=$(git branch --show-current)
git checkout main
git pull origin main
git branch -d "$MERGED_BRANCH"
git push origin --delete "$MERGED_BRANCH" 2>/dev/null || true
```
