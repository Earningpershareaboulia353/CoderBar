#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=0.5.5
swift build -c release

DIST=dist
rm -rf "$DIST"
mkdir -p "$DIST/CoderBar.app/Contents/MacOS" \
         "$DIST/CoderBar.app/Contents/Resources" \
         "$DIST/CoderBar.app/Contents/Library/LaunchServices" \
         "$DIST/bin"

BIN=.build/release
cp "$BIN/coder-bar" "$DIST/CoderBar.app/Contents/MacOS/"
cp "$BIN/coder-bar-hook" "$BIN/coder-bar-ctl" "$DIST/CoderBar.app/Contents/MacOS/"
mkdir -p "$DIST/bin"
cp "$BIN/coder-bar-hook" "$BIN/coder-bar-ctl" "$DIST/bin/"

# app icon
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
rm -rf /tmp/coderbaricon-$$ && swift "$SCRIPT_DIR/IconGen.swift" /tmp/coderbaricon-$$.iconset >/dev/null
iconutil -c icns "/tmp/coderbaricon-$$.iconset" -o "$DIST/CoderBar.app/Contents/Resources/AppIcon.icns"
rm -rf "/tmp/coderbaricon-$$.iconset"

cat > "$DIST/CoderBar.app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key>
	<string>coder-bar</string>
	<key>CFBundleIdentifier</key>
	<string>dev.coderbar.app</string>
	<key>CFBundleName</key>
	<string>CoderBar</string>
	<key>CFBundleDisplayName</key>
	<string>CoderBar</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>LSUIElement</key>
	<true/>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSAppleEventsUsageDescription</key>
	<string>CoderBar brings your terminal to the front when you click a session or notification.</string>
	<key>NSUserNotificationUsageDescription</key>
	<string>CoderBar shows notifications when an agent needs your attention.</string>
</dict>
</plist>
PLIST

codesign --force --sign - --entitlements "$SCRIPT_DIR/Entitlements.plist" \
    "$DIST/CoderBar.app"
codesign -dv "$DIST/CoderBar.app" 2>&1 | grep -E "Signature|Identifier|Runtime" || true

echo
echo "Built: $DIST/CoderBar.app  (v$VERSION)"
echo "Hooks/ctl also inside: Contents/MacOS/coder-bar-hook"
echo
echo "Next:"
echo "  open $DIST/CoderBar.app"
echo "  $DIST/bin/coder-bar-ctl configure"
