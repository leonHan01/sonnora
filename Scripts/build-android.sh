#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_ROOT="$PROJECT/.android-build"
mkdir -p "$BUILD_ROOT/keys" "$PROJECT/dist"
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK" ]]; then
    for candidate in "$HOME/Library/Android/sdk" /opt/homebrew/share/android-commandlinetools; do
        if [[ -f "$candidate/platforms/android-35/android.jar" ]]; then SDK="$candidate"; break; fi
    done
fi
[[ -n "$SDK" && -f "$SDK/platforms/android-35/android.jar" ]] || { echo '请安装 Android SDK Platform 35 和 Build Tools 35.0.0，并设置 ANDROID_HOME。' >&2; exit 1; }
export ANDROID_HOME="$SDK"
if [[ -z "${JAVA_HOME:-}" && -x /usr/libexec/java_home ]]; then export JAVA_HOME="$(/usr/libexec/java_home -v 17)"; fi
GRADLE="${SONORA_GRADLE_BIN:-}"
if [[ -z "$GRADLE" && -x "$PROJECT/android/gradlew" ]]; then GRADLE="$PROJECT/android/gradlew"; fi
if [[ -z "$GRADLE" ]]; then
    GRADLE="$(command -v gradle || true)"
    if [[ -z "$GRADLE" && -d "$HOME/.gradle/wrapper/dists" ]]; then
        GRADLE="$(find "$HOME/.gradle/wrapper/dists/gradle-8.11.1-all" -type f -path '*/bin/gradle' -print -quit 2>/dev/null || true)"
    fi
fi
if [[ -z "$GRADLE" && -x "$PROJECT/android/gradlew" ]]; then GRADLE="$PROJECT/android/gradlew"; fi
[[ -n "$GRADLE" ]] || { echo '请安装 Gradle 8.11.1，或设置 SONORA_GRADLE_BIN。' >&2; exit 1; }
if [[ ! -f "$BUILD_ROOT/keys/sonora.jks" ]]; then
    keytool -genkeypair -keystore "$BUILD_ROOT/keys/sonora.jks" -storepass android -keypass android -alias sonora \
        -keyalg RSA -keysize 3072 -validity 10000 -dname 'CN=Sonora Local, O=Sonora, C=CN' -noprompt
    chmod 600 "$BUILD_ROOT/keys/sonora.jks"
fi
"$GRADLE" -p "$PROJECT/android" --no-daemon --max-workers=2 "${@}" assembleRelease lintRelease
APK="$PROJECT/android/app/build/outputs/apk/release/app-release.apk"
"$SDK/build-tools/35.0.0/apksigner" verify --verbose "$APK"
VERSION="$("$SDK/build-tools/35.0.0/aapt" dump badging "$APK" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p" | head -1)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'APK 版本无效' >&2; exit 1; }
OUTPUT="$PROJECT/dist/声屿-Sonora-Android-$VERSION.apk"
cp "$APK" "$OUTPUT"
shopt -s nullglob
for old in "$PROJECT"/dist/声屿-Sonora-Android-*.apk; do [[ "$old" == "$OUTPUT" ]] || rm -f "$old"; done
echo "已构建并校验：$OUTPUT"
