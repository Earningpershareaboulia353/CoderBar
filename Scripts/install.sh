#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."

DIST=$(pwd)/dist

if [ ! -x "$DIST/bin/coder-bar-ctl" ]; then
    echo "not built yet — run Scripts/build.sh first"
    exit 1
fi

# generate AppleScript automation permission description is in Info.plist;
# first run may prompt for notification permission.
open "$DIST/CoderBar.app"
sleep 1
"$DIST/bin/coder-bar-ctl" configure
echo
echo "Done. CoderBar is listening on 127.0.0.1:41734."
echo "Run a Claude Code / Codex / Gemini CLI session — events will appear in the menu bar."