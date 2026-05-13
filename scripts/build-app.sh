#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build/release"
APP_DIR="$ROOT/build/MagicSwitch.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

cd "$ROOT"
swift build -c release

rm -rf "$APP_DIR"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BUILD_DIR/MagicSwitch" "$MACOS/MagicSwitch"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
cp "$ROOT/Resources/MagicSwitch.entitlements" "$RESOURCES/MagicSwitch.entitlements"
cp "$ROOT/Resources/MagicSwitch.icns" "$RESOURCES/MagicSwitch.icns"

codesign --force --deep --sign - --entitlements "$ROOT/Resources/MagicSwitch.entitlements" "$APP_DIR"

echo "$APP_DIR"
