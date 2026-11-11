#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${SONORA_BUILD_ROOT:-$PROJECT/.build}"
mkdir -p "$BUILD_ROOT/module-cache"
swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$BUILD_ROOT/module-cache" \
    "$PROJECT/Sources/Sonora/Models.swift" \
    "$PROJECT/Sources/Sonora/TrackImporter.swift" \
    "$PROJECT/Sources/Sonora/Design.swift" \
    "$PROJECT/Sources/Sonora/PlayerModel.swift" \
    "$PROJECT/Tests/SonoraTests/PagePerformanceTests.swift" \
    -o "$BUILD_ROOT/SonoraPagePerformanceTests"
"$BUILD_ROOT/SonoraPagePerformanceTests"
