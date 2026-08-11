#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

DIST=$(pwd)/dist
"$DIST/bin/coder-bar-ctl" deconfigure
osascript -e 'tell application "CoderBar" to quit' >/dev/null 2>&1 || true
pkill -f "CoderBar.app/Contents/MacOS/coder-bar" >/dev/null 2>&1 || true
echo "Hooks removed. App stopped. Original configs backed up as *.coderbar.bak."