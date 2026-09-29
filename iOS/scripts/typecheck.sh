#!/bin/bash
# Type-check every Swift source against the iOS simulator SDK.
#
# This is the project's verification command. `xcodebuild` needs an installed iOS
# platform runtime, which this machine may not have, so the whole module is
# type-checked with swiftc instead. It catches everything a compile would except
# linking and asset processing.
set -euo pipefail

cd "$(dirname "$0")/.."

SDK="$(xcrun --sdk iphonesimulator --show-sdk-path)"
FILES=$(find Shared Sigil -name '*.swift' | sort)

if [ -z "$FILES" ]; then
  echo "No Swift sources found." >&2
  exit 1
fi

# shellcheck disable=SC2086
xcrun swiftc -typecheck \
  -sdk "$SDK" \
  -target arm64-apple-ios26.0-simulator \
  -swift-version 5 \
  $FILES

echo "typecheck: OK ($(echo "$FILES" | wc -l | tr -d ' ') files)"
