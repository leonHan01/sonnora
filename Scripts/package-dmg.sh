#!/bin/bash
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:-${SONORA_APP_OUTPUT:-$PROJECT/dist/声屿.app}}"
APP="$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")"
DIST="$(dirname "$APP")"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,3}([-\.][A-Za-z0-9]+)*$ ]] || { echo '应用版本号无效' >&2; exit 1; }
codesign --verify --deep --strict "$APP"

STAGING="$(mktemp -d "$DIST/.sonora-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/payload"
cp -R "$APP" "$STAGING/payload/"
ln -s /Applications "$STAGING/payload/Applications"
hdiutil create -volname '声屿 · Sonora' -srcfolder "$STAGING/payload" -format UDZO "$STAGING/package.dmg"
hdiutil verify "$STAGING/package.dmg"

# Replace the installer only after the new image has been verified.
TARGET="$DIST/声屿-Sonora-$VERSION.dmg"
mv -f "$STAGING/package.dmg" "$TARGET"
shopt -s nullglob
for image in "$DIST"/声屿-Sonora-*.dmg; do
    [[ "$image" == "$TARGET" ]] || rm -f "$image"
done

# Old releases left empty version folders with Finder metadata behind.
# Leave any directory containing other files untouched.
for directory in "$DIST"/*; do
    [[ -d "$directory" && ! -L "$directory" ]] || continue
    [[ "$(basename "$directory")" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
    if [[ -z "$(find "$directory" -mindepth 1 ! -name .DS_Store -print -quit)" ]]; then
        rm -f "$directory/.DS_Store"
        rmdir "$directory"
    fi
done
echo "已打包：${TARGET}（仅保留最新 DMG）"
