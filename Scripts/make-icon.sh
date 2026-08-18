#!/usr/bin/env bash
# Generate Resources/Sigil.icns from a drawn PNG iconset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="$ROOT/Resources"
ICNS="$RESOURCES/Sigil.icns"

mkdir -p "$RESOURCES"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/sigil-icon.XXXXXX")"
ICONSET="$WORKDIR/Sigil.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$WORKDIR"' EXIT

swift "$SCRIPT_DIR/DrawIcon.swift" "$ICONSET"

if ! command -v iconutil >/dev/null 2>&1; then
  echo "error: iconutil is required to build Sigil.icns" >&2
  exit 1
fi

iconutil -c icns -o "$ICNS" "$ICONSET"

if [[ ! -s "$ICNS" ]]; then
  echo "error: iconutil did not write $ICNS" >&2
  exit 1
fi

echo "Wrote $ICNS"
