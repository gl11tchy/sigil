#!/bin/bash
# Archive the iPhone app and upload it to App Store Connect for TestFlight.
# The build number is the UTC time, so a ship never needs a bump commit.
# Ends on one line: UPLOADED: or FAILED:. Upload alone reaches a phone only
# through an internal tester group with automatic distribution on.
set -euo pipefail

cd "$(dirname "$0")/.."

TEAM=$(grep -m1 -oE 'DEVELOPMENT_TEAM = [A-Z0-9]+' Sigil.xcodeproj/project.pbxproj | awk '{print $3}')
BUILD=$(date -u +%Y%m%d%H%M)
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/sigil-ship.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

# Written at run time so the team id never lands in a tracked plist.
cat > "$SCRATCH/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>            <string>app-store-connect</string>
    <key>destination</key>       <string>upload</string>
    <key>teamID</key>            <string>${TEAM}</string>
    <key>uploadSymbols</key>     <true/>
    <key>signingStyle</key>      <string>automatic</string>
    <key>manageAppVersionAndBuildNumber</key> <false/>
</dict>
</plist>
PLIST

echo "Archiving build $BUILD..."
if ! xcodebuild archive -project Sigil.xcodeproj -scheme Sigil -destination "generic/platform=iOS" \
    -archivePath "$SCRATCH/Sigil.xcarchive" -allowProvisioningUpdates -quiet \
    DEVELOPMENT_TEAM="$TEAM" CURRENT_PROJECT_VERSION="$BUILD"; then
  echo "FAILED: archive failed; see the errors above."
  exit 1
fi

echo "Uploading build $BUILD..."
if ! xcodebuild -exportArchive -archivePath "$SCRATCH/Sigil.xcarchive" \
    -exportOptionsPlist "$SCRATCH/ExportOptions.plist" -exportPath "$SCRATCH/export" \
    -allowProvisioningUpdates; then
  echo "FAILED: upload failed; see the errors above."
  exit 1
fi

echo "UPLOADED: build $BUILD is in App Store Connect. Apple takes 10 to 20 minutes to process it."
