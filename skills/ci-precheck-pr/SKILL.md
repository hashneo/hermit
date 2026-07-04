---
name: ci-precheck-pr
description: Pre-PR quality gate matching CI. Run before opening or updating a pull request to ensure all three CI jobs (backend, openapi, ui) will pass.
---

# ci-precheck-pr

Run before opening a PR or after making changes on a feature branch. Mirrors the three CI jobs that must pass for merge.

## Step 1 — Detect scope

```bash
git diff --name-only origin/main...HEAD
```

## Step 2 — Run all applicable gates

### Backend (Go) — mirrors CI `backend` job
```bash
make build                    # go build ./...
go test ./...                 # all unit tests
make test-native-config       # seed-prefs integration tests
python3 -m py_compile scripts/*.py  # Python syntax check
python3 scripts/test-native-seed-prefs.py
```

### OpenAPI — mirrors CI `openapi` job
```bash
npx --yes @redocly/cli@latest lint api/openapi/v1/openapi.yaml
```

### UI — mirrors CI `ui` job
```bash
cd ui && npm ci && npm run build
```

### Docs (if docs-cms/ changed)
```bash
docuchango validate --verbose
```

### Swift (if hermit-native/ changed)
```bash
make gomobile-build      # rebuild xcframework if Go changed
make native-build-macos  # full macOS app build
```

## Step 3 — Final pre-PR verification

```bash
git status                          # no unexpected local changes
git log --oneline origin/main..HEAD # review commit scope
git diff --stat origin/main...HEAD  # confirm what's in the PR
```

## Gate

- [ ] Branch is not `main`
- [ ] `go test ./...` passes with exit 0
- [ ] OpenAPI lint passes
- [ ] UI builds successfully
- [ ] No unexpected files in the diff
- [ ] Commit scope is coherent and reviewable

## Continue with

`pr-lifecycle` when all checks pass.
