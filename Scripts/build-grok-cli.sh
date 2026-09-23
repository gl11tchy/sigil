#!/usr/bin/env bash
# Build the app's own CLI: upstream Grok Build plus the Sigil Neon TUI theme.
#
# The app draws a frame around a program someone else wrote. Theming only the
# frame leaves two designs in one window, so the app ships a build of the
# open-source CLI that carries a matching `sigil-neon` theme and honours
# GROK_THEME. The result is installed as ~/.grok/bin/grok-sigil, which the app
# prefers over the installer's ~/.grok/bin/grok when it is there.
#
# Requirements: rust (1.94+), protoc, git. Nothing here touches the installed
# `grok`: remove grok-sigil and the app falls back to it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PATCH="$SCRIPT_DIR/grok-cli/sigil-neon.patch"
HOST_PATCH="$SCRIPT_DIR/grok-cli/sigil-host.patch"
# The upstream commit the patch is written against.
UPSTREAM_REV="${GROK_CLI_REV:-9684fa3cdbf2995e30ea8b9b637f1db008f144fc}"
REPO="${GROK_CLI_SRC:-$HOME/Documents/grok-build-sigil}"
DEST="${GROK_CLI_DEST:-$HOME/.grok/bin/grok-sigil}"

for tool in git cargo protoc; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool is required (protoc: brew install protobuf)" >&2
    exit 1
  }
done

if [[ ! -d "$REPO/.git" ]]; then
  echo "==> cloning xai-org/grok-build into $REPO"
  git clone https://github.com/xai-org/grok-build "$REPO"
fi

cd "$REPO"
if ! git cat-file -e "$UPSTREAM_REV^{commit}" 2>/dev/null; then
  git fetch origin "$UPSTREAM_REV"
fi
git cat-file -e "$UPSTREAM_REV^{commit}" || {
  echo "error: upstream revision $UPSTREAM_REV is not available in $REPO" >&2
  exit 1
}

# Read the log once: `git log | grep -q` can die of SIGPIPE under pipefail.
recent="$(git log --oneline -20)"
# The patches are written against UPSTREAM_REV, not whatever HEAD the clone has.
if [[ "$recent" != *"Sigil Neon"* && "$recent" != *"GROK_THEME_*"* ]]; then
  echo "==> checking out $UPSTREAM_REV"
  git checkout --detach "$UPSTREAM_REV"
fi

if [[ "$recent" == *"Sigil Neon"* ]]; then
  echo "==> neon patch already applied"
else
  echo "==> applying $PATCH"
  git am --keep-cr <"$PATCH"
fi
if [[ "$recent" == *"GROK_THEME_*"* ]]; then
  echo "==> host patch already applied"
else
  echo "==> applying $HOST_PATCH"
  git am --keep-cr <"$HOST_PATCH"
fi

echo "==> cargo build -p xai-grok-pager-bin --release"
PROTOC="${PROTOC:-$(command -v protoc)}" cargo build -p xai-grok-pager-bin --release

mkdir -p "$(dirname "$DEST")"
install -m 0755 "$REPO/target/release/xai-grok-pager" "$DEST"
echo "==> installed $DEST"
"$DEST" --version
