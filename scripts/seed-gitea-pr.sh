#!/usr/bin/env bash
set -euo pipefail

GITEA_BASE_URL="${GITEA_BASE_URL:-http://localhost:3000}"
GITEA_API_BASE="${GITEA_API_BASE:-${GITEA_BASE_URL}/api/v1}"
GITEA_CONTAINER="${GITEA_CONTAINER:-hermit-gitea}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea_admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-gitea_admin}"
GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-gitea_admin@example.com}"
GITEA_TEST_REPO="${GITEA_TEST_REPO:-hermit-rfcs}"
GITEA_MAIN_BRANCH="${GITEA_MAIN_BRANCH:-main}"
GITEA_PR_BRANCH="${GITEA_PR_BRANCH:-feat/rfc-002-seeded-pr-review}"
SEED_WORKDIR="${SEED_WORKDIR:-.tmp/gitea-seed}"

wait_for_gitea() {
  local max_attempts=60
  local attempt=1

  # Wait for the API version endpoint — the root page responds before the API
  # is fully initialised, which causes transient 404s on the first API call.
  while [ "$attempt" -le "$max_attempts" ]; do
    if curl -fsS "${GITEA_API_BASE}/version" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done

  printf 'Gitea API did not become ready at %s\n' "${GITEA_API_BASE}" >&2
  return 1
}

ensure_admin_user() {
  if docker exec -u git "${GITEA_CONTAINER}" gitea admin user create \
    --username "${GITEA_ADMIN_USER}" \
    --password "${GITEA_ADMIN_PASS}" \
    --email "${GITEA_ADMIN_EMAIL}" \
    --admin \
    --must-change-password=false >/dev/null 2>&1; then
    printf 'Created Gitea admin user %s\n' "${GITEA_ADMIN_USER}"
    return 0
  fi

  printf 'Gitea admin user %s already exists or could not be created; continuing\n' "${GITEA_ADMIN_USER}"
}

ensure_repo() {
  local repo_status
  repo_status=$(curl -s -o /dev/null -w '%{http_code}' -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" "${GITEA_API_BASE}/repos/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}")
  if [ "${repo_status}" = "200" ]; then
    printf 'Gitea repo %s/%s already exists\n' "${GITEA_ADMIN_USER}" "${GITEA_TEST_REPO}"
    return 0
  fi

  curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -H 'Content-Type: application/json' \
    -X POST "${GITEA_API_BASE}/user/repos" \
    -d "{\"name\":\"${GITEA_TEST_REPO}\",\"private\":false,\"auto_init\":false,\"default_branch\":\"${GITEA_MAIN_BRANCH}\"}" >/dev/null

  printf 'Created Gitea repo %s/%s\n' "${GITEA_ADMIN_USER}" "${GITEA_TEST_REPO}"
}

seed_git_history() {
  local remote_url
  local repo_dir
  local remote_has_pr_branch

  rm -rf "${SEED_WORKDIR}"
  mkdir -p "${SEED_WORKDIR}"

  remote_url="${GITEA_BASE_URL#http://}"
  remote_url="${remote_url#https://}"
  remote_url="http://${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}@${remote_url}/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}.git"
  repo_dir="${SEED_WORKDIR}/${GITEA_TEST_REPO}"

  git clone "${remote_url}" "${repo_dir}" >/dev/null 2>&1 || {
    git init "${repo_dir}" >/dev/null
    git -C "${repo_dir}" remote add origin "${remote_url}"
  }

  git -C "${repo_dir}" config user.name "Hermit Seed Bot"
  git -C "${repo_dir}" config user.email "seed-bot@hermit.local"
  git -C "${repo_dir}" fetch origin >/dev/null 2>&1 || true

  mkdir -p "${repo_dir}/docs-cms/rfcs"
  cat >"${repo_dir}/docs-cms/rfcs/rfc-001-seeded-main-branch.md" <<'EOF'
---
title: RFC-001 Go Hello World Baseline Service
status: implemented
author: Hermit Seed Bot
created: 2026-04-21T00:00:00Z
id: rfc-001
project_id: hermit
doc_uuid: 11111111-1111-1111-1111-111111111111
---

# RFC-001 Go Hello World Baseline Service

## Summary

Define a minimal Go HTTP service that returns `hello world` and establish a simple production-ready baseline (health endpoint, logging, and container build).

## Problem

Teams need a canonical "smallest useful service" to validate developer onboarding, CI, packaging, and runtime observability patterns.

## Decision

Implement a single binary Go service using the standard library with two routes:

- `GET /` returns `hello world`
- `GET /healthz` returns JSON health payload

## Implementation Notes

```go
package main

import (
  "encoding/json"
  "log"
  "net/http"
)

func main() {
  mux := http.NewServeMux()
  mux.HandleFunc("GET /", func(w http.ResponseWriter, _ *http.Request) {
    _, _ = w.Write([]byte("hello world"))
  })
  mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    _ = json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
  })
  log.Fatal(http.ListenAndServe(":8080", mux))
}
```

## Status

This RFC is implemented and retained on main as the canonical baseline reference.
EOF

  git -C "${repo_dir}" checkout -B "${GITEA_MAIN_BRANCH}" >/dev/null
  git -C "${repo_dir}" add docs-cms/rfcs/rfc-001-seeded-main-branch.md
  if ! git -C "${repo_dir}" diff --cached --quiet; then
    git -C "${repo_dir}" commit -m "seed: add main branch RFC" >/dev/null
  fi
  git -C "${repo_dir}" push -u origin "${GITEA_MAIN_BRANCH}" >/dev/null

  remote_has_pr_branch="0"
  if git -C "${repo_dir}" ls-remote --exit-code --heads origin "${GITEA_PR_BRANCH}" >/dev/null 2>&1; then
    remote_has_pr_branch="1"
  fi

  if [ "${remote_has_pr_branch}" = "1" ]; then
    git -C "${repo_dir}" checkout -B "${GITEA_PR_BRANCH}" "origin/${GITEA_PR_BRANCH}" >/dev/null
  else
    git -C "${repo_dir}" checkout -B "${GITEA_PR_BRANCH}" "${GITEA_MAIN_BRANCH}" >/dev/null
  fi

  cat >"${repo_dir}/docs-cms/rfcs/rfc-002-seeded-pr-review.md" <<'EOF'
---
title: RFC-002 Hello World Go App v2 Proposal
status: draft
author: Hermit Seed Bot
created: 2026-04-21T00:05:00Z
id: rfc-002
project_id: hermit
doc_uuid: 22222222-2222-2222-2222-222222222222
---

# RFC-002 Hello World Go App v2 Proposal

## Summary

Propose a more complete Go-based Hello World service that introduces structured logging, graceful shutdown, and a small configuration surface while keeping runtime complexity low.

## Goals

- Keep implementation approachable for new contributors.
- Provide a realistic shape for production service scaffolding.
- Demonstrate routing, config, logging, and operational endpoints.

## Non-Goals

- No database integration.
- No authentication/authorization.
- No distributed tracing in this phase.

## API

| Method | Path | Description |
| --- | --- | --- |
| GET | `/` | Returns hello payload |
| GET | `/healthz` | Liveness/readiness health |
| GET | `/version` | Build and commit metadata |

### Example Response

```json
{
  "message": "hello world",
  "service": "hello-go",
  "environment": "development"
}
```

## Proposed Design

The app remains a single process with explicit startup/shutdown lifecycle.

```mermaid
flowchart TD
  A[Process Start] --> B[Load Config]
  B --> C[Build HTTP Router]
  C --> D[Start Listener]
  D --> E[Serve Requests]
  E --> F[Receive SIGTERM]
  F --> G[Graceful Shutdown]
```

## Detailed Implementation

```go
type Config struct {
  ListenAddress string
  Environment   string
}

func NewConfig() Config {
  return Config{
    ListenAddress: envOrDefault("LISTEN_ADDRESS", ":8080"),
    Environment:   envOrDefault("APP_ENV", "development"),
  }
}
```

```go
func helloHandler(cfg Config) http.HandlerFunc {
  return func(w http.ResponseWriter, _ *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    _ = json.NewEncoder(w).Encode(map[string]string{
      "message": "hello world",
      "service": "hello-go",
      "environment": cfg.Environment,
    })
  }
}
```

## Operational Considerations

- Log one structured line per request with status code and latency.
- Return `503` from `/healthz` if shutdown has started.
- Bound shutdown timeout to 10s.

## Rollout Plan

1. Land core handlers and config.
2. Add request logging middleware.
3. Add Dockerfile and CI smoke test.
4. Verify startup and shutdown behavior in local docker-compose.

## Risks and Mitigations

- **Risk:** over-engineering a simple app.
  - **Mitigation:** keep dependencies to standard library only.
- **Risk:** inconsistent local environment setup.
  - **Mitigation:** provide one-command Make target and documented env defaults.

## Open Questions

- Should `/version` expose git SHA in non-production environments only?
- Do we want a `GET /readyz` endpoint separate from `/healthz`?
EOF

  git -C "${repo_dir}" add docs-cms/rfcs/rfc-002-seeded-pr-review.md
  if ! git -C "${repo_dir}" diff --cached --quiet; then
    git -C "${repo_dir}" commit -m "seed: add RFC for PR review" >/dev/null
  fi
  git -C "${repo_dir}" push -u origin "${GITEA_PR_BRANCH}" >/dev/null
}

ensure_label() {
  local label_name="${1}"
  local label_color="${2}"
  local label_desc="${3}"

  local labels_json
  labels_json=$(curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    "${GITEA_API_BASE}/repos/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}/labels")

  local existing
  existing=$(python3 -c "
import sys, json
labels = json.loads(sys.argv[1])
target = sys.argv[2]
for l in labels:
    if l['name'] == target:
        print(l['id'])
        break
" "${labels_json}" "${label_name}" 2>/dev/null || true)

  if [ -n "${existing}" ]; then
    printf 'Label "%s" already exists (id=%s)\n' "${label_name}" "${existing}" >&2
    echo "${existing}"
    return 0
  fi

  local create_response
  create_response=$(curl -s -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -H 'Content-Type: application/json' \
    -X POST "${GITEA_API_BASE}/repos/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}/labels" \
    -d "$(printf '{"name":"%s","color":"%s","description":"%s"}' "${label_name}" "${label_color}" "${label_desc}")")

  local label_id
  label_id=$(echo "${create_response}" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)

  if [ -z "${label_id}" ]; then
    printf 'Failed to create label "%s": %s\n' "${label_name}" "${create_response}" >&2
    return 1
  fi

  printf 'Created label "%s" (id=%s)\n' "${label_name}" "${label_id}" >&2
  echo "${label_id}"
}

apply_label_to_pr() {
  local pr_number="${1}"
  local label_id="${2}"

  local labels_json
  labels_json=$(curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    "${GITEA_API_BASE}/repos/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}/issues/${pr_number}/labels")

  local already_labeled
  already_labeled=$(python3 -c "
import sys, json
labels = json.loads(sys.argv[1])
lid = int(sys.argv[2])
print('1' if any(l['id'] == lid for l in labels) else '0')
" "${labels_json}" "${label_id}" 2>/dev/null || echo "0")

  if [ "${already_labeled}" = "1" ]; then
    printf 'PR #%s already has label id=%s\n' "${pr_number}" "${label_id}"
    return 0
  fi

  curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -H 'Content-Type: application/json' \
    -X POST "${GITEA_API_BASE}/repos/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}/issues/${pr_number}/labels" \
    -d "{\"labels\":[${label_id}]}" >/dev/null

  printf 'Applied label id=%s to PR #%s\n' "${label_id}" "${pr_number}"
}

ensure_pull_request() {
  local has_pr
  local pulls
  local attempt

  # Retry loop: after a fresh git push Gitea may not have indexed the repo
  # yet, causing transient 404s on the pulls endpoint.
  for attempt in $(seq 1 15); do
    pulls=$(curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
      "${GITEA_API_BASE}/repos/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}/pulls?state=open" 2>/dev/null) && break
    sleep 1
  done

  has_pr=$(python3 - <<'PY' "${pulls}" "${GITEA_PR_BRANCH}" "${GITEA_MAIN_BRANCH}"
import json
import sys

payload = json.loads(sys.argv[1])
head = sys.argv[2]
base = sys.argv[3]

for pr in payload:
    if pr.get("head", {}).get("ref") == head and pr.get("base", {}).get("ref") == base:
        print("1")
        break
else:
    print("0")
PY
)

  if [ "${has_pr}" = "1" ]; then
    printf 'Seed PR already exists for %s -> %s\n' "${GITEA_PR_BRANCH}" "${GITEA_MAIN_BRANCH}"
    return 0
  fi

  curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
    -H 'Content-Type: application/json' \
    -X POST "${GITEA_API_BASE}/repos/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}/pulls" \
    -d "{\"title\":\"Seeded RFC review PR\",\"head\":\"${GITEA_PR_BRANCH}\",\"base\":\"${GITEA_MAIN_BRANCH}\",\"body\":\"Seeded by scripts/seed-gitea-pr.sh for Hermit testing.\",\"draft\":false}" >/dev/null

  printf 'Created seed PR for %s/%s\n' "${GITEA_ADMIN_USER}" "${GITEA_TEST_REPO}"
}

wait_for_gitea
ensure_admin_user
ensure_repo
seed_git_history
ensure_pull_request

RFC_READY_LABEL_ID=$(ensure_label "hermit:rfc-ready" "#0075ca" "Marks a PR as ready for RFC review in Hermit")

SEED_PR_NUMBER=$(curl -fsS -u "${GITEA_ADMIN_USER}:${GITEA_ADMIN_PASS}" \
  "${GITEA_API_BASE}/repos/${GITEA_ADMIN_USER}/${GITEA_TEST_REPO}/pulls?state=open&limit=20" \
  | python3 -c "
import sys, json
prs = json.load(sys.stdin)
for pr in prs:
    if pr.get('head', {}).get('ref') == '${GITEA_PR_BRANCH}':
        print(pr['number'])
        break
" 2>/dev/null || true)

if [ -n "${SEED_PR_NUMBER}" ]; then
  apply_label_to_pr "${SEED_PR_NUMBER}" "${RFC_READY_LABEL_ID}"
else
  printf 'Warning: could not find seed PR to apply label\n' >&2
fi

printf 'Seed complete: %s/%s with open PR from %s to %s\n' "${GITEA_ADMIN_USER}" "${GITEA_TEST_REPO}" "${GITEA_PR_BRANCH}" "${GITEA_MAIN_BRANCH}"
