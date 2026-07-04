---
name: pr-resolve
description: Resolve open PR review comments, fix CI failures, and merge. Works on the current branch's PR or a specified PR number.
argument-hint: "[PR_NUMBER]"
---

# pr-resolve

**Usage:** `/pr-resolve` (auto-detect current branch PR) or `/pr-resolve 5`

---

## Step 1 — Identify PR

```bash
PR_NUMBER=${1:-$(gh pr view --json number --jq '.number')}
echo "Working on PR #$PR_NUMBER"
gh pr view $PR_NUMBER --json title,state,headRefName,baseRefName
```

## Step 1.5 — Worktree gate

If the current working directory branch ≠ the PR head branch, use a git worktree to avoid disrupting ongoing work:

```bash
PR_BRANCH=$(gh pr view $PR_NUMBER --json headRefName --jq '.headRefName')
CURRENT=$(git branch --show-current)

if [ "$CURRENT" != "$PR_BRANCH" ]; then
  mkdir -p .tmp/worktrees
  REPO_ROOT=$(git rev-parse --show-toplevel)
  WORKTREE="$REPO_ROOT/.tmp/worktrees/pr-$PR_NUMBER"
  git worktree add "$WORKTREE" "$PR_BRANCH"
  cd "$WORKTREE"
  echo "Working in worktree: $WORKTREE"
  # All subsequent edits, git add, git commit, git push happen here
fi
```

## Step 2 — Check CI

```bash
gh pr checks $PR_NUMBER
```

If `backend`, `openapi`, or `ui` are failing, fix the code issue before addressing review comments. Inspect failures:

```bash
gh run list --branch $PR_BRANCH --limit 3
gh run view <RUN_ID> --log-failed
```

## Step 3 — Fetch all comments and threads

```bash
gh api repos/hashneo/hermit/pulls/$PR_NUMBER/comments --paginate \
  | python3 -c "
import sys,json
for c in json.load(sys.stdin):
    print(f'[{c[\"id\"]}] {c[\"path\"]}:{c.get(\"line\",\"?\")} — {c[\"body\"][:120]}')
" > .tmp/pr-comments-$PR_NUMBER.txt
cat .tmp/pr-comments-$PR_NUMBER.txt

# Fetch unresolved threads
gh api graphql -f query='{ repository(owner:"hashneo",name:"hermit") {
  pullRequest(number: '$PR_NUMBER') { reviewThreads(first:100) {
    nodes { id isResolved isOutdated
      comments(first:1) { nodes { body path line } } } } } } }' \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)['data']['repository']['pullRequest']['reviewThreads']['nodes']
unresolved=[t for t in d if not t['isResolved'] and not t['isOutdated']]
print(f'Unresolved threads: {len(unresolved)}')
for t in unresolved:
    c=t['comments']['nodes'][0] if t['comments']['nodes'] else {}
    print(f'  [{t[\"id\"]}] {c.get(\"path\",\"?\")}:{c.get(\"line\",\"?\")} — {c.get(\"body\",\"\")[:100]}')
"
```

## Step 4 — Triage each comment

| Fix | Reply only |
|---|---|
| Real bug, incorrect logic | Wrong assumption about intent |
| Dead code, unused field | Out-of-scope suggestion |
| Test gap, disabled assertion | Intentional design (cite PR description, ADR, or RFC) |
| Security issue (e.g. open ACL in wrong build config) | Style / naming preference |

## Step 5 — Apply fixes

Edit files, then:
```bash
git add <file1> <file2>    # explicit only — never git add .
git commit -m "fix(<scope>): address PR #$PR_NUMBER review — <description>"
git push origin $PR_BRANCH
```

## Step 6 — Reply to every comment

No comment may be left without a reply:
- **Fixed:** "Fixed in <SHA> — <one sentence>."
- **Disagreed:** Factual explanation.

```bash
# Reply via gh CLI
gh api repos/hashneo/hermit/pulls/$PR_NUMBER/comments/$COMMENT_ID/replies \
  -X POST -f body="Fixed in $(git rev-parse --short HEAD) — <explanation>."
```

## Step 7 — Resolve all threads

```bash
gh api graphql -f query='{ repository(owner:"hashneo",name:"hermit") {
  pullRequest(number: '$PR_NUMBER') { reviewThreads(first:100) {
    nodes { id isResolved isOutdated } } } } }' | \
  python3 -c "
import sys,json
threads=json.load(sys.stdin)['data']['repository']['pullRequest']['reviewThreads']['nodes']
for t in threads:
  if not t['isResolved'] and not t['isOutdated']: print(t['id'])
" | while read id; do
  gh api graphql -f query="mutation {
    resolveReviewThread(input:{threadId:\"$id\"}) { thread { isResolved } } }" \
    | python3 -c "import sys,json; print('resolved' if json.load(sys.stdin)['data']['resolveReviewThread']['thread']['isResolved'] else 'failed')"
done
```

## Step 8 — Wait for CI

```bash
# Poll until all checks pass (max ~10 min)
for i in $(seq 1 20); do
  STATUS=$(gh pr checks $PR_NUMBER 2>/dev/null | grep -v "^$" | awk '{print $2}' | sort -u)
  echo "[$i] $STATUS"
  echo "$STATUS" | grep -q "fail" && break
  echo "$STATUS" | grep -qv "pending\|in_progress" && echo "All done" && break
  sleep 30
done
gh pr checks $PR_NUMBER
```

## Step 9 — Check for new comments

After CI re-runs, Copilot may add new comments. Repeat Steps 3–8 if new unresolved threads appear.

## Step 10 — Merge

```bash
gh pr merge $PR_NUMBER --squash
```

If still blocked by unresolved threads (GitHub cache lag):
```bash
gh pr merge $PR_NUMBER --squash --auto
```

## Step 11 — Cleanup

```bash
# Exit worktree if used
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || git -C "$WORKTREE" rev-parse --show-toplevel)
cd "$REPO_ROOT"
git worktree remove .tmp/worktrees/pr-$PR_NUMBER 2>/dev/null || true

git checkout main
git pull origin main
git branch -d "$PR_BRANCH" 2>/dev/null || true
git push origin --delete "$PR_BRANCH" 2>/dev/null || true
```
