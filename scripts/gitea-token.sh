#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-ensure}"

GITEA_CONTAINER="${GITEA_CONTAINER:-hermit-gitea}"
GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-gitea_admin}"
GITEA_ADMIN_PASS="${GITEA_ADMIN_PASS:-gitea_admin}"
GITEA_TOKEN_NAME="${GITEA_TOKEN_NAME:-hermit-local-token}"
GITEA_TOKEN_CACHE_FILE="${GITEA_TOKEN_CACHE_FILE:-.tmp/gitea-token.env}"
GITEA_BASE_URL="${GITEA_BASE_URL:-http://localhost:3000}"

ensure_container_running() {
  if ! docker ps --format '{{.Names}}' | grep -q "^${GITEA_CONTAINER}$"; then
    printf 'Gitea container %s is not running\n' "${GITEA_CONTAINER}" >&2
    exit 1
  fi
}

read_cached_token() {
  if [ -f "${GITEA_TOKEN_CACHE_FILE}" ]; then
    # shellcheck disable=SC1090
    . "${GITEA_TOKEN_CACHE_FILE}"
    if [ "${GITEA_TOKEN:-}" != "" ]; then
      printf '%s' "${GITEA_TOKEN}"
      return 0
    fi
  fi
  return 1
}

token_is_valid() {
  local token="${1}"
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: token ${token}" "${GITEA_BASE_URL}/api/v1/user")
  [ "${status}" = "200" ]
}

mint_token() {
  local token_name="${1}"
  docker exec -u git "${GITEA_CONTAINER}" gitea admin user generate-access-token \
    --username "${GITEA_ADMIN_USER}" \
    --token-name "${token_name}" \
    --scopes all \
    --raw 2>/dev/null
}

cache_token() {
  local token="${1}"
  mkdir -p "$(dirname "${GITEA_TOKEN_CACHE_FILE}")"
  printf 'GITEA_TOKEN=%s\n' "${token}" >"${GITEA_TOKEN_CACHE_FILE}"
}

resolve_token() {
  local token
  local token_name
  local attempt

  if token=$(read_cached_token); then
    if token_is_valid "${token}"; then
      printf '%s\n' "${token}"
      return 0
    fi
    rm -f "${GITEA_TOKEN_CACHE_FILE}"
  fi

  for attempt in 0 1 2; do
    if [ "${attempt}" -eq 0 ]; then
      token_name="${GITEA_TOKEN_NAME}"
    else
      token_name="${GITEA_TOKEN_NAME}-$(date +%s)-${attempt}"
    fi
    if token=$(mint_token "${token_name}") && [ -n "${token}" ] && token_is_valid "${token}"; then
      cache_token "${token}"
      printf '%s\n' "${token}"
      return 0
    fi
  done

  printf 'failed to mint valid Gitea access token\n' >&2
  exit 1
}

main() {
  ensure_container_running
  local token
  token=$(resolve_token)

  case "${MODE}" in
    ensure)
      printf 'Gitea token is ready at %s\n' "${GITEA_TOKEN_CACHE_FILE}"
      ;;
    env)
      printf 'export GITEA_TOKEN=%q\n' "${token}"
      ;;
    *)
      printf 'Unknown mode: %s (supported: ensure, env)\n' "${MODE}" >&2
      exit 1
      ;;
  esac
}

main
