#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
BUILD_OPTIONS=(
    --configuration release
    --cache-path "$PROJECT_DIR/.build/swiftpm-cache"
    --config-path "$PROJECT_DIR/.build/swiftpm-config"
    --security-path "$PROJECT_DIR/.build/swiftpm-security"
)
swift build "${BUILD_OPTIONS[@]}" "$@"
EXECUTABLE_DIR="$(swift build "${BUILD_OPTIONS[@]}" "$@" --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/WindowLane.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE_DIR/WindowLane" "$APP_DIR/Contents/MacOS/WindowLane"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod 755 "$APP_DIR/Contents/MacOS/WindowLane"

/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
/usr/bin/codesign --force --sign - --identifier com.feizhang.windowlane "$APP_DIR"
/usr/bin/codesign --verify --strict "$APP_DIR"
printf 'Built and signed: %s\n' "$APP_DIR"
