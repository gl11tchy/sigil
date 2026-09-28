#!/usr/bin/env bash
# Upload only the stamped relay bundle, not a checkout or local credentials.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/sigil-sidereal-deploy.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
for file in Dockerfile package.json package-lock.json server.mjs apns.mjs revision.mjs; do
  cp "$ROOT/Sidereal/$file" "$STAGE/$file"
done
cp -R "$ROOT/Sidereal/public" "$STAGE/public"
node "$ROOT/Sidereal/stamp-revision.mjs" "$STAGE"
# The image build needs the stamp; a bundle without it must never leave this Mac.
[[ -s "$STAGE/revision.json" ]] || { echo "deploy-sidereal: revision.json was not written to $STAGE" >&2; exit 1; }
railway up "$STAGE" --path-as-root "$@"
