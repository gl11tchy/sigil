#!/bin/bash
# Build the shipping app and both extensions, then test the app on a fresh
# simulator through the real loopback relay. No signing or provider credentials.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -z "${SIGIL_RELAY_PORT:-}" ]; then
  exec scripts/relay-e2e.sh scripts/native-test.sh
fi

ARTIFACTS="${SIGIL_NATIVE_ARTIFACTS:-$PWD/../.build/native-verification}"
mkdir -p "$ARTIFACTS"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/sigil-native.XXXXXX")"
SIMULATOR=""
cleanup() {
  if [ -n "$SIMULATOR" ]; then
    xcrun simctl shutdown "$SIMULATOR" >/dev/null 2>&1 || true
    xcrun simctl delete "$SIMULATOR" >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Discover the installed runtime instead of assuming a particular phone name.
xcrun simctl list -j > "$WORK/simulators.json"
python3 - "$WORK/simulators.json" "$WORK/device" "$WORK/runtime" <<'PY'
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
runtimes = [r for r in data['runtimes'] if r.get('isAvailable') and r['identifier'].startswith('com.apple.CoreSimulator.SimRuntime.iOS-') and int(r['version'].split('.')[0]) >= 26]
if not runtimes:
    raise SystemExit('Native verification requires Xcode 26 and an installed iOS 26+ simulator runtime.')
runtime = max(runtimes, key=lambda r: tuple(map(int, r['version'].split('.'))))
version = tuple(map(int, runtime['version'].split('.')))
encoded = (version[0] << 16) | (version[1] << 8)
devices = [d for d in data['devicetypes'] if d['name'].startswith('iPhone') and d.get('minRuntimeVersion', 0) <= encoded <= d.get('maxRuntimeVersion', 0xFFFFFFFF)]
if not devices:
    raise SystemExit('No compatible iPhone simulator device type is installed.')
Path(sys.argv[2]).write_text(devices[-1]['identifier'])
Path(sys.argv[3]).write_text(runtime['identifier'])
PY
SIMULATOR="$(xcrun simctl create "sigil-native-verify-$$" "$(cat "$WORK/device")" "$(cat "$WORK/runtime")")"
xcrun simctl boot "$SIMULATOR"
xcrun simctl bootstatus "$SIMULATOR" -b

xcodebuild -project Sigil.xcodeproj -scheme Sigil -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$SIMULATOR" -derivedDataPath "$WORK/DerivedData" \
  CODE_SIGNING_ALLOWED=NO SIGIL_RELAY_PORT="$SIGIL_RELAY_PORT" build-for-testing -quiet

APP="$WORK/DerivedData/Build/Products/Debug-iphonesimulator/Sigil.app"
for product in "$APP/Sigil" "$APP/PlugIns/SigilNotifications.appex/SigilNotifications" "$APP/PlugIns/SigilWidgets.appex/SigilWidgets"; do
  test -f "$product" || { echo "Missing shipping product: $product" >&2; exit 1; }
done
RESULT="$ARTIFACTS/native-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
TEST_RUNNER_SIGIL_RELAY_PORT="$SIGIL_RELAY_PORT" xcodebuild -project Sigil.xcodeproj -scheme Sigil -sdk iphonesimulator \
  -destination "platform=iOS Simulator,id=$SIMULATOR" -derivedDataPath "$WORK/DerivedData" \
  -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 60 \
  -resultBundlePath "$RESULT" CODE_SIGNING_ALLOWED=NO SIGIL_RELAY_PORT="$SIGIL_RELAY_PORT" test-without-building -quiet

echo "native: OK (Sigil.app, SigilNotifications.appex, SigilWidgets.appex; app-hosted simulator tests)"
echo "Evidence: $RESULT"
