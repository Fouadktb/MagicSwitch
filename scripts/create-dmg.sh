#!/bin/zsh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${1:-0.1.7}"
APP_DIR="$ROOT/build/MagicSwitch.app"
DIST_DIR="$ROOT/dist"
STAGING_DIR="$ROOT/build/dmg-staging"
RW_DMG="$ROOT/build/MagicSwitch-v$VERSION-rw.dmg"
DMG_PATH="$DIST_DIR/MagicSwitch-v$VERSION.dmg"
VOLUME_NAME="MagicSwitch"
MOUNT_DIR="/Volumes/$VOLUME_NAME"
BACKGROUND_NAME="dmg-background.png"

if [ ! -d "$APP_DIR" ]; then
  "$ROOT/scripts/build-app.sh" >/dev/null
fi

"$ROOT/scripts/render-dmg-background.sh" >/dev/null

if mount | grep -q "on $MOUNT_DIR "; then
  hdiutil detach "$MOUNT_DIR" -quiet || true
fi

rm -rf "$STAGING_DIR" "$RW_DMG" "$DMG_PATH"
mkdir -p "$STAGING_DIR/.background" "$DIST_DIR"

ditto "$APP_DIR" "$STAGING_DIR/MagicSwitch.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$ROOT/build/$BACKGROUND_NAME" "$STAGING_DIR/.background/$BACKGROUND_NAME"

hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDRW \
  "$RW_DMG" >/dev/null

cleanup() {
  if mount | grep -q "on $MOUNT_DIR "; then
    hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
}
trap cleanup EXIT

hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen -mountpoint "$MOUNT_DIR" >/dev/null

osascript <<APPLESCRIPT
set volumeFolder to POSIX file "$MOUNT_DIR" as alias
tell application "Finder"
  repeat 30 times
    if exists folder volumeFolder then exit repeat
    delay 0.2
  end repeat
  tell folder volumeFolder
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {100, 100, 820, 540}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set background picture of viewOptions to file ".background:$BACKGROUND_NAME"
    set position of item "MagicSwitch.app" of container window to {170, 225}
    set position of item "Applications" of container window to {558, 225}
    close
    open
    update without registering applications
    delay 1
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" -quiet

hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null
rm -rf "$RW_DMG" "$STAGING_DIR"

echo "$DMG_PATH"
