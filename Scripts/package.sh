#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" \
    dist/CoderBar.app/Contents/Info.plist 2>/dev/null || echo "0.2.0")

ZIP="dist/CoderBar-$VERSION-macos.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent \
    "dist/CoderBar.app" \
    "dist/CoderBar-$VERSION-macos.zip"

echo "Created: $ZIP"
ls -lh "$ZIP"