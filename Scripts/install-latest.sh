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

# Canonicalize as much of the path as exists. Walking up to the nearest real
# directory matters because a build output that does not exist yet can still
# sit under a symlink into the installed app, and the part that does not exist
# can still point back inside it through ..
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

# True when the two paths are the same bundle, or when one sits inside the
# other: building below the installed app would rewrite it in place.
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

# The destination is moved aside and the old copy is deleted on the way out, so
# be certain it is a Sigil bundle and not a directory that merely holds one. A
# stray SIGIL_INSTALL_APP of /Applications or a home directory would otherwise
# be carried off wholesale.
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

# One installer at a time, taken before anything reads the destination: the
# other installer could otherwise finish between a check here and the swap
# below, and the checks would have looked at a bundle that no longer exists.
if ! mkdir "$LOCK" 2>/dev/null; then
  echo "error: another install is already running" >&2
  echo "if that is not true, remove $LOCK and try again" >&2
  exit 1
fi
HELD_LOCK=1

# build-app.sh deletes its own output before it builds. If that output is the
# installed app, or anything inside it, a failed build would take the
# installation, or its signature, with it.
if overlaps "$SRC" "$DEST"; then
  echo "error: the build output and the install destination overlap" >&2
  echo "       build: $SRC" >&2
  echo "     install: $DEST" >&2
  echo "point SIGIL_APP somewhere outside the installed app" >&2
  exit 1
fi

# Anything the build would compile but HEAD does not carry: a change to a
# tracked file anywhere, or an untracked file under the sources SwiftPM and
# build-app.sh read. Untracked files elsewhere, dist/ and scratch notes among
# them, are not build inputs and do not count.
build_inputs_differ_from_head() {
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no)" ]]; then
    return 0
  fi
  if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=all -- \
    Sources Tests Resources Package.swift Package.resolved \
    'Package@swift-*.swift' 2>/dev/null)" ]]; then
    return 0
  fi
  # Ignored files count too when they sit under the sources, because SwiftPM
  # compiles them regardless. Scoped to those paths so .build and dist, which
  # are ignored on purpose, do not make every install refuse. Finder's
  # .DS_Store is never a build input. Git quotes a path with a space in it.
  local ignored
  ignored="$(git -C "$ROOT" status --porcelain --ignored=matching -- \
    Sources Tests Resources 2>/dev/null | grep -v '/\.DS_Store"\?$' || true)"
  if [[ -n "$ignored" ]]; then
    return 0
  fi
  # Dependency sources are compiled from .build/checkouts, which is ignored, so
  # a checkout edited while debugging a dependency would ship unnoticed.
  local checkout
  for checkout in "$ROOT"/.build/checkouts/*/; do
    if [[ -d "$checkout/.git" ]] \
      && [[ -n "$(git -C "$checkout" status --porcelain 2>/dev/null)" ]]; then
      return 0
    fi
  done
  return 1
}

# The build compiles the working tree but stamps the build number from HEAD, so
# uncommitted work would install as if it were the merged build.
if [[ -z "${SIGIL_ALLOW_DIRTY:-}" ]] && git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  if build_inputs_differ_from_head; then
    echo "error: the working tree does not match HEAD" >&2
    echo "this installs HEAD, and the build number comes from HEAD, so the app" >&2
    echo "would not be what it claims to be" >&2
    echo "commit or stash first, use Scripts/install.sh for a local build, or set" >&2
    echo "SIGIL_ALLOW_DIRTY=1 to install the working tree anyway" >&2
    exit 1
  fi
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
