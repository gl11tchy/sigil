#!/usr/bin/env bash
# Build each architecture with native SwiftPM, then join the verified products.
set -euo pipefail

if [[ "$#" != 1 || ! -d "$1" ]]; then
  echo "usage: Scripts/build-universal.sh <empty output directory>" >&2
  exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
OUTPUT="$(cd "$1" && pwd)"
for product in Sigil sigil-mcp; do
  if [[ -e "$OUTPUT/$product" || -L "$OUTPUT/$product" ]]; then
    echo "error: output directory already contains $product" >&2
    exit 1
  fi
done
SUCCESS=0
cleanup() {
  if [[ "$SUCCESS" != 1 ]]; then
    rm -f "$OUTPUT/Sigil" "$OUTPUT/sigil-mcp"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
LIPO="$(xcrun --find lipo 2>/dev/null || command -v lipo)"
cd "$ROOT"

# SwiftPM 6.3 switches a multi-arch request to XCBuild even with --build-system
# native. One architecture per invocation keeps the native resource/build path.
for architecture in arm64 x86_64; do
  scratch="$ROOT/.build/universal/$architecture"
  products="$(swift build -c release --build-system native --arch "$architecture" \
    --scratch-path "$scratch" --show-bin-path)"
  # A successful no-op or failed compile cannot reuse a stale executable.
  rm -f "$products/Sigil" "$products/sigil-mcp"
  echo "==> swift build -c release (native $architecture)"
  swift build -c release --build-system native --arch "$architecture" --scratch-path "$scratch"
  for product in Sigil sigil-mcp; do
    if [[ ! -f "$products/$product" || ! -x "$products/$product" ]]; then
      echo "error: missing $product output ($architecture): $products/$product" >&2
      exit 1
    fi
    "$LIPO" "$products/$product" -verify_arch "$architecture"
  done
  if [[ "$architecture" == arm64 ]]; then
    ARM_PRODUCTS="$products"
  else
    INTEL_PRODUCTS="$products"
  fi
done

for product in Sigil sigil-mcp; do
  "$LIPO" -create "$ARM_PRODUCTS/$product" "$INTEL_PRODUCTS/$product" -output "$OUTPUT/$product"
  chmod +x "$OUTPUT/$product"
  echo "==> lipo $OUTPUT/$product -verify_arch arm64 x86_64"
  "$LIPO" "$OUTPUT/$product" -verify_arch arm64 x86_64
  "$LIPO" -info "$OUTPUT/$product"
done
SUCCESS=1
