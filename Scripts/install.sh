#!/usr/bin/env bash
# Copy dist/Sigil.app into /Applications, replacing the running copy.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
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
DEST="${SIGIL_INSTALL_APP:-/Applications/Sigil.app}"
DEST_PARENT="$(dirname "$DEST")"
LOCK="$DEST_PARENT/.sigil-install.lock"
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

# Drop . and .. segments. Safe on the part of a path that does not exist, and
# on a prefix pwd -P has already resolved, because neither holds a symlink.
normalize_segments() {
  local path="$1" seg out=() parts=()
  IFS='/' read -r -a parts <<< "$path"
  for seg in "${parts[@]}"; do
    case "$seg" in
      '' | .) ;;
      ..)
        if [[ ${#out[@]} -gt 0 ]]; then
          # Not out[-1]: macOS ships bash 3.2, which has no negative subscript.
          unset "out[$((${#out[@]} - 1))]"
        fi
        ;;
      *) out+=("$seg") ;;
    esac
  done
  local joined=""
  for seg in ${out[@]+"${out[@]}"}; do
    joined="$joined/$seg"
  done
  printf '%s\n' "${joined:-/}"
}

# Canonicalize as much of the path as exists, so a symlink or a .. segment
# cannot hide that the source sits inside the destination.
resolve_path() {
  local path="$1" dir rest=""
  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P)
    return
  fi
  dir="$path"
  while [[ ! -d "$dir" && "$dir" != "/" && "$dir" != "." ]]; do
    rest="$(basename "$dir")${rest:+/$rest}"
    dir="$(dirname "$dir")"
  done
  if [[ -d "$dir" ]]; then
    dir="$(cd "$dir" && pwd -P)"
  fi
  normalize_segments "${dir%/}/$rest"
}

# Device and inode, so two spellings of one bundle compare equal even on a
# case-insensitive filesystem. Empty when the path does not exist yet.
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

# True when the two paths are the same bundle, or when one sits inside the
# other: replacing the destination would then delete the source.
overlaps() {
  local a="$1" b="$2" a_id b_id
  a_id="$(path_id "$a")"
  b_id="$(path_id "$b")"
  if [[ -n "$a_id" && "$a_id" == "$b_id" ]]; then
    return 0
  fi
  a="$(resolve_path "$a")"
  b="$(resolve_path "$b")"
  [[ "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]]
}

# Stage a complete copy and check it before touching the destination. A failed
# copy or signature check leaves the installed app as it was, and a failed
# final move puts the old bundle back through cleanup.
replace_bundle() {
  STAGING_ROOT="$(mktemp -d "$DEST_PARENT/.sigil-install.XXXXXX")"
  local staged="$STAGING_ROOT/Sigil.app"
  ditto "$SRC" "$staged"
  codesign --verify --deep --strict "$staged"
  if [[ -e "$DEST" ]]; then
    PREVIOUS="$STAGING_ROOT/previous-Sigil.app"
    mv "$DEST" "$PREVIOUS"
  fi
  # mv would move the bundle inside an existing directory of that name instead
  # of replacing it, so never run it with the destination occupied.
  if [[ -e "$DEST" ]]; then
    echo "error: $DEST reappeared during the install; leaving it alone" >&2
    exit 1
  fi
  mv "$staged" "$DEST"
}

if [[ ! -d "$SRC" ]]; then
  echo "error: no app bundle at $SRC" >&2
  echo "build one first: SIGIL_ALLOW_THIN=1 Scripts/build-app.sh" >&2
  exit 1
fi
if [[ ! -x "$SRC/Contents/MacOS/Sigil" ]]; then
  echo "error: $SRC is not a Sigil app bundle" >&2
  exit 1
fi

# This script does rm -rf on the destination, so be certain it is a Sigil
# bundle and not a directory that merely holds one.
case "$(basename "$DEST")" in
  *.app) ;;
  *)
    echo "error: the install destination is not an app bundle path" >&2
    echo "       $DEST" >&2
    exit 1
    ;;
esac
if [[ -e "$DEST" && ! -x "$DEST/Contents/MacOS/Sigil" ]]; then
  echo "error: $DEST exists and is not a Sigil app bundle; refusing to replace it" >&2
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

if overlaps "$SRC" "$DEST"; then
  echo "error: the app to install and the install destination overlap" >&2
  echo "        app: $SRC" >&2
  echo "    install: $DEST" >&2
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
replace_bundle
echo "==> opening $DEST"
open "$DEST"
