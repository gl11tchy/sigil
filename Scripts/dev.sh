#!/usr/bin/env bash
# Debug-build the app bundle and run it in the foreground (stdout/stderr stay here).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

GROKBUILD_CONFIG=debug "$SCRIPT_DIR/build-app.sh"
echo "==> launching $ROOT/dist/GrokBuild.app (Ctrl-C to quit)"
exec "$ROOT/dist/GrokBuild.app/Contents/MacOS/GrokBuild"
