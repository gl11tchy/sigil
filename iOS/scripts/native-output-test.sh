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
ARTIFACTS="${SIGIL_NATIVE_ARTIFACTS:-$PWD/../.build/native-verification}"
mkdir -p "$ARTIFACTS"
# Only this synthetic fixture's streams are captured. Writes are unbuffered,
# capped independently at 2 MiB, with a separate bounded phase-marker file.
exec 3>&1 4>&2
# Explicit asynchronous children are waitable by this shell, including /bin/bash
# on the hosted Mac. Process-substitution PIDs were not waitable in its EXIT trap.
mkfifo "$WORK/stdout.pipe" "$WORK/stderr.pipe"
python3 scripts/native-output-log.py "$ARTIFACTS" stdout < "$WORK/stdout.pipe" >&3 2>&4 &
STDOUT_LOGGER=$!
python3 scripts/native-output-log.py "$ARTIFACTS" stderr < "$WORK/stderr.pipe" >&4 2>&4 &
STDERR_LOGGER=$!
exec > "$WORK/stdout.pipe" 2> "$WORK/stderr.pipe"
phase() {
  printf 'SIGIL_TEXTKIT time=%s phase=%s\n' "$(date +%s)" "$1"
}
cleanup() {
  local rc=$? stdout_rc=0 stderr_rc=0
  # The body status precedes cleanup; it must not claim the final script status.
  phase "body-exit-$rc"
  if [ -z "${SIGIL_NATIVE_TEST_DEVICE:-}" ] && [ -n "$DEVICE" ]; then
    xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
    xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
  # Close both writers and wait for capture to drain before artifact upload.
  exec 1>&3 2>&4
  wait "$STDOUT_LOGGER" || stdout_rc=$?
  wait "$STDERR_LOGGER" || stderr_rc=$?
  if [ "$stdout_rc" -ne 0 ]; then
    printf 'TextKit stdout capture failed (exit %s)\n' "$stdout_rc" >&2
    if [ "$rc" -eq 0 ]; then rc="$stdout_rc"; fi
  fi
  if [ "$stderr_rc" -ne 0 ]; then
    printf 'TextKit stderr capture failed (exit %s)\n' "$stderr_rc" >&2
    if [ "$rc" -eq 0 ]; then rc="$stderr_rc"; fi
  fi
  exit "$rc"
}
trap cleanup EXIT

phase build-start
mkdir -p "$APP"
SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
FILES=$(find Shared Sigil/Core/Networking Sigil/Core/Utilities NativeTests -name '*.swift' ! -name 'NativeFlowTests.swift' | sort)

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
phase build-complete

phase simulator-select-start
if [ -z "$DEVICE" ]; then
  DEVICE="$(xcrun simctl create "Sigil native tests $$" "${SIGIL_NATIVE_TEST_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro}")"
fi
phase simulator-boot-wait
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
phase simulator-ready
phase app-install-start
xcrun simctl install "$DEVICE" "$APP"
phase app-install-complete
phase app-launch-request
xcrun simctl launch --console-pty --terminate-running-process "$DEVICE" "$BUNDLE" | tee "$WORK/output.txt"
phase app-launch-returned
grep -q '^OK ' "$WORK/output.txt"
phase success-sentinel-verified
