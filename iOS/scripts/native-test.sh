#!/bin/bash
# Build NativeTests/ with the output view for the iOS simulator and run it, so
# the output checks use UIKit and TextKit 2 themselves. The run gets a simulator
# of its own, deleted afterwards; set SIGIL_NATIVE_TEST_DEVICE to a simulator's
# UDID to use that one instead. Exits non-zero on any failing test.
set -euo pipefail

cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
APP="$WORK/SigilNativeTests.app"
BUNDLE=dev.sigil.native-tests
DEVICE="${SIGIL_NATIVE_TEST_DEVICE:-}"
cleanup() {
  if [ -z "${SIGIL_NATIVE_TEST_DEVICE:-}" ] && [ -n "$DEVICE" ]; then
    xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
FILES=$(find Shared Sigil/Core/Networking Sigil/Core/Utilities NativeTests -name '*.swift' | sort)

# shellcheck disable=SC2086
xcrun swiftc \
  -O \
  -sdk "$SDK" \
  -target arm64-apple-ios26.0-simulator \
  -swift-version 5 \
  -parse-as-library \
  -o "$APP/SigilNativeTests" \
  $FILES \
  Sigil/Features/Session/OutputView.swift Sigil/Features/Shared/Theme.swift \
  Tests/TestSupport.swift Tests/IOSOutputFixtures.swift Tests/IOSOutputEditTests.swift

cp Sigil/Resources/readable-output.js Sigil/Resources/Fonts/*.ttf "$APP/"
FONTS=""
for font in "$APP"/*.ttf; do FONTS="$FONTS<string>$(basename "$font")</string>"; done
cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$BUNDLE</string>
<key>CFBundleName</key><string>SigilNativeTests</string>
<key>CFBundleExecutable</key><string>SigilNativeTests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>1</string>
<key>MinimumOSVersion</key><string>26.0</string>
<key>UIDeviceFamily</key><array><integer>1</integer></array>
<key>UIAppFonts</key><array>$FONTS</array>
<key>UILaunchScreen</key><dict/>
<key>UIApplicationSceneManifest</key><dict><key>UIApplicationSupportsMultipleScenes</key><false/></dict>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null

if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl create "Sigil native tests $$" "${SIGIL_NATIVE_TEST_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}")"
fi
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" "$BUNDLE" | tee "$WORK/output.txt"
grep -q '^OK ' "$WORK/output.txt"
