#!/usr/bin/env bash
# install-keychain-pat.sh
#
# Installs the Gitea PAT and Hermit server config into the macOS Keychain so
# HermitNative can read them at runtime without needing embedded DevConfig files.
#
# Key/account names mirror KeychainHelper.swift so the Swift app finds them:
#
#   hermit.pat           — Gitea PAT
#   hermit.base-url      — Gitea API base URL   (e.g. http://localhost:3000/api/v1)
#   hermit.server-base-url — Hermit Go server   (e.g. http://localhost:8080)
#   hermit.repo-owner    — e.g. gitea_admin
#   hermit.repo-name     — e.g. hermit-rfcs
#   hermit.docs-path     — e.g. docs-cms/rfcs
#   hermit.rfc-label     — e.g. hermit:rfc-ready
#
# Usage:
#   scripts/install-keychain-pat.sh [PAT] [HERMIT_YAML_PATH]
#
# When called with no arguments it reads the PAT from .tmp/gitea-token.env
# and the config from config/hermit.yaml (both relative to the repo root,
# which is the parent of this script's directory).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Resolve PAT ───────────────────────────────────────────────────────────────

PAT="${1:-}"

if [ -z "${PAT}" ]; then
    TOKEN_ENV="${REPO_ROOT}/.tmp/gitea-token.env"
    if [ -f "${TOKEN_ENV}" ]; then
        # shellcheck disable=SC1090
        . "${TOKEN_ENV}"
        PAT="${GITEA_TOKEN:-}"
    fi
fi

if [ -z "${PAT}" ]; then
    printf 'ERROR: No PAT provided and .tmp/gitea-token.env not found or empty.\n' >&2
    printf 'Run "make gitea-up" first, or pass the token as the first argument.\n' >&2
    exit 1
fi

# ── Resolve config values from hermit.yaml ────────────────────────────────────

HERMIT_YAML="${2:-${REPO_ROOT}/config/hermit.yaml}"

if [ ! -f "${HERMIT_YAML}" ]; then
    printf 'ERROR: config/hermit.yaml not found at %s\n' "${HERMIT_YAML}" >&2
    exit 1
fi

# Extract the gitea-local registry base_url (localhost or gitea)
GITEA_BASE_URL=$(awk '
    /base_url:/ && (prev_base ~ /localhost/ || prev_base ~ /gitea/) { found=1 }
    /base_url:/ {
        split($0, a, ": ")
        gsub(/[[:space:]]/, "", a[2])
        prev_base = a[2]
        val = a[2]
    }
    END { if (val) print val }
' "${HERMIT_YAML}" || true)

# Simpler: grab the base_url from the gitea-local block specifically
GITEA_BASE_URL=$(python3 - "${HERMIT_YAML}" <<'PY'
import sys, re

with open(sys.argv[1]) as f:
    content = f.read()

# Find registries block and extract the entry with localhost/gitea base_url
in_registry = False
current = {}
registries = []

for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('- name:'):
        if current:
            registries.append(dict(current))
        current = {'name': stripped.split(':', 1)[1].strip()}
    elif stripped.startswith('kind:'):
        current['kind'] = stripped.split(':', 1)[1].strip()
    elif stripped.startswith('base_url:'):
        current['base_url'] = stripped.split(':', 1)[1].strip()
    elif stripped.startswith('token_env_var:'):
        current['token_env_var'] = stripped.split(':', 1)[1].strip()

if current:
    registries.append(current)

for r in registries:
    base = r.get('base_url', '')
    if 'localhost' in base or 'gitea' in base:
        print(base)
        break
PY
)

if [ -z "${GITEA_BASE_URL}" ]; then
    printf 'WARN: Could not detect Gitea base_url from hermit.yaml; defaulting to http://localhost:3000/api/v1\n' >&2
    GITEA_BASE_URL="http://localhost:3000/api/v1"
fi

# Extract the Hermit server listen address
HERMIT_SERVER_URL=$(python3 - "${HERMIT_YAML}" <<'PY'
import sys
with open(sys.argv[1]) as f:
    for line in f:
        stripped = line.strip()
        if stripped.startswith('listen_address:'):
            val = stripped.split(':', 1)[1].strip().strip('"\'')
            port = val.split(':')[-1]
            print(f"http://localhost:{port}")
            break
PY
)
HERMIT_SERVER_URL="${HERMIT_SERVER_URL:-http://localhost:8080}"

# Extract the first gitea-backed repo
read -r REPO_OWNER REPO_NAME DOCS_PATH RFC_LABEL < <(python3 - "${HERMIT_YAML}" <<'PY'
import sys

with open(sys.argv[1]) as f:
    content = f.read()

# Find gitea-local registry name first
gitea_registry = None
current = {}
registries = []
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('- name:'):
        if current:
            registries.append(dict(current))
        current = {'name': stripped.split(':', 1)[1].strip()}
    elif stripped.startswith('kind:'):
        current['kind'] = stripped.split(':', 1)[1].strip()
    elif stripped.startswith('base_url:'):
        current['base_url'] = stripped.split(':', 1)[1].strip()
if current:
    registries.append(current)

for r in registries:
    base = r.get('base_url', '')
    if 'localhost' in base or 'gitea' in base:
        gitea_registry = r['name']
        break

if not gitea_registry:
    sys.exit(1)

# Find first repository using that registry
current_repo = {}
repos = []
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('- owner:'):
        if current_repo:
            repos.append(dict(current_repo))
        current_repo = {'owner': stripped.split(':', 1)[1].strip()}
    elif stripped.startswith('name:') and current_repo:
        current_repo['name'] = stripped.split(':', 1)[1].strip()
    elif stripped.startswith('registry:') and current_repo:
        current_repo['registry'] = stripped.split(':', 1)[1].strip()
    elif stripped.startswith('docs_path_policy:') and current_repo:
        current_repo['docs_path'] = stripped.split(':', 1)[1].strip().strip('/')
if current_repo:
    repos.append(current_repo)

for r in repos:
    if r.get('registry') == gitea_registry:
        owner = r.get('owner', '')
        name = r.get('name', '')
        docs = r.get('docs_path', 'docs-cms/rfcs')
        print(owner, name, docs, 'hermit:rfc-ready')
        break
PY
)

REPO_OWNER="${REPO_OWNER:-gitea_admin}"
REPO_NAME="${REPO_NAME:-hermit-rfcs}"
DOCS_PATH="${DOCS_PATH:-docs-cms/rfcs}"
RFC_LABEL="${RFC_LABEL:-hermit:rfc-ready}"

# ── Install into Keychain as a single JSON blob ───────────────────────────────
# KeychainHelper.swift reads one item: service=HermitNative account=hermit.config
# Storing everything in one item means macOS only prompts for the password once.

JSON=$(python3 - <<PY
import json, sys
print(json.dumps({
    "pat":              "${PAT}",
    "baseURL":          "${GITEA_BASE_URL}",
    "serverBaseURL":    "${HERMIT_SERVER_URL}",
    "repoOwner":        "${REPO_OWNER}",
    "repoName":         "${REPO_NAME}",
    "docsPath":         "${DOCS_PATH}",
    "rfcLabel":         "${RFC_LABEL}",
    "serverMode":       '{"type":"embeddedLocal"}'
}))
PY
)

printf 'Installing Hermit config into macOS Keychain (single item)...\n'

# Delete any existing item, then add the new one.
security delete-generic-password \
    -a "hermit.config" \
    -s "HermitNative" 2>/dev/null || true

security add-generic-password \
    -a "hermit.config" \
    -s "HermitNative" \
    -w "${JSON}" \
    -T "" \
    -U

printf '  server-base-url → %s\n' "${HERMIT_SERVER_URL}"
printf '  base-url        → %s\n' "${GITEA_BASE_URL}"
printf '  repo            → %s/%s\n' "${REPO_OWNER}" "${REPO_NAME}"
printf '  docs-path       → %s\n' "${DOCS_PATH}"
printf '  rfc-label       → %s\n' "${RFC_LABEL}"
printf '  pat             → (set)\n'
printf 'Keychain install complete.\n'
