#!/usr/bin/env bash
# Pre-push gate: build, test, optional format lint, bundle, smoke-launch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT" || exit 1

RELEASE_APP="$ROOT/dist/Sigil.app"
APP=""
BIN=""
MCP_BIN=""
FORMAT_STATUS=""
BUILD_ROOT=""
RELEASE_SUM=""

cleanup() {
  if [[ -n "$BUILD_ROOT" ]]; then
    rm -rf "$BUILD_ROOT"
  fi
}
trap cleanup EXIT

fail() {
  echo >&2
  echo "==== verify: FAIL — $1 ====" >&2
  exit 1
}

echo "==> Sidereal dependencies and tests"
npm --prefix "$ROOT/Sidereal" ci --ignore-scripts || fail "Sidereal dependencies"
npm --prefix "$ROOT/Sidereal" test || fail "Sidereal tests"
npm --prefix "$ROOT/Sidereal" audit --omit=dev || fail "Sidereal dependency audit"

echo "==> Site dependencies and tests"
npm --prefix "$ROOT/Site" ci --ignore-scripts || fail "Site dependencies"
npm --prefix "$ROOT/Site" test || fail "Site tests"
npm --prefix "$ROOT/Site" audit --omit=dev || fail "Site dependency audit"

echo "==> Sidereal mobile browser checks"
npm --prefix "$ROOT/Sidereal" exec -- playwright install chromium webkit || fail "Sidereal browsers"
npm --prefix "$ROOT/Sidereal" run test:browser || fail "Sidereal browser tests"

echo "==> swift test --no-parallel"
# Several integration tests use blocking processes and sockets. Serial execution
# avoids starving the older Swift concurrency runtime on GitHub's macOS runner.
SWIFT_TEST_LOG="$(mktemp "${TMPDIR:-/tmp}/sigil-swift-test.XXXXXX")"
swift test --no-parallel 2>&1 | tee "$SWIFT_TEST_LOG" || fail "swift test"
python3 "$SCRIPT_DIR/check-swift-test-log.py" "$SWIFT_TEST_LOG" || fail "swift test completion"

echo "==> CI-only SwiftUI app-hosted sidebar fixture"
"$SCRIPT_DIR/sidebar-host-test.sh" || fail "sidebar app-hosted test"

echo "==> bash -n"
# bash -n reads only its first file and treats the rest as arguments.
for script in "$SCRIPT_DIR"/*.sh; do
  bash -n "$script" || fail "bash syntax: $script"
done

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
# Write it under a temporary directory so dist/Sigil.app is not replaced.
RELEASE_BIN="$RELEASE_APP/Contents/MacOS/Sigil"
if [[ -x "$RELEASE_BIN" ]]; then
  RELEASE_SUM="$(shasum -a 256 "$RELEASE_BIN" | awk '{print $1}')"
fi

BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sigil-verify-bundle.XXXXXX")"
APP="$BUILD_ROOT/Sigil.app"
BIN="$APP/Contents/MacOS/Sigil"
MCP_BIN="$APP/Contents/MacOS/sigil-mcp"

SIGIL_CONFIG=debug \
  SIGIL_APP="$APP" \
  SIGIL_CODESIGN_IDENTITY=- \
  "$SCRIPT_DIR/build-app.sh" || fail "Scripts/build-app.sh"

if [[ -n "$RELEASE_SUM" ]]; then
  if [[ ! -x "$RELEASE_BIN" ]]; then
    fail "debug verify removed dist/Sigil.app"
  fi
  after_sum="$(shasum -a 256 "$RELEASE_BIN" | awk '{print $1}')"
  if [[ "$after_sum" != "$RELEASE_SUM" ]]; then
    fail "debug verify overwrote dist/Sigil.app"
  fi
elif [[ -e "$RELEASE_APP" ]]; then
  fail "debug verify created dist/Sigil.app"
fi

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

"$SCRIPT_DIR/smoke-launch.sh" "$APP" || fail "launch smoke check"
rm -rf "$BUILD_ROOT"
BUILD_ROOT=""

echo
echo "==== verify: PASS ===="
echo "  swift test --no-parallel"
echo "  $FORMAT_STATUS"
echo "  Scripts/build-app.sh (debug bundle)"
echo "  launch smoke check (alive after 3s, then quit)"
