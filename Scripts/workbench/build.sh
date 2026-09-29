#!/bin/bash
# Builds a debug Sigil bundle from this checkout and renames it, so AX and
# screenshots can never reach the owner's running Sigil. usage: build.sh
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"
repo="$(cd "$HARNESS_DIR/../.." && pwd)"
mkdir -p "$WB_ROOT"
(cd "$repo" && SIGIL_CONFIG=debug SIGIL_APP="$WB_ROOT/Sigil.app" SIGIL_CODESIGN_IDENTITY=- \
  Scripts/build-app.sh >"$WB_ROOT/build.log" 2>&1) || { tail -20 "$WB_ROOT/build.log"; exit 1; }
rm -rf "$WB_APP"
cp -R "$WB_ROOT/Sigil.app" "$WB_APP"
mv "$WB_APP/Contents/MacOS/Sigil" "$WB_APP/Contents/MacOS/$WB_NAME"
plist="$WB_APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $WB_NAME" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $WB_NAME" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $WB_NAME" "$plist" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $WB_NAME" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $WB_BUNDLE_ID" "$plist"
codesign -f -s - --deep "$WB_APP" >/dev/null 2>&1
echo "$WB_APP"
