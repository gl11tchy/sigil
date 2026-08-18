#!/usr/bin/env bash
# Build dist/GrokBuild.app from the SwiftPM GrokBuild executable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP="$ROOT/dist/GrokBuild.app"
CONTENTS="$APP/Contents"
CONFIG="${GROKBUILD_CONFIG:-release}"

cd "$ROOT" || exit 1

if [[ "$CONFIG" == "release" ]]; then
  apple_products="Release"
  config_dir="release"
  echo "==> swift build -c release (universal)"
  if swift build -c release --arch arm64 --arch x86_64; then
    echo "Built a universal (arm64 + x86_64) binary."
  else
    echo "WARNING: universal build (arm64 + x86_64) failed on this toolchain." >&2
    echo "WARNING: falling back to host architecture: $(uname -m)." >&2
    swift build -c release
  fi
elif [[ "$CONFIG" == "debug" ]]; then
  apple_products="Debug"
  config_dir="debug"
  echo "==> swift build (debug)"
  swift build
else
  echo "error: GROKBUILD_CONFIG must be release or debug (got: $CONFIG)" >&2
  exit 1
fi

BINARY=""
for candidate in \
  "$ROOT/.build/apple/Products/${apple_products}/GrokBuild" \
  "$ROOT/.build/${config_dir}/GrokBuild"; do
  if [[ -f "$candidate" && -x "$candidate" ]]; then
    BINARY="$candidate"
    break
  fi
done

if [[ -z "$BINARY" ]]; then
  echo "error: could not find the GrokBuild executable after the build" >&2
  echo "looked in:" >&2
  echo "  $ROOT/.build/apple/Products/${apple_products}/GrokBuild" >&2
  echo "  $ROOT/.build/${config_dir}/GrokBuild" >&2
  exit 1
fi

echo "==> using $BINARY"
if command -v lipo >/dev/null 2>&1; then
  lipo -info "$BINARY" || true
fi

ICNS="$ROOT/Resources/GrokBuild.icns"
if [[ ! -s "$ICNS" ]]; then
  echo "==> Resources/GrokBuild.icns missing; running Scripts/make-icon.sh"
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

version="${GROKBUILD_VERSION:-0.1.0}"
if [[ -n "${GROKBUILD_BUILD:-}" ]]; then
  build="$GROKBUILD_BUILD"
elif git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  build="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)"
else
  build="1"
fi

echo "==> assembling $APP (version $version build $build)"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BINARY" "$CONTENTS/MacOS/GrokBuild"
chmod +x "$CONTENTS/MacOS/GrokBuild"
cp "$ICNS" "$CONTENTS/Resources/GrokBuild.icns"
printf 'APPL????' >"$CONTENTS/PkgInfo"

sed \
  -e "s|__VERSION__|${version}|g" \
  -e "s|__BUILD__|${build}|g" \
  "$PLIST_TEMPLATE" >"$CONTENTS/Info.plist"

if grep -q '__VERSION__\|__BUILD__' "$CONTENTS/Info.plist"; then
  echo "error: Info.plist still contains template placeholders" >&2
  exit 1
fi

echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP"
echo "==> codesign --verify --deep --strict"
if ! codesign --verify --deep --strict "$APP"; then
  echo "error: codesign verification failed for $APP" >&2
  exit 1
fi

echo "Built $APP"
