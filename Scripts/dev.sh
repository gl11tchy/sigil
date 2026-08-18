#!/usr/bin/env bash
# Debug-build the app bundle and run it in the foreground (stdout/stderr stay here).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SIGIL_CONFIG=debug "$SCRIPT_DIR/build-app.sh"
echo "==> launching $ROOT/dist/Sigil.app (Ctrl-C to quit)"
exec "$ROOT/dist/Sigil.app/Contents/MacOS/Sigil"
