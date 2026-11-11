#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${SONORA_BUILD_ROOT:-$PROJECT/.build}"
TEST_ROOT="$BUILD_ROOT/mini-window-tests"
mkdir -p "$BUILD_ROOT/module-cache" "$TEST_ROOT"

# Keep the production RootView and window coordinator in the test binary;
# only remove the application entry point so the test runner can supply one.
sed '/^@main$/d' "$PROJECT/Sources/Sonora/SonoraApp.swift" > "$TEST_ROOT/SonoraAppForTest.swift"
swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macosx14.0" \
    -module-cache-path "$BUILD_ROOT/module-cache" \
    "$PROJECT/Sources/Sonora/Models.swift" \
    "$PROJECT/Sources/Sonora/TrackImporter.swift" \
    "$PROJECT/Sources/Sonora/Design.swift" \
    "$PROJECT/Sources/Sonora/PlayerModel.swift" \
    "$PROJECT/Sources/Sonora/PlaylistAddMenu.swift" \
    "$PROJECT/Sources/Sonora/LibraryView.swift" \
    "$PROJECT/Sources/Sonora/ArtistsView.swift" \
    "$PROJECT/Sources/Sonora/Sidebar.swift" \
    "$PROJECT/Sources/Sonora/PlaybackViews.swift" \
    "$PROJECT/Sources/Sonora/PlayerWindowPresentation.swift" \
    "$TEST_ROOT/SonoraAppForTest.swift" \
    "$PROJECT/Tests/SonoraTests/MiniWindowTests.swift" \
    -o "$TEST_ROOT/MiniWindowTests"
"$TEST_ROOT/MiniWindowTests"
