#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--debug" ]; then
  exec "${ROOT_DIR}/run.sh" --debug
fi

echo "Usage: ./ren.sh --debug"
exit 1
