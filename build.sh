#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="Headroom"
APP_BUNDLE="$SCRIPT_DIR/$APP_NAME.app"
BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
DMG="$SCRIPT_DIR/$APP_NAME.dmg"

rm -rf "$APP_BUNDLE" "$DMG"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# --- Icon ---
echo "Generating icon..."
ICONSET="$SCRIPT_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
swift "$SCRIPT_DIR/generate_icon.swift" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

# --- Compile ---
echo "Compiling for arm64..."
swiftc "$SCRIPT_DIR/Headroom.swift" -swift-version 5 -framework Cocoa -framework UserNotifications \
    -target arm64-apple-macosx11.0 -o /tmp/${APP_NAME}_arm64

echo "Compiling for x86_64..."
swiftc "$SCRIPT_DIR/Headroom.swift" -swift-version 5 -framework Cocoa -framework UserNotifications \
    -target x86_64-apple-macosx11.0 -o /tmp/${APP_NAME}_x86_64

echo "Creating universal binary..."
lipo -create /tmp/${APP_NAME}_arm64 /tmp/${APP_NAME}_x86_64 -output "$BINARY"
rm /tmp/${APP_NAME}_arm64 /tmp/${APP_NAME}_x86_64

# --- Swift stdlib ---
echo "Embedding Swift libraries..."
xcrun swift-stdlib-tool --copy --scan-executable "$BINARY" \
    --destination "$APP_BUNDLE/Contents/Frameworks" --platform macosx
install_name_tool -add_rpath @executable_path/../Frameworks "$BINARY"

cp "$SCRIPT_DIR/Info.plist" "$APP_BUNDLE/Contents/"

# --- DMG ---
echo "Creating DMG..."
RW_DMG="/tmp/${APP_NAME}_rw_$$.dmg"
TEMP_VOL="HeadroomBuild$$"
rm -f "$RW_DMG" "$DMG"

hdiutil create -size 60m -volname "$TEMP_VOL" -fs HFS+ -o "$RW_DMG" > /dev/null
MOUNT_DIR=$(hdiutil attach "$RW_DMG" | awk '/Volumes/{print substr($0, index($0, "/Volumes"))}')

ditto "$APP_BUNDLE" "$MOUNT_DIR/$APP_NAME.app"
ln -s /Applications "$MOUNT_DIR/Applications"

osascript << APPLESCRIPT
tell application "Finder"
  tell disk "$TEMP_VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 150, 760, 420}
    set icon size of icon view options of container window to 120
    set arrangement of icon view options of container window to not arranged
    set position of item "Headroom.app" of container window to {160, 140}
    set position of item "Applications" of container window to {400, 140}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

sync
hdiutil detach "$MOUNT_DIR" > /dev/null
hdiutil convert "$RW_DMG" -format UDZO -o "$DMG" > /dev/null
rm -f "$RW_DMG"

echo ""
echo "Done!"
echo "  App:  $APP_BUNDLE"
echo "  DMG:  $DMG  ← share this"
open "$APP_BUNDLE"
