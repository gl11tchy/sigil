#!/usr/bin/env bash
# Build HEAD and copy it onto /Applications/Sigil.app.
# Does not quit a running Sigil. The new binary loads on the next launch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${SIGIL_INSTALL_APP:-/Applications/Sigil.app}"
export SIGIL_ALLOW_THIN="${SIGIL_ALLOW_THIN:-1}"

sigil_running() {
  ps -axo command | awk -v exe="$DEST/Contents/MacOS/Sigil" '$0 == exe { found = 1 } END { exit !found }'
}

"$SCRIPT_DIR/build-app.sh"
SRC="${SIGIL_APP:-$ROOT/dist/Sigil.app}"
if [[ ! -x "$SRC/Contents/MacOS/Sigil" ]]; then
  echo "error: $SRC is not a Sigil app bundle" >&2
  exit 1
fi

old="$(defaults read "$DEST/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo none)"
echo "==> installing $SRC -> $DEST (was build $old)"
ditto "$SRC" "$DEST"
codesign --verify --deep --strict "$DEST"
new="$(defaults read "$DEST/Contents/Info.plist" CFBundleVersion)"
echo "==> installed build $new"

if sigil_running; then
  echo "==> Sigil is running the previous binary. Restart it to load build $new."
else
  echo "==> opening $DEST"
  open "$DEST"
fi
