#!/usr/bin/env bash
# Pre-push gate: build, test, optional format lint, bundle, smoke-launch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

APP="$ROOT/dist/Sigil.app"
BIN="$APP/Contents/MacOS/Sigil"
MCP_BIN="$APP/Contents/MacOS/sigil-mcp"
FORMAT_STATUS=""
SMOKE_PID=""
SMOKE_ROOT=""
SMOKE_LOG=""

stop_smoke() {
  if [[ -n "${SMOKE_PID}" ]]; then
    kill "$SMOKE_PID" 2>/dev/null || true
    for _ in {1..20}; do
      if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$SMOKE_PID" 2>/dev/null; then
      kill -KILL "$SMOKE_PID" 2>/dev/null || true
    fi
    wait "$SMOKE_PID" 2>/dev/null || true
    SMOKE_PID=""
  fi
}

cleanup() {
  stop_smoke
  if [[ -n "${SMOKE_ROOT}" ]]; then
    rm -rf "$SMOKE_ROOT"
    SMOKE_ROOT=""
  fi
  SMOKE_LOG=""
}
trap cleanup EXIT

fail() {
  echo >&2
  echo "==== verify: FAIL — $1 ====" >&2
  exit 1
}

echo "==> swift test"
swift test || fail "swift test"

echo "==> bash -n"
bash -n "$SCRIPT_DIR"/*.sh || fail "bash syntax"

if command -v shellcheck >/dev/null 2>&1; then
  echo "==> shellcheck"
  shellcheck "$SCRIPT_DIR"/*.sh || fail "shellcheck"
else
  echo "note: shellcheck not installed; skipping shell lint"
fi

if swift format lint --help >/dev/null 2>&1; then
  echo "==> swift format lint --strict"
  swift format lint --configuration "$ROOT/.swift-format" --recursive --strict \
    "$ROOT/Sources" "$ROOT/Tests" || fail "swift format lint"
  FORMAT_STATUS="swift format lint --strict"
elif command -v swift-format >/dev/null 2>&1; then
  echo "==> swift-format lint --strict"
  swift-format lint --configuration "$ROOT/.swift-format" --recursive --strict \
    "$ROOT/Sources" "$ROOT/Tests" || fail "swift-format lint"
  FORMAT_STATUS="swift-format lint --strict"
elif command -v swiftformat >/dev/null 2>&1; then
  echo "==> swiftformat --lint"
  swiftformat --lint "$ROOT/Sources" "$ROOT/Tests" || fail "swiftformat lint"
  FORMAT_STATUS="swiftformat lint"
else
  echo "note: no Swift formatter is installed; skipping format lint"
  FORMAT_STATUS="format lint skipped (tool not installed)"
fi

echo "==> Scripts/build-app.sh"
# Verification needs a runnable local bundle, not a release artifact. A debug
# bundle avoids an expensive universal release rebuild after the tests.
SIGIL_CONFIG=debug "$SCRIPT_DIR/build-app.sh" || fail "Scripts/build-app.sh"

if [[ ! -x "$BIN" || ! -x "$MCP_BIN" ]]; then
  fail "bundled executable or MCP helper is missing"
fi
if [[ ! -f "$APP/Contents/Resources/LICENSE.txt" \
  || ! -f "$APP/Contents/Resources/ThirdPartyLicenses/SwiftTerm-LICENSE.txt" \
  || ! -f "$APP/Contents/Resources/ThirdPartyLicenses/swift-argument-parser-LICENSE.txt" ]]; then
  fail "bundled licenses are missing"
fi
plutil -lint "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist"
codesign --verify --deep --strict "$APP" || fail "bundle signature"

echo "==> launch smoke check"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sigil-smoke-home.XXXXXX")"
SMOKE_LOG="$SMOKE_ROOT/sigil.log"
mkdir -p "$SMOKE_ROOT/.grok" "$SMOKE_ROOT/tmp" "$SMOKE_ROOT/cache" "$SMOKE_ROOT/config"
# The smoke flag prevents session restore and bridge registration. The temporary
# homes are a second boundary against touching a developer's real state.
HOME="$SMOKE_ROOT" \
  CFFIXED_USER_HOME="$SMOKE_ROOT" \
  GROK_HOME="$SMOKE_ROOT/.grok" \
  TMPDIR="$SMOKE_ROOT/tmp" \
  XDG_CACHE_HOME="$SMOKE_ROOT/cache" \
  XDG_CONFIG_HOME="$SMOKE_ROOT/config" \
  SIGIL_SMOKE_TEST=1 \
  "$BIN" --smoke-test >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
sleep 3
if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
  echo "---- smoke output ----" >&2
  cat "$SMOKE_LOG" >&2 || true
  rm -f "$SMOKE_LOG"
  wait "$SMOKE_PID" 2>/dev/null || true
  SMOKE_PID=""
  fail "Sigil exited during the smoke check"
fi
stop_smoke
rm -f "$SMOKE_LOG"
rm -rf "$SMOKE_ROOT"
SMOKE_ROOT=""
SMOKE_LOG=""

echo
echo "==== verify: PASS ===="
echo "  swift test"
echo "  $FORMAT_STATUS"
echo "  Scripts/build-app.sh (debug bundle)"
echo "  launch smoke check (alive after 3s, then quit)"
