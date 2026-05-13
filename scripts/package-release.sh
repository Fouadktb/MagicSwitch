#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.0}"
DIST_DIR="$ROOT/dist"
ZIP_PATH="$DIST_DIR/MagicSwitch-v$VERSION.zip"

"$ROOT/scripts/build-app.sh" >/dev/null

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

ditto -c -k --norsrc --keepParent "$ROOT/build/MagicSwitch.app" "$ZIP_PATH"

echo "$ZIP_PATH"
