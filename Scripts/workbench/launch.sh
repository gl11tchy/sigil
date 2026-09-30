#!/bin/bash
# Starts the renamed bundle on one fixture in an isolated home and prints its pid.
# usage: launch.sh <empty|no-tasks|one|busy|unavailable|error> <dark|light> <WxH> [open|closed]
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
fixture="$1"; appearance="$2"; size="$3"; review="${4:-open}"
if pgrep -x "$WB_NAME" >/dev/null; then echo "a $WB_NAME is already running" >&2; exit 1; fi
mkdir -p "$WB_HOME/tmp" "$WB_HOME/cache" "$WB_HOME/config" "$WB_HOME/.grok"
rm -rf "$WB_HOME/fixtures"; mkdir -p "$WB_HOME/fixtures"
# An empty environment: the app must never inherit this shell's PATH and
# reach a real CLI. Every folder it may use is inside the fake home.
env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin open -n -a "$WB_APP" \
  --env HOME="$WB_HOME" --env CFFIXED_USER_HOME="$WB_HOME" --env GROK_HOME="$WB_HOME/.grok" \
  --env TMPDIR="$WB_HOME/tmp/" --env XDG_CACHE_HOME="$WB_HOME/cache" --env XDG_CONFIG_HOME="$WB_HOME/config" \
  --env XCTestConfigurationFilePath=/dev/null --env SHELL=/bin/zsh \
  --env SIGIL_WORKBENCH_ROOT="$WB_HOME/fixtures" --env SIGIL_WORKBENCH_FIXTURE="$fixture" \
  --env SIGIL_WORKBENCH_APPEARANCE="$appearance" --env SIGIL_WORKBENCH_WINDOW="$size" \
  --env SIGIL_WORKBENCH_REVIEW="$review"
pid=""
for _ in $(seq 1 50); do pid="$(pgrep -x "$WB_NAME" || true)"; [[ -n "$pid" ]] && break; sleep 0.2; done
[[ -n "$pid" ]] || { echo "no $WB_NAME process" >&2; exit 1; }
sleep "${WB_SETTLE:-4}"
echo "$pid"
