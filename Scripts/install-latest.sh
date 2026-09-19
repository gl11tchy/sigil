#!/usr/bin/env bash
# Build HEAD and swap it into /Applications/Sigil.app.
# Does not quit a running Sigil. The new binary loads on the next launch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${SIGIL_INSTALL_APP:-/Applications/Sigil.app}"
export SIGIL_ALLOW_THIN="${SIGIL_ALLOW_THIN:-1}"
STAGING_ROOT=""

cleanup() {
  if [[ -n "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
    STAGING_ROOT=""
  fi
}
trap cleanup EXIT

sigil_running() {
  ps -axo command | awk -v exe="$DEST/Contents/MacOS/Sigil" '$0 == exe { found = 1 } END { exit !found }'
}

"$SCRIPT_DIR/build-app.sh"
# build-app.sh resolves a relative SIGIL_APP against the repository root, so
# this has to resolve it the same way or the two disagree outside that root.
if [[ -n "${SIGIL_APP:-}" ]]; then
  case "$SIGIL_APP" in
    /*) SRC="$SIGIL_APP" ;;
    *) SRC="$ROOT/$SIGIL_APP" ;;
  esac
else
  SRC="$ROOT/dist/Sigil.app"
fi
if [[ ! -x "$SRC/Contents/MacOS/Sigil" ]]; then
  echo "error: $SRC is not a Sigil app bundle" >&2
  exit 1
fi

old="$(defaults read "$DEST/Contents/Info.plist" CFBundleVersion 2>/dev/null || echo none)"
new="$(defaults read "$SRC/Contents/Info.plist" CFBundleVersion)"
echo "==> installing $SRC -> $DEST (was build $old)"

# Stage a complete copy and check it before touching the destination. Copying
# onto the old bundle would merge the two, leaving files a later build dropped
# behind to fail the signature check on an app that is already half replaced.
was_running=0
if sigil_running; then
  was_running=1
fi
dest_parent="$(dirname "$DEST")"
STAGING_ROOT="$(mktemp -d "$dest_parent/.sigil-install.XXXXXX")"
STAGED="$STAGING_ROOT/Sigil.app"
ditto "$SRC" "$STAGED"
codesign --verify --deep --strict "$STAGED"

if [[ -e "$DEST" ]]; then
  PREVIOUS="$STAGING_ROOT/previous-Sigil.app"
  mv "$DEST" "$PREVIOUS"
  if ! mv "$STAGED" "$DEST"; then
    mv "$PREVIOUS" "$DEST"
    echo "error: could not move $STAGED into place; kept build $old" >&2
    exit 1
  fi
else
  mv "$STAGED" "$DEST"
fi
echo "==> installed build $new"

if [[ "$was_running" -eq 1 ]]; then
  echo "==> Sigil is running the previous binary. Restart it to load build $new."
else
  echo "==> opening $DEST"
  open "$DEST"
fi
