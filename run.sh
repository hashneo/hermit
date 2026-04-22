#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "${ROOT_DIR}"

SLEEP_SHORT="${SLEEP_SHORT:-2}"
SLEEP_LONG="${SLEEP_LONG:-6}"
MAX_GITEA_UP_ATTEMPTS="${MAX_GITEA_UP_ATTEMPTS:-3}"
MAKE_TARGET="run"

case "${1:-}" in
  "")
    ;;
  --debug)
    MAKE_TARGET="debug"
    ;;
  -h|--help)
    echo "Usage: ./run.sh [--debug]"
    echo "  default  Start Gitea and run hermit once (make run)"
    echo "  --debug  Start Gitea and run Air/Vite watch mode (make debug)"
    exit 0
    ;;
  *)
    echo "Unknown option: ${1}"
    echo "Usage: ./run.sh [--debug]"
    exit 1
    ;;
esac

run_make() {
  echo "==> make $*"
  make "$@"
}

run_gitea_up_with_retries() {
  local attempt=1

  while [ "${attempt}" -le "${MAX_GITEA_UP_ATTEMPTS}" ]; do
    if run_make gitea-up; then
      return 0
    fi

    if [ "${attempt}" -eq "${MAX_GITEA_UP_ATTEMPTS}" ]; then
      echo "gitea-up failed after ${MAX_GITEA_UP_ATTEMPTS} attempts"
      return 1
    fi

    echo "gitea-up failed (attempt ${attempt}/${MAX_GITEA_UP_ATTEMPTS}); retrying in ${SLEEP_LONG}s..."
    sleep "${SLEEP_LONG}"
    attempt=$((attempt + 1))
  done
}

run_make gitea-down || true
sleep "${SLEEP_SHORT}"

run_gitea_up_with_retries
sleep "${SLEEP_LONG}"

run_make "${MAKE_TARGET}"
