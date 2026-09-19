#!/usr/bin/env bash
# Copy dist/Sigil.app into /Applications, replacing the running copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${SIGIL_APP:-$ROOT/dist/Sigil.app}"
DEST="${SIGIL_INSTALL_APP:-/Applications/Sigil.app}"
LOCK="$(dirname "$DEST")/.sigil-install.lock"
HELD_LOCK=0

cleanup() {
  if [[ "$HELD_LOCK" -eq 1 ]]; then
    rmdir "$LOCK" 2>/dev/null || true
    HELD_LOCK=0
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

if [[ ! -d "$SRC" ]]; then
  echo "error: no app bundle at $SRC" >&2
  echo "build one first: SIGIL_ALLOW_THIN=1 Scripts/build-app.sh" >&2
  exit 1
fi
if [[ ! -x "$SRC/Contents/MacOS/Sigil" ]]; then
  echo "error: $SRC is not a Sigil app bundle" >&2
  exit 1
fi

# The same lock Scripts/install-latest.sh takes, so the two cannot overwrite
# each other's work on /Applications/Sigil.app.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "error: another install is already running" >&2
  echo "if that is not true, remove $LOCK and try again" >&2
  exit 1
fi
HELD_LOCK=1

if pgrep -xq Sigil; then
  echo "==> quitting Sigil"
  osascript -e 'tell application "Sigil" to quit' >/dev/null 2>&1 || true
  for _ in {1..50}; do
    if ! pgrep -xq Sigil; then
      break
    fi
    sleep 0.1
  done
  if pgrep -xq Sigil; then
    echo "error: Sigil is still running; quit it and run this again" >&2
    exit 1
  fi
fi

echo "==> installing $SRC -> $DEST"
rm -rf "$DEST"
ditto "$SRC" "$DEST"
echo "==> opening $DEST"
open "$DEST"
