#!/usr/bin/env bash
# Launch the supplied bundle in an isolated home; never install or open it.
set -euo pipefail

if [[ "$#" != 1 || "$1" != *.app || ! -d "$1" ]]; then
  echo "usage: Scripts/smoke-launch.sh <path to .app>" >&2
  exit 1
fi
APP="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
BIN="$APP/Contents/MacOS/Sigil"
if [[ ! -f "$BIN" || ! -x "$BIN" ]]; then
  echo "error: bundle executable is missing: $BIN" >&2
  exit 1
fi

SMOKE_PID=""
SMOKE_ROOT=""
stop_smoke() {
  if [[ -n "$SMOKE_PID" ]]; then
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
  if [[ -n "$SMOKE_ROOT" ]]; then
    rm -rf "$SMOKE_ROOT"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

echo "==> launch smoke check: $APP"
BEFORE_SUM="$(shasum -a 256 "$BIN" | awk '{print $1}')"
echo "  executable SHA256: $BEFORE_SUM"
SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sigil-smoke-home.XXXXXX")"
SMOKE_LOG="$SMOKE_ROOT/sigil.log"
mkdir -p "$SMOKE_ROOT/.grok" "$SMOKE_ROOT/tmp" "$SMOKE_ROOT/cache" "$SMOKE_ROOT/config"
# The smoke flag prevents restore, provider probes and bridge registration. The
# temporary homes and working directory also keep startup away from real state.
(
  cd "$SMOKE_ROOT"
  exec env HOME="$SMOKE_ROOT" \
    CFFIXED_USER_HOME="$SMOKE_ROOT" \
    GROK_HOME="$SMOKE_ROOT/.grok" \
    TMPDIR="$SMOKE_ROOT/tmp" \
    XDG_CACHE_HOME="$SMOKE_ROOT/cache" \
    XDG_CONFIG_HOME="$SMOKE_ROOT/config" \
    SIGIL_SMOKE_TEST=1 \
    "$BIN" --smoke-test
) >"$SMOKE_LOG" 2>&1 &
SMOKE_PID=$!
sleep 3
if ! kill -0 "$SMOKE_PID" 2>/dev/null; then
  echo "---- smoke output ----" >&2
  cat "$SMOKE_LOG" >&2 || true
  wait "$SMOKE_PID" 2>/dev/null || true
  SMOKE_PID=""
  echo "error: Sigil exited during the smoke check: $APP" >&2
  exit 1
fi
stop_smoke
AFTER_SUM="$(shasum -a 256 "$BIN" | awk '{print $1}')"
if [[ "$AFTER_SUM" != "$BEFORE_SUM" ]]; then
  echo "error: bundle executable changed during the smoke check: $APP" >&2
  exit 1
fi
echo "  PASS: alive after 3s, then stopped; executable SHA256 unchanged"
