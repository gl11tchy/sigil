#!/usr/bin/env bash
# Generate Resources/GrokBuild.icns from a drawn PNG iconset.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RESOURCES="$ROOT/Resources"
ICNS="$RESOURCES/GrokBuild.icns"

mkdir -p "$RESOURCES"

WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/grokbuild-icon.XXXXXX")"
ICONSET="$WORKDIR/GrokBuild.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$WORKDIR"' EXIT

swift "$SCRIPT_DIR/DrawIcon.swift" "$ICONSET"

if ! command -v iconutil >/dev/null 2>&1; then
  echo "error: iconutil is required to build GrokBuild.icns" >&2
  exit 1
fi

iconutil -c icns -o "$ICNS" "$ICONSET"

if [[ ! -s "$ICNS" ]]; then
  echo "error: iconutil did not write $ICNS" >&2
  exit 1
fi

echo "Wrote $ICNS"
