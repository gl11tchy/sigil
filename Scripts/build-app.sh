#!/usr/bin/env bash
# Build dist/Sigil.app from the SwiftPM Sigil executable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FINAL_APP="$ROOT/dist/Sigil.app"
CONFIG="${SIGIL_CONFIG:-release}"
ALLOW_THIN="${SIGIL_ALLOW_THIN:-0}"
DISTRIBUTION="${SIGIL_DISTRIBUTION:-0}"
IDENTITY="${SIGIL_CODESIGN_IDENTITY:--}"
NOTARY_PROFILE="${SIGIL_NOTARY_PROFILE:-}"
NOTARY_TIMEOUT="${SIGIL_NOTARY_TIMEOUT:-30m}"
NOTARY_TMP=""
STAGING_ROOT=""

cleanup() {
  if [[ -n "$NOTARY_TMP" ]]; then
    rm -rf "$NOTARY_TMP"
  fi
  if [[ -n "$STAGING_ROOT" ]]; then
    rm -rf "$STAGING_ROOT"
  fi
}
trap cleanup EXIT

cd "$ROOT" || exit 1

if [[ "$DISTRIBUTION" == "1" ]]; then
  if [[ -z "${SIGIL_VERSION:-}" ]]; then
    echo "error: distribution builds require SIGIL_VERSION, for example 1.0.0" >&2
    exit 1
  fi
  if [[ -z "${SIGIL_BUILD:-}" ]]; then
    echo "error: distribution builds require SIGIL_BUILD, for example 1" >&2
    exit 1
  fi
fi

version="${SIGIL_VERSION:-1.0.0}"
if [[ -n "${SIGIL_BUILD:-}" ]]; then
  build="$SIGIL_BUILD"
elif git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  build="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
else
  build="1"
fi

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: SIGIL_VERSION must contain three numbers, for example 1.0.0" >&2
  exit 1
fi
if [[ ! "$build" =~ ^[1-9][0-9]*(\.[0-9]+){0,2}$ ]]; then
  echo "error: SIGIL_BUILD must be a positive number with at most three parts" >&2
  exit 1
fi

case "$ALLOW_THIN" in
  0 | 1) ;;
  *)
    echo "error: SIGIL_ALLOW_THIN must be 0 or 1 (got: $ALLOW_THIN)" >&2
    exit 1
    ;;
esac
case "$DISTRIBUTION" in
  0 | 1) ;;
  *)
    echo "error: SIGIL_DISTRIBUTION must be 0 or 1 (got: $DISTRIBUTION)" >&2
    exit 1
    ;;
esac
case "$CONFIG" in
  debug | release) ;;
  *)
    echo "error: SIGIL_CONFIG must be release or debug (got: $CONFIG)" >&2
    exit 1
    ;;
esac
if [[ "$DISTRIBUTION" == "1" ]]; then
  if [[ "$CONFIG" != "release" ]]; then
    echo "error: distribution builds require SIGIL_CONFIG=release" >&2
    exit 1
  fi
  if [[ "$ALLOW_THIN" == "1" ]]; then
    echo "error: distribution builds cannot set SIGIL_ALLOW_THIN=1" >&2
    exit 1
  fi
  if [[ "$IDENTITY" == "-" ]]; then
    echo "error: set SIGIL_CODESIGN_IDENTITY to a Developer ID Application identity" >&2
    exit 1
  fi
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "error: set SIGIL_NOTARY_PROFILE to a notarytool keychain profile" >&2
    exit 1
  fi
  if [[ ! "$NOTARY_TIMEOUT" =~ ^[1-9][0-9]*[smh]?$ ]]; then
    echo "error: SIGIL_NOTARY_TIMEOUT must be a positive duration such as 30m" >&2
    exit 1
  fi
fi
identity_line=""
if [[ "$IDENTITY" != "-" ]]; then
  identity_line="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -F -- "$IDENTITY" | head -n 1 || true)"
  if [[ -z "$identity_line" ]]; then
    echo "error: signing identity not found: $IDENTITY" >&2
    exit 1
  fi
  if [[ "$DISTRIBUTION" == "1" && "$identity_line" != *"Developer ID Application:"* ]]; then
    echo "error: distribution requires a Developer ID Application identity" >&2
    exit 1
  fi
fi

# A failed build must not leave an older bundle looking like its output.
rm -rf "$FINAL_APP"

if [[ "$CONFIG" == "release" ]]; then
  if ! xcrun --sdk macosx metal --version >/dev/null 2>&1; then
    echo "error: release builds need Apple's Metal Toolchain" >&2
    echo "install it with: xcodebuild -downloadComponent MetalToolchain" >&2
    exit 1
  fi
  apple_products="Release"
  config_dir="release"
  echo "==> swift build -c release (universal)"
  # Never let a failed build leave an older universal product eligible for packaging.
  rm -f \
    "$ROOT/.build/apple/Products/${apple_products}/Sigil" \
    "$ROOT/.build/apple/Products/${apple_products}/sigil-mcp"
  if swift build -c release --arch arm64 --arch x86_64; then
    echo "Built a universal (arm64 + x86_64) binary."
    products_dir="$ROOT/.build/apple/Products/${apple_products}"
    built_universal=1
  else
    if [[ "$ALLOW_THIN" != "1" ]]; then
      echo "error: universal build failed; refusing to publish a host-only app" >&2
      echo "set SIGIL_ALLOW_THIN=1 only for a local development bundle" >&2
      exit 1
    fi
    echo "WARNING: universal build failed; building an explicit local-only $(uname -m) bundle." >&2
    swift build -c release
    products_dir="$ROOT/.build/${config_dir}"
    built_universal=0
  fi
elif [[ "$CONFIG" == "debug" ]]; then
  config_dir="debug"
  echo "==> swift build (debug)"
  swift build
  products_dir="$ROOT/.build/${config_dir}"
  built_universal=0
else
  echo "error: SIGIL_CONFIG must be release or debug (got: $CONFIG)" >&2
  exit 1
fi

BINARY="$products_dir/Sigil"

if [[ ! -f "$BINARY" || ! -x "$BINARY" ]]; then
  echo "error: could not find the Sigil executable after the build" >&2
  echo "looked in: $BINARY" >&2
  exit 1
fi

# The tab-messaging helper ships beside the app binary; the Settings switch
# looks for it there, and stays disabled when it is missing.
MCP_BINARY="$products_dir/sigil-mcp"

if [[ ! -f "$MCP_BINARY" || ! -x "$MCP_BINARY" ]]; then
  echo "error: could not find the sigil-mcp helper after the build" >&2
  echo "looked in: $MCP_BINARY" >&2
  exit 1
fi

echo "==> using $BINARY"
echo "==> using $MCP_BINARY"
LIPO="$(xcrun --find lipo 2>/dev/null || command -v lipo || true)"
if [[ "$built_universal" == "1" ]]; then
  if [[ -z "$LIPO" ]]; then
    echo "error: lipo is required to verify a universal build" >&2
    exit 1
  fi
  "$LIPO" -verify_arch arm64 x86_64 "$BINARY"
  "$LIPO" -verify_arch arm64 x86_64 "$MCP_BINARY"
  "$LIPO" -info "$BINARY"
  "$LIPO" -info "$MCP_BINARY"
elif [[ -n "$LIPO" ]]; then
  "$LIPO" -info "$BINARY"
  "$LIPO" -info "$MCP_BINARY"
fi

if [[ "$DISTRIBUTION" == "1" && "$built_universal" != "1" ]]; then
  echo "error: distribution builds must be universal" >&2
  exit 1
fi

ICNS="$ROOT/Resources/Sigil.icns"
if [[ ! -s "$ICNS" ]]; then
  echo "==> Resources/Sigil.icns missing; running Scripts/make-icon.sh"
  "$SCRIPT_DIR/make-icon.sh"
fi
if [[ ! -s "$ICNS" ]]; then
  echo "error: $ICNS is missing; run Scripts/make-icon.sh" >&2
  exit 1
fi

PLIST_TEMPLATE="$ROOT/Resources/Info.plist"
if [[ ! -f "$PLIST_TEMPLATE" ]]; then
  echo "error: missing $PLIST_TEMPLATE" >&2
  exit 1
fi

mkdir -p "$ROOT/dist"
STAGING_ROOT="$(mktemp -d "$ROOT/dist/.sigil-stage.XXXXXX")"
APP="$STAGING_ROOT/Sigil.app"
CONTENTS="$APP/Contents"
echo "==> assembling $FINAL_APP (version $version build $build)"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BINARY" "$CONTENTS/MacOS/Sigil"
chmod +x "$CONTENTS/MacOS/Sigil"
cp "$MCP_BINARY" "$CONTENTS/MacOS/sigil-mcp"
chmod +x "$CONTENTS/MacOS/sigil-mcp"
cp "$ICNS" "$CONTENTS/Resources/Sigil.icns"
cp "$ROOT/LICENSE" "$CONTENTS/Resources/LICENSE.txt"
mkdir -p "$CONTENTS/Resources/ThirdPartyLicenses"
for license in \
  "$ROOT/Resources/ThirdPartyLicenses/SwiftTerm-LICENSE.txt" \
  "$ROOT/Resources/ThirdPartyLicenses/swift-argument-parser-LICENSE.txt"; do
  if [[ ! -f "$license" ]]; then
    echo "error: missing third-party license: $license" >&2
    exit 1
  fi
done
cp "$ROOT/Resources/ThirdPartyLicenses/SwiftTerm-LICENSE.txt" \
  "$CONTENTS/Resources/ThirdPartyLicenses/SwiftTerm-LICENSE.txt"
cp "$ROOT/Resources/ThirdPartyLicenses/swift-argument-parser-LICENSE.txt" \
  "$CONTENTS/Resources/ThirdPartyLicenses/swift-argument-parser-LICENSE.txt"
printf 'APPL????' >"$CONTENTS/PkgInfo"

cp "$PLIST_TEMPLATE" "$CONTENTS/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$build" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

if grep -q '__VERSION__\|__BUILD__' "$CONTENTS/Info.plist"; then
  echo "error: Info.plist still contains template placeholders" >&2
  exit 1
fi

# macOS ties folder permissions to the code signature. An ad-hoc signature changes
# on every build, so every build looks like a new app and the grants are thrown
# away — you get asked for Desktop, Documents and Downloads again each time.
# Signing with a real identity keeps the signature stable, so the grants stick.
#
# Local builds are ad-hoc by default. Distribution builds must explicitly name
# a Developer ID identity and are hardened, timestamped, notarized, and stapled.
if [[ "$IDENTITY" != "-" ]]; then
  echo "==> codesign (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$CONTENTS/MacOS/sigil-mcp"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$CONTENTS/MacOS/Sigil"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
  echo "==> ad-hoc codesign (local build)"
  codesign --force --deep --sign - "$APP"
fi
echo "==> codesign --verify --deep --strict"
if ! codesign --verify --deep --strict "$APP"; then
  echo "error: codesign verification failed for $APP" >&2
  exit 1
fi

if [[ "$DISTRIBUTION" == "1" ]]; then
  NOTARY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sigil-notary.XXXXXX")"
  archive="$NOTARY_TMP/Sigil.zip"
  submission_json="$NOTARY_TMP/submission.json"
  result_json="$NOTARY_TMP/result.json"
  echo "==> notarize"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$archive"
  xcrun notarytool submit "$archive" \
    --keychain-profile "$NOTARY_PROFILE" \
    --output-format json >"$submission_json"
  submission_id="$(plutil -extract id raw -o - "$submission_json" 2>/dev/null || true)"
  if [[ -z "$submission_id" ]]; then
    echo "error: notarytool did not return a submission id" >&2
    cat "$submission_json" >&2
    exit 1
  fi
  echo "==> notarization submission: $submission_id"
  if ! xcrun notarytool wait "$submission_id" \
    --keychain-profile "$NOTARY_PROFILE" \
    --timeout "$NOTARY_TIMEOUT" \
    --output-format json >"$result_json"; then
    cat "$result_json" >&2 || true
    echo "error: notarization did not finish successfully; submission: $submission_id" >&2
    exit 1
  fi
  notary_status="$(plutil -extract status raw -o - "$result_json" 2>/dev/null || true)"
  if [[ "$notary_status" != "Accepted" ]]; then
    cat "$result_json" >&2
    echo "error: notarization status is ${notary_status:-unknown}; submission: $submission_id" >&2
    exit 1
  fi
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
  codesign --verify --deep --strict "$APP"
  spctl --assess --type execute --verbose=2 "$APP"
fi

mv "$APP" "$FINAL_APP"
echo "Built $FINAL_APP"
