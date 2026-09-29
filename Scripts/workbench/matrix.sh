#!/bin/bash
# Captures every fixture at narrow and wide sizes in both appearances.
# usage: matrix.sh <out dir> [narrow WxH] [wide WxH]
set -euo pipefail
here="$(dirname "$0")"
# shellcheck source=common.sh
source "$here/common.sh"
out="$1"; narrow="${2:-900x620}"; wide="${3:-1512x949}"
mkdir -p "$out"
for fixture in empty no-tasks one busy unavailable error; do
  for appearance in dark light; do
    for size in "narrow:$narrow" "wide:$wide"; do
      pid="$("$here/launch.sh" "$fixture" "$appearance" "${size#*:}")"
      "$here/snap.sh" "$out/$fixture-${size%%:*}-$appearance.png" >/dev/null
      kill "$pid"
      for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    done
  done
done
ls "$out"
