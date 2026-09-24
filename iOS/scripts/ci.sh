#!/bin/bash
# Every iPhone check: typecheck, tests against the real relay, simulator build.
#
# Usage: scripts/ci.sh
set -euo pipefail

cd "$(dirname "$0")/.."

stage() {
  local name="$1"
  shift
  echo "==> $name"
  if "$@"; then
    echo "PASS  $name"
  else
    local rc=$?
    echo "FAIL  $name"
    exit "$rc"
  fi
}

stage "typecheck" scripts/typecheck.sh
stage "test (with the real relay)" scripts/relay-e2e.sh
stage "build" scripts/build.sh
