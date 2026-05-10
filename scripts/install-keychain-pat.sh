#!/usr/bin/env bash
# install-keychain-pat.sh
#
# Bootstraps HermitNative for a local dev session:
#
#   UserDefaults → all config including PAT (debug builds store token in UserDefaults)
#   Keychain     → PAT also written for release builds (skipped with --no-keychain)
#
# In DEBUG builds the Swift app reads the token directly from the Connection JSON
# stored in UserDefaults (hermit.accounts), so no Keychain prompt is needed.
# In Release builds the token field in the JSON is ignored and the Keychain is used.
#
# Usage:
#   scripts/install-keychain-pat.sh [--no-keychain] [PAT] [HERMIT_YAML_PATH]
#
#   --no-keychain  Skip writing the PAT to Keychain (debug builds don't need it).
#                  UserDefaults config (including token in JSON) is still written.
#
# When called with no arguments it reads the PAT from .tmp/gitea-token.env
# and the config from config/hermit.yaml (both relative to the repo root).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Parse flags ───────────────────────────────────────────────────────────────

SKIP_KEYCHAIN=false
POSITIONAL=()
for arg in "$@"; do
    case "${arg}" in
        --no-keychain) SKIP_KEYCHAIN=true ;;
        *) POSITIONAL+=("${arg}") ;;
    esac
done
set -- "${POSITIONAL[@]+"${POSITIONAL[@]}"}"

# ── Resolve PAT ───────────────────────────────────────────────────────────────

PAT="${1:-}"

if [ -z "${PAT}" ] && [ "${SKIP_KEYCHAIN}" = false ]; then
    TOKEN_ENV="${REPO_ROOT}/.tmp/gitea-token.env"
    if [ -f "${TOKEN_ENV}" ]; then
        # shellcheck disable=SC1090
        . "${TOKEN_ENV}"
        PAT="${GITEA_TOKEN:-}"
    fi
fi

if [ -z "${PAT}" ] && [ "${SKIP_KEYCHAIN}" = false ]; then
    printf 'ERROR: No PAT provided and .tmp/gitea-token.env not found or empty.\n' >&2
    printf 'Run "make gitea-up" first, pass the token as the first argument, or use --no-keychain.\n' >&2
    exit 1
fi

# ── Resolve config values from hermit.yaml ────────────────────────────────────

HERMIT_YAML="${2:-${REPO_ROOT}/config/hermit.yaml}"

if [ ! -f "${HERMIT_YAML}" ]; then
    printf 'ERROR: config/hermit.yaml not found at %s\n' "${HERMIT_YAML}" >&2
    exit 1
fi

# Extract the gitea-local registry base_url
GITEA_BASE_URL=$(python3 - "${HERMIT_YAML}" <<'PY'
import sys
with open(sys.argv[1]) as f:
    content = f.read()

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
        print(base)
        break
PY
)
GITEA_BASE_URL="${GITEA_BASE_URL:-http://localhost:3000/api/v1}"
# Strip /api/v1 suffix — the account endpoint is the bare host.
# EmbeddedServerManager.resolvedAPIBase() appends /api/v1 at server start time
# for any non-GitHub host, so storing the bare URL keeps the two in sync.
GITEA_ENDPOINT="${GITEA_BASE_URL%/api/v1}"
GITEA_ENDPOINT="${GITEA_ENDPOINT%/}"

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

current = {}
registries = []
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('- name:'):
        if current: registries.append(dict(current))
        current = {'name': stripped.split(':', 1)[1].strip()}
    elif stripped.startswith('base_url:'):
        current['base_url'] = stripped.split(':', 1)[1].strip()
    elif stripped.startswith('kind:'):
        current['kind'] = stripped.split(':', 1)[1].strip()
if current:
    registries.append(current)

gitea_registry = None
for r in registries:
    if 'localhost' in r.get('base_url', '') or 'gitea' in r.get('base_url', ''):
        gitea_registry = r['name']
        break

if not gitea_registry:
    sys.exit(1)

current_repo = {}
repos = []
for line in content.splitlines():
    stripped = line.strip()
    if stripped.startswith('- owner:'):
        if current_repo: repos.append(dict(current_repo))
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
        print(r.get('owner',''), r.get('name',''), r.get('docs_path','docs-cms/rfcs'), 'hermit:rfc-ready')
        break
PY
)

REPO_OWNER="${REPO_OWNER:-gitea_admin}"
REPO_NAME="${REPO_NAME:-hermit-rfcs}"
DOCS_PATH="${DOCS_PATH:-docs-cms/rfcs}"
RFC_LABEL="${RFC_LABEL:-hermit:rfc-ready}"

# ── Bundle ID (read from Local.xcconfig, falls back to example) ──────────────

LOCAL_XCCONFIG="${REPO_ROOT}/hermit-native/Local.xcconfig"
EXAMPLE_XCCONFIG="${REPO_ROOT}/hermit-native/Local.xcconfig.example"

BUNDLE_ID=$(grep -E '^HERMIT_BUNDLE_ID\s*=' "${LOCAL_XCCONFIG}" 2>/dev/null \
    | head -1 | sed 's/.*=[ \t]*//' | tr -d '[:space:]') || true

if [ -z "${BUNDLE_ID}" ] || echo "${BUNDLE_ID}" | grep -q "yourname"; then
    printf 'WARNING: HERMIT_BUNDLE_ID not set — skipping UserDefaults/Keychain bootstrap.\n' >&2
    printf '\n' >&2
    printf 'If you are running this via "make dev" this should have been set up automatically.\n' >&2
    printf 'If it was not, your Mac may not have a valid Apple Development certificate.\n' >&2
    printf '\n' >&2
    printf 'To fix:\n' >&2
    printf '  1. Open Xcode -> Settings (Cmd+,) -> Accounts tab\n' >&2
    printf '  2. Sign in with your Apple ID if not already signed in\n' >&2
    printf '  3. Select your account -> click "Manage Certificates..."\n' >&2
    printf '  4. Click "+" and create an "Apple Development" certificate if none exist\n' >&2
    printf '  5. Re-run: make dev\n' >&2
    printf '\n' >&2
    exit 0
fi

# ── 1. Write PAT to Keychain (service=HermitNative account=hermit.account.<UUID>) ─

if [ "${SKIP_KEYCHAIN}" = true ]; then
    printf 'Skipping Keychain (--no-keychain).\n'
else
    printf 'Installing PAT into Keychain...\n'
    security delete-generic-password \
        -a "hermit.account.00000000-0000-0000-0000-000000000001" \
        -s "HermitNative" 2>/dev/null || true

    security add-generic-password \
        -a "hermit.account.00000000-0000-0000-0000-000000000001" \
        -s "HermitNative" \
        -w "${PAT}" \
        -T "" \
        -U

    printf '  PAT → (set)\n'
fi

# ── 2. Write non-secret config to UserDefaults ───────────────────────────────
# Write to both:
#   a) The global domain (picked up by non-sandboxed runs / `defaults read`)
#   b) The sandboxed container plist directly (what a sandboxed app actually reads)
#
# macOS does NOT reliably sync `defaults write <bundleID>` into the sandbox
# container before app launch, so we write the plist file directly to be safe.
#
# Accounts and repositories are ONLY seeded on first run (when the key is absent).
# On subsequent runs we only refresh the PAT on the fixed dev account UUID so that
# Gitea token rotation is picked up without overwriting any accounts/repos the user
# has added at runtime.

SANDBOX_PLIST="${HOME}/Library/Containers/${BUNDLE_ID}/Data/Library/Preferences/${BUNDLE_ID}.plist"

ACCOUNT_UUID="00000000-0000-0000-0000-000000000001"
REPO_UUID="00000000-0000-0000-0000-000000000002"

# Returns 0 (true) if hermit.accounts is already set in the given domain.
accounts_exist() {
    local domain="$1"
    defaults read "${domain}" hermit.accounts &>/dev/null
}

# Patch the PAT on the fixed dev account UUID inside an existing hermit.accounts JSON.
# Handles both string-stored (from this script) and data-stored (from Swift app) formats.
# Leaves any user-added accounts untouched.
patch_dev_pat() {
    local domain="$1"
    # Export the full plist so we can read the raw bytes regardless of storage format.
    local tmp_plist
    tmp_plist=$(mktemp /tmp/hermit-patch-XXXXXX.plist)
    if [[ "${domain}" == *.plist ]]; then
        cp "${domain}" "${tmp_plist}"
    else
        defaults export "${domain}" "${tmp_plist}" 2>/dev/null || { rm -f "${tmp_plist}"; return 1; }
    fi

    local patched_plist
    patched_plist=$(mktemp /tmp/hermit-patched-XXXXXX.plist)

    python3 - "${tmp_plist}" "${patched_plist}" "${ACCOUNT_UUID}" "${PAT}" <<'PY'
import sys, json, plistlib

src, dst, target_id, pat = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(src, 'rb') as f:
    d = plistlib.load(f)

raw = d.get('hermit.accounts')
if raw is None:
    sys.exit(1)

# raw may be bytes (Data) or str depending on how it was written
if isinstance(raw, bytes):
    accounts = json.loads(raw.decode())
elif isinstance(raw, str):
    accounts = json.loads(raw)
else:
    sys.exit(1)

changed = False
for a in accounts:
    if a.get('id') == target_id:
        a['token'] = pat
        changed = True

if not changed:
    sys.exit(1)

# Write back in the same format as the original
if isinstance(d['hermit.accounts'], bytes):
    d['hermit.accounts'] = json.dumps(accounts).encode()
else:
    d['hermit.accounts'] = json.dumps(accounts)

with open(dst, 'wb') as f:
    plistlib.dump(d, f)
PY
    local py_status=$?
    rm -f "${tmp_plist}"
    if [ $py_status -ne 0 ]; then
        rm -f "${patched_plist}"
        return 1
    fi

    if [[ "${domain}" == *.plist ]]; then
        cp "${patched_plist}" "${domain}"
    else
        defaults import "${domain}" "${patched_plist}"
    fi
    rm -f "${patched_plist}"
}

write_invariants() {
    local domain="$1"
    defaults write "${domain}" hermit.baseURL       "${GITEA_BASE_URL}"
    defaults write "${domain}" hermit.serverBaseURL "${HERMIT_SERVER_URL}"
    defaults write "${domain}" hermit.repoOwner     "${REPO_OWNER}"
    defaults write "${domain}" hermit.repoName      "${REPO_NAME}"
    defaults write "${domain}" hermit.docsPath      "${DOCS_PATH}"
    defaults write "${domain}" hermit.rfcLabel      "${RFC_LABEL}"
    defaults write "${domain}" hermit.serverMode    -string '{"type":"embeddedLocal"}'
}

seed_accounts() {
    local domain="$1"
    local ACCOUNTS_JSON="[{\"id\":\"${ACCOUNT_UUID}\",\"name\":\"Default (Gitea)\",\"endpoint\":\"${GITEA_ENDPOINT}\",\"token\":\"${PAT}\"}]"
    defaults write "${domain}" hermit.accounts          -string "${ACCOUNTS_JSON}"
    defaults write "${domain}" hermit.accounts.activeID -string "${ACCOUNT_UUID}"

    local REPOS_JSON="[{\"id\":\"${REPO_UUID}\",\"accountID\":\"${ACCOUNT_UUID}\",\"owner\":\"${REPO_OWNER}\",\"name\":\"${REPO_NAME}\",\"docsPath\":\"${DOCS_PATH}\",\"rfcLabel\":\"${RFC_LABEL}\"}]"
    defaults write "${domain}" hermit.repositories          -string "${REPOS_JSON}"
    defaults write "${domain}" hermit.repositories.activeID -string "${REPO_UUID}"
}

apply_to_domain() {
    local domain="$1"
    write_invariants "${domain}"
    if accounts_exist "${domain}"; then
        # Accounts already seeded — just refresh the PAT on the dev account.
        if patch_dev_pat "${domain}"; then
            printf '  accounts already present — refreshed dev PAT only\n'
        else
            printf '  accounts already present — dev account UUID not found, PAT not refreshed\n'
        fi
    else
        printf '  seeding accounts and repositories for the first time\n'
        seed_accounts "${domain}"
    fi
}

printf 'Writing config to UserDefaults (global: %s)...\n' "${BUNDLE_ID}"
apply_to_domain "${BUNDLE_ID}"

if [ -f "${SANDBOX_PLIST}" ]; then
    printf 'Writing config to sandboxed plist: %s\n' "${SANDBOX_PLIST}"
    apply_to_domain "${SANDBOX_PLIST}"
else
    printf 'Sandbox container not found yet (%s) — global write only.\n' "${SANDBOX_PLIST}"
    printf 'The app will pick up values on first launch.\n'
fi

printf '  server-base-url → %s\n' "${HERMIT_SERVER_URL}"
printf '  gitea-endpoint  → %s\n' "${GITEA_ENDPOINT}"
printf '  gitea-api-base  → %s\n' "${GITEA_BASE_URL}"
printf '  repo            → %s/%s\n' "${REPO_OWNER}" "${REPO_NAME}"
printf '  docs-path       → %s\n' "${DOCS_PATH}"
printf '  rfc-label       → %s\n' "${RFC_LABEL}"
printf 'Bootstrap complete.\n'
