#!/usr/bin/env bash
# Stage one verified source upload, then wait for its identity on /health.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec node "$SCRIPT_DIR/deploy-service.mjs" site "$@"
