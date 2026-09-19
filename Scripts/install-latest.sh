#!/usr/bin/env bash
# Build HEAD and swap it into /Applications/Sigil.app.
# Does not quit a running Sigil. The new binary loads on the next launch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${SIGIL_INSTALL_APP:-/Applications/Sigil.app}"
export SIGIL_ALLOW_THIN="${SIGIL_ALLOW_THIN:-1}"
STAGING_ROOT=""
PREVIOUS=""

# A signal between the two moves below would otherwise leave the staging
# directory holding the only copy of the app, so put it back before deleting.
cleanup() {
  if [[ -n "$PREVIOUS" && -d "$PREVIOUS" && ! -e "$DEST" ]]; then
    mv "$PREVIOUS" "$DEST" || true
  fi
  if [[ -n "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
    STAGING_ROOT=""
  fi
  PREVIOUS=""
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

sigil_running() {
  ps -axo command | awk -v exe="$DEST/Contents/MacOS/Sigil" '$0 == exe { found = 1 } END { exit !found }'
}

resolve_path() {
  local path="$1" dir base
  dir="$(dirname "$path")"
  base="$(basename "$path")"
  if [[ -d "$dir" ]]; then
    dir="$(cd "$dir" && pwd -P)"
  fi
  printf '%s/%s\n' "$dir" "$base"
}

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

# build-app.sh deletes its own output before it builds. If that output is the
# installed app, a failed build would take the installation with it.
if [[ "$(resolve_path "$SRC")" == "$(resolve_path "$DEST")" ]]; then
  echo "error: the build output and the install destination are the same bundle" >&2
  echo "       $DEST" >&2
  echo "point SIGIL_APP somewhere else; building there would delete the installed app" >&2
  exit 1
fi

"$SCRIPT_DIR/build-app.sh"
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
    PREVIOUS=""
    echo "error: could not move $STAGED into place; kept build $old" >&2
    exit 1
  fi
else
  mv "$STAGED" "$DEST"
fi
echo "==> installed build $new"

# Read the process state now, not before the copy: Sigil may have been opened
# or quit while the bundle was being staged.
if sigil_running; then
  echo "==> Sigil is running the previous binary. Restart it to load build $new."
else
  echo "==> opening $DEST"
  open "$DEST"
fi
