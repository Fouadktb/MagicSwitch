#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.8}"
DIST_DIR="$ROOT/dist"
ZIP_PATH="$DIST_DIR/MagicSwitch-v$VERSION.zip"
DMG_PATH="$DIST_DIR/MagicSwitch-v$VERSION.dmg"

"$ROOT/scripts/build-app.sh" >/dev/null

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto -c -k --norsrc --keepParent "$ROOT/build/MagicSwitch.app" "$ZIP_PATH"
"$ROOT/scripts/create-dmg.sh" "$VERSION" >/dev/null

echo "$ZIP_PATH"
echo "$DMG_PATH"
