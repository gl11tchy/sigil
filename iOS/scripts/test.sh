#!/bin/bash
# Compile the platform-independent sources plus Tests/ as a macOS executable
# and run it. Exits non-zero on any failing test.
set -euo pipefail

cd "$(dirname "$0")/.."

# The phone formatter is the web companion's file. Never let the copies drift.
if ! cmp -s Sigil/Resources/readable-output.js ../Sidereal/public/output.mjs; then
  echo "FAIL Sigil/Resources/readable-output.js differs from Sidereal/public/output.mjs; copy it over." >&2
  exit 1
fi

OUT="$(mktemp -d)/Sigil-tests"
FILES=$(find Shared Sigil/Core/Networking Sigil/Core/Storage Sigil/Core/Utilities Tests \
  -name '*.swift' | sort)

if [ -z "$FILES" ]; then
  echo "No Swift sources found." >&2
  exit 1
fi

# shellcheck disable=SC2086
xcrun swiftc \
  -target arm64-apple-macosx14.0 \
  -swift-version 5 \
  -parse-as-library \
  -o "$OUT" \
  $FILES

"$OUT"
