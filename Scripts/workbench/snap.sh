#!/bin/bash
# Screenshots the renamed bundle's window by window id. usage: snap.sh <out.png>
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
wid="$("$(wb_tool winid)" "$WB_NAME" | head -1 | cut -d' ' -f1)"
[[ -n "$wid" ]] || { echo "no $WB_NAME window" >&2; exit 1; }
screencapture -x -o -l "$wid" "$1"
echo "$1"
