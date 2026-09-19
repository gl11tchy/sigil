#!/usr/bin/env bash
# Build HEAD and swap it into /Applications/Sigil.app.
# Does not quit a running Sigil. The new binary loads on the next launch.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEST="${SIGIL_INSTALL_APP:-/Applications/Sigil.app}"
DEST_PARENT="$(dirname "$DEST")"
LOCK="$DEST_PARENT/.sigil-install.lock"
export SIGIL_ALLOW_THIN="${SIGIL_ALLOW_THIN:-1}"
STAGING_ROOT=""
PREVIOUS=""
HELD_LOCK=0

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
  if [[ "$HELD_LOCK" -eq 1 ]]; then
    rmdir "$LOCK" 2>/dev/null || true
    HELD_LOCK=0
  fi
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

# Device and inode, so two spellings of one bundle compare equal even on a
# case-insensitive filesystem. Empty when the path does not exist yet. BSD stat
# takes the format after -f, GNU stat after -c, so try both and keep whichever
# answers in the right shape.
path_id() {
  local id
  id="$(stat -L -f '%d:%i' "$1" 2>/dev/null || true)"
  if [[ ! "$id" =~ ^[0-9]+:[0-9]+$ ]]; then
    id="$(stat -L -c '%d:%i' "$1" 2>/dev/null || true)"
  fi
  if [[ "$id" =~ ^[0-9]+:[0-9]+$ ]]; then
    printf '%s\n' "$id"
  fi
}

same_bundle() {
  local a="$1" b="$2" a_id b_id
  a_id="$(path_id "$a")"
  b_id="$(path_id "$b")"
  if [[ -n "$a_id" && "$a_id" == "$b_id" ]]; then
    return 0
  fi
  [[ "$(resolve_path "$a")" == "$(resolve_path "$b")" ]]
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
if same_bundle "$SRC" "$DEST"; then
  echo "error: the build output and the install destination are the same bundle" >&2
  echo "       $DEST" >&2
  echo "point SIGIL_APP somewhere else; building there would delete the installed app" >&2
  exit 1
fi

# One installer at a time. Two overlapping runs would otherwise interleave
# their swaps, and the loser would move its bundle inside the winner's.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "error: another install is already running" >&2
  echo "if that is not true, remove $LOCK and try again" >&2
  exit 1
fi
HELD_LOCK=1

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
STAGING_ROOT="$(mktemp -d "$DEST_PARENT/.sigil-install.XXXXXX")"
STAGED="$STAGING_ROOT/Sigil.app"
ditto "$SRC" "$STAGED"
codesign --verify --deep --strict "$STAGED"

if [[ -e "$DEST" ]]; then
  PREVIOUS="$STAGING_ROOT/previous-Sigil.app"
  mv "$DEST" "$PREVIOUS"
fi
# mv would move the bundle inside an existing directory of that name instead of
# replacing it, so never run it with the destination occupied.
if [[ -e "$DEST" ]]; then
  echo "error: $DEST reappeared during the install; leaving it alone" >&2
  exit 1
fi
if ! mv "$STAGED" "$DEST"; then
  echo "error: could not move $STAGED into place; kept build $old" >&2
  exit 1
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
