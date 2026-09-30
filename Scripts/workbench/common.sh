#!/bin/bash
# Shared settings for the workbench harness. Sourced by the other scripts.
# Everything lives under WB_ROOT, outside /tmp so Sigil does not treat it as scratch.
WB_ROOT="${WB_ROOT:-/Users/Shared/sigil-ux/wb}"
WB_NAME="${WB_NAME:-SigilWB}"
WB_BUNDLE_ID="${WB_BUNDLE_ID:-com.gl11tchy.sigil.workbench}"
WB_APP="$WB_ROOT/$WB_NAME.app"
WB_HOME="$WB_ROOT/home"
WB_BIN="$WB_ROOT/bin"
HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export WB_ROOT WB_NAME WB_BUNDLE_ID WB_APP WB_HOME WB_BIN HARNESS_DIR

# Compiles the small AppKit helpers once.
wb_tool() {
  local name="$1"
  mkdir -p "$WB_BIN"
  if [[ ! -x "$WB_BIN/$name" || "$HARNESS_DIR/tools/$name.swift" -nt "$WB_BIN/$name" ]]; then
    swiftc -O "$HARNESS_DIR/tools/$name.swift" -o "$WB_BIN/$name" >/dev/null
  fi
  echo "$WB_BIN/$name"
}
