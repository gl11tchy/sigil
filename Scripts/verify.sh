#!/usr/bin/env bash
# Pre-push gate: build, test, optional format lint, bundle, smoke-launch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

APP="$ROOT/dist/Sigil.app"
BIN="$APP/Contents/MacOS/Sigil"
FORMAT_STATUS=""
SMOKE_PID=""

cleanup() {
  if [[ -n "${SMOKE_PID}" ]]; then
    kill "$SMOKE_PID" 2>/dev/null || true
    wait "$SMOKE_PID" 2>/dev/null || true
    SMOKE_PID=""
  fi
}
trap cleanup EXIT

fail() {
  echo >&2
  echo "==== verify: FAIL — $1 ====" >&2
  exit 1
}

echo "==> swift build"
swift build || fail "swift build"

echo "==> swift test"
swift test || fail "swift test"

if command -v swiftformat >/dev/null 2>&1; then
  echo "==> swiftformat --lint"
  swiftformat --lint "$ROOT/Sources" "$ROOT/Tests" "$ROOT/Scripts" || fail "swiftformat lint"
  FORMAT_STATUS="swiftformat lint"
elif command -v swift-format >/dev/null 2>&1; then
  echo "==> swift-format lint"
  swift-format lint --recursive "$ROOT/Sources" "$ROOT/Tests" "$ROOT/Scripts" || fail "swift-format lint"
  FORMAT_STATUS="swift-format lint"
else
  echo "note: swiftformat / swift-format not installed; skipping format lint"
  FORMAT_STATUS="format lint skipped (tool not installed)"
fi

echo "==> Scripts/build-app.sh"
"$SCRIPT_DIR/build-app.sh" || fail "Scripts/build-app.sh"

if [[ ! -x "$BIN" ]]; then
  fail "bundled executable missing at $BIN"
fi

echo "==> launch smoke check"
SMOKE_LOG="$(mktemp "${TMPDIR:-/tmp}/sigil-smoke.XXXXXX")"
"$BIN" >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
sleep 3
if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
  echo "---- smoke output ----" >&2
  cat "$SMOKE_LOG" >&2 || true
  rm -f "$SMOKE_LOG"
  SMOKE_PID=""
  fail "Sigil exited during the smoke check"
fi
kill "$SMOKE_PID" 2>/dev/null || true
wait "$SMOKE_PID" 2>/dev/null || true
SMOKE_PID=""
rm -f "$SMOKE_LOG"

echo
echo "==== verify: PASS ===="
echo "  swift build"
echo "  swift test"
echo "  $FORMAT_STATUS"
echo "  Scripts/build-app.sh"
echo "  launch smoke check (alive after 3s, then quit)"
