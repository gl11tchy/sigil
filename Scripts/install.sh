#!/usr/bin/env bash
# Copy dist/Sigil.app into /Applications, replacing the running copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="${SIGIL_APP:-$ROOT/dist/Sigil.app}"
DEST="${SIGIL_INSTALL_APP:-/Applications/Sigil.app}"

if [[ ! -d "$SRC" ]]; then
  echo "error: no app bundle at $SRC" >&2
  echo "build one first: SIGIL_ALLOW_THIN=1 Scripts/build-app.sh" >&2
  exit 1
fi
if [[ ! -x "$SRC/Contents/MacOS/Sigil" ]]; then
  echo "error: $SRC is not a Sigil app bundle" >&2
  exit 1
fi

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
