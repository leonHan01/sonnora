#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="${SONORA_BUILD_ROOT:-$PROJECT/.build}"
ARCH="${1:-$(uname -m)}"
case "$ARCH" in arm64|x86_64) ;; *) echo '架构需为 arm64 或 x86_64' >&2; exit 1 ;; esac

mkdir -p "$BUILD_ROOT/module-cache" "$PROJECT/dist"
export CLANG_MODULE_CACHE_PATH="$BUILD_ROOT/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_ROOT/module-cache"
SWIFT_ARGS=(--package-path "$PROJECT" --scratch-path "$BUILD_ROOT" --cache-path "$BUILD_ROOT/cache" --config-path "$BUILD_ROOT/config" --security-path "$BUILD_ROOT/security" --disable-sandbox --build-system native --arch "$ARCH" -c release)

swift build "${SWIFT_ARGS[@]}" -j 4
BIN_DIR="$(swift build "${SWIFT_ARGS[@]}" --show-bin-path)"
APP="${SONORA_APP_OUTPUT:-$PROJECT/dist/声屿.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Sonora" "$APP/Contents/MacOS/Sonora"
cp "$PROJECT/Resources/Info.plist" "$APP/Contents/Info.plist"
swift -module-cache-path "$BUILD_ROOT/module-cache" "$PROJECT/Scripts/make-icon.swift" "$BUILD_ROOT/AppIcon.iconset"
cp "$BUILD_ROOT/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "已构建：$APP ($ARCH)"
bash "$PROJECT/Scripts/package-dmg.sh" "$APP"
