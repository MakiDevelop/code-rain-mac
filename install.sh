#!/usr/bin/env bash
# Build → bundle → install to ~/Applications → register as Login Item → launch
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CodeRain"
BUNDLE_ID="tw.chiba.CodeRain"
INSTALL_DIR="$HOME/Applications"
APP_PATH="${INSTALL_DIR}/${APP_NAME}.app"
BUILD_OUT=".build/release/${APP_NAME}"

echo "▶ 1/5  Building release binary..."
swift build -c release

echo "▶ 2/5  Assembling ${APP_NAME}.app bundle..."
STAGE="build/${APP_NAME}.app"
rm -rf "$STAGE"
mkdir -p "$STAGE/Contents/MacOS"
cp "$BUILD_OUT" "$STAGE/Contents/MacOS/${APP_NAME}"

cat > "$STAGE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>         <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>         <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>               <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>0.1</string>
    <key>CFBundleVersion</key>            <string>1</string>
    <key>LSMinimumSystemVersion</key>     <string>13.0</string>
    <key>LSUIElement</key>                <true/>
    <key>NSHighResolutionCapable</key>    <true/>
</dict>
</plist>
PLIST

echo "▶ 3/5  Installing to ${APP_PATH}..."
mkdir -p "$INSTALL_DIR"
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "$APP_PATH"
cp -R "$STAGE" "$APP_PATH"

echo "▶ 4/5  Registering Login Item..."
osascript -e "tell application \"System Events\" to delete (every login item whose path is \"${APP_PATH}\")" 2>/dev/null || true
osascript -e "tell application \"System Events\" to make login item at end with properties {path:\"${APP_PATH}\", hidden:true}" >/dev/null

echo "▶ 5/5  Launching..."
open "$APP_PATH"

echo ""
echo "✅ Done."
echo "   App:          $APP_PATH"
echo "   Hotkey:       ⌃⌥⌘M"
echo "   Menu bar:     look for ⣿"
echo "   Auto-start:   registered (System Settings → General → Login Items to verify / remove)"
