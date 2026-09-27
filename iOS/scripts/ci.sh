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

toolchain() {
  local version
  version="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
  if [[ ! "$version" =~ ^[0-9]+([.][0-9]+)*$ ]] || [ "${version%%.*}" -lt 26 ]; then
    echo "Native verification requires Xcode 26+ with an iOS 26+ simulator runtime; selected Xcode is ${version:-unknown}." >&2
    return 1
  fi
}

stage "Xcode 26+ toolchain" toolchain
stage "typecheck" scripts/typecheck.sh
stage "test (with the real relay)" scripts/relay-e2e.sh
stage "native app, extensions, and simulator tests" scripts/native-test.sh

stage "native TextKit output, Find, and cover tests" scripts/native-output-test.sh
