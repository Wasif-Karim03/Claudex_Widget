#!/usr/bin/env bash
# Builds Claudex in release mode and wraps it in an ad-hoc signed build/Claudex.app.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Claudex.app"
rm -rf "$APP"

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Claudex" "$APP/Contents/MacOS/Claudex"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.wasifkarim.claudex</string>
    <key>CFBundleName</key>
    <string>Claudex</string>
    <key>CFBundleDisplayName</key>
    <string>Claudex</string>
    <key>CFBundleExecutable</key>
    <string>Claudex</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "Built $APP"
