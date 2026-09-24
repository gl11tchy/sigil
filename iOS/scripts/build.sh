#!/bin/bash
# Build the app for the iOS Simulator. This is the shipping gate — it does
# everything `typecheck.sh` does, plus asset compilation and linking.
#
# Usage: scripts/build.sh [simulator-name]
#
# Derived data goes to a temporary directory by default. Keeping it inside the
# repository breaks the asset catalog step under a sandboxed shell, which cannot
# write there. Set DERIVED_DATA to override.
set -euo pipefail

cd "$(dirname "$0")/.."

DEVICE="${1:-iPhone 17 Pro}"
DERIVED="${DERIVED_DATA:-${TMPDIR:-/tmp}/Sigil-DerivedData}"

xcodebuild \
  -project Sigil.xcodeproj \
  -scheme Sigil \
  -sdk iphonesimulator \
  -destination "platform=iOS Simulator,name=$DEVICE" \
  -derivedDataPath "$DERIVED" \
  -quiet \
  CODE_SIGNING_ALLOWED=NO \
  build

APP="$DERIVED/Build/Products/Debug-iphonesimulator/Sigil.app"
echo "build: OK → $APP"

# Printed on its own line so `install`/`launch` can read it back.
echo "$APP" > "${TMPDIR:-/tmp}/Sigil-app-path"
