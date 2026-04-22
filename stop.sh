#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

run_make() {
  echo "==> make $*"
  make "$@"
}

if [ "${1:-}" = "--reset" ]; then
  run_make gitea-down || true
  sleep "${SLEEP_SHORT:-2}"
  run_make gitea-reset
  exit 0
fi

run_make gitea-down
