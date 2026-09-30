#!/bin/bash
# Reads or presses the renamed bundle's controls through accessibility. Never
# sends keystrokes. usage: ax.sh <pid> dump | ax.sh <pid> press <label prefix>
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
pid="$1"
[[ "$(ps -p "$pid" -o comm= | xargs basename)" == "$WB_NAME" ]] || { echo "pid $pid is not $WB_NAME" >&2; exit 1; }
"$(wb_tool axtool)" "$@"
