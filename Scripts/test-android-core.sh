#!/bin/bash
set -euo pipefail
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="$PROJECT/.android-build/core-tests"
mkdir -p "$OUTPUT"
javac -encoding UTF-8 -d "$OUTPUT" "$PROJECT/android/app/src/main/java/studio/sonora/android/Core.java" "$PROJECT/android/core-tests/CoreTests.java"
java -cp "$OUTPUT" studio.sonora.android.CoreTests
