#!/bin/bash
# Builds Zapper.app. Swift Package Manager produces a bare executable, so the
# bundle is assembled by hand here.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Zapper.app"
BUNDLE_ID="com.kamenlevi.zapper"
VERSION="1.0"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" --product ZapperApp
swift build -c "$CONFIG" --product zapperctl

BIN=".build/$CONFIG/ZapperApp"
CTL=".build/$CONFIG/zapperctl"

echo "▸ Assembling bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Zapper"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Zapper</string>
    <key>CFBundleDisplayName</key><string>Zapper</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>Zapper</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>

    <!-- Menu bar only: no Dock tile. -->
    <key>LSUIElement</key><true/>

    <!-- macOS gates LAN access; without these the TV is invisible. -->
    <key>NSLocalNetworkUsageDescription</key>
    <string>Zapper finds and controls TVs on your local network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_airplay._tcp</string>
    </array>
</dict>
</plist>
PLIST

if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "▸ Signing…"
# Ad-hoc signature, but stable-identified: macOS ties the Local Network
# permission to the bundle id, so the grant survives rebuilds.
codesign --force --sign - --identifier "$BUNDLE_ID" "$APP" >/dev/null 2>&1

echo "▸ Built $APP"
echo "  CLI: $CTL"
