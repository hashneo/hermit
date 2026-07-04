---
name: ci-precheck-commit
description: Mandatory quality gate before git commit. Runs build and tests appropriate to the changed files. Fail-closed — do not commit if any check fails.
---

# ci-precheck-commit

Run this skill before every `git commit`. It detects what changed and runs the minimum required checks.

## Step 1 — Detect scope

```bash
git diff --cached --name-only
```

Classify the staged changes:

| Scope | Indicators |
|---|---|
| **docs-only** | All files under `docs-cms/` |
| **scripts-only** | All files under `scripts/` |
| **go** | Any `*.go`, `go.mod`, `go.sum`, `internal/`, `cmd/`, `mobile/` |
| **swift** | Any `*.swift`, `*.xcodeproj`, `hermit-native/` |
| **openapi** | `api/openapi/**` |
| **ui** | `ui/src/**`, `ui/package*.json` |
| **mixed** | Combination of the above |

## Step 2 — Run gates by scope

### Docs-only
```bash
docuchango validate --verbose
```
Fix any errors before committing.

### Scripts-only (Python)
```bash
python3 -m py_compile scripts/*.py
python3 scripts/test-native-seed-prefs.py
```

### Go (including mixed)
```bash
make build          # go build ./...
go test ./...       # full unit suite
make test-native-config  # seed-prefs integration tests
```

### OpenAPI
```bash
npx --yes @redocly/cli@latest lint api/openapi/v1/openapi.yaml
```

### Swift (only if hermit-native/ files staged)
```bash
make native-build-macos
```
> Note: Swift builds are slow (~2 min). Only run when Swift files are staged.

### UI
```bash
cd ui && npm run build
```

## Step 3 — Stage hygiene

- **Never** use `git add .` or `git add -A`
- Stage files explicitly: `git add path/to/file1 path/to/file2`
- Never stage `.beads/`, `scripts/__pycache__/`, `hermit-native/build/`, `HermitNative.app/`
- Never commit directly to `main`

## Commit is allowed only when

- [ ] All applicable checks above passed
- [ ] Only intentional files are staged
- [ ] Branch is not `main`
- [ ] `go test ./...` exit code is 0 (for Go changes)

## Related skills

- `git-checkin` — full commit + push workflow (invokes this skill)
- `ci-precheck-pr` — pre-PR gate (broader scope)
