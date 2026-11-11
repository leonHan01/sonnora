#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${SONORA_BUILD_ROOT:-$PROJECT/.build}"
mkdir -p "$BUILD_ROOT/module-cache"
SOURCES=()
for source in "$PROJECT"/Sources/Sonora/*.swift; do
    if [[ "$source" != */SonoraApp.swift ]]; then SOURCES+=("$source"); fi
done
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$BUILD_ROOT/module-cache" \
    "${SOURCES[@]}" "$PROJECT/Tests/SonoraTests/RenderingContractTests.swift" \
    -o "$BUILD_ROOT/SonoraRenderingContractTests"
"$BUILD_ROOT/SonoraRenderingContractTests"
