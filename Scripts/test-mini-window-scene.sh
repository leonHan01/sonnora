#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${SONORA_BUILD_ROOT:-$PROJECT/.build}"
TEST_ROOT="$BUILD_ROOT/mini-window-tests"
TEST_APP="$TEST_ROOT/SceneTest.app"
mkdir -p "$BUILD_ROOT/module-cache" "$TEST_APP/Contents/MacOS"

sed '/^@main$/d' "$PROJECT/Sources/Sonora/SonoraApp.swift" > "$TEST_ROOT/SonoraAppForTest.swift"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>studio.sonora.test.mini-window</string>
<key>CFBundleName</key><string>Sonora Mini Window Check</string>
<key>CFBundleExecutable</key><string>SceneTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST

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
    "$PROJECT/Tests/SonoraTests/MiniWindowSceneTests.swift" \
    -o "$TEST_APP/Contents/MacOS/SceneTest"
"$TEST_APP/Contents/MacOS/SceneTest"
