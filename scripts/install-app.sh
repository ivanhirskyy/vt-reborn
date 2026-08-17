#!/bin/sh
# Builds vt-reborn.app and installs/updates it in /Applications, pinned to the Dock.
# Safe to re-run any time you want to pick up new changes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP_NAME="vt-reborn.app"
mkdir -p "$HOME/Applications"
DEST="$HOME/Applications/$APP_NAME"
OLD_DEST="/Applications/VTPuncher.app"

"$ROOT/scripts/build-app.sh"

echo "Stopping any running instance..."
pkill -f "$DEST/Contents/MacOS/vt-reborn" 2>/dev/null || true
pkill -f "$OLD_DEST/Contents/MacOS/VTPuncher" 2>/dev/null || true

if [ -d "$OLD_DEST" ] && rm -rf "$OLD_DEST" 2>/dev/null; then
	echo "Removed stale $OLD_DEST"
elif [ -d "$OLD_DEST" ]; then
	echo "Note: couldn't remove old $OLD_DEST (needs admin rights) — delete it manually via Finder if you like."
fi

echo "Installing to $DEST..."
rm -rf "$DEST"
cp -R "$ROOT/dist/$APP_NAME" "$DEST"

if ! defaults read com.apple.dock persistent-apps 2>/dev/null | grep -q "$DEST"; then
	echo "Pinning to Dock..."
	defaults write com.apple.dock persistent-apps -array-add "<dict><key>tile-data</key><dict><key>file-data</key><dict><key>_CFURLString</key><string>$DEST</string><key>_CFURLStringType</key><integer>0</integer></dict></dict></dict>"
	killall Dock 2>/dev/null || true
fi

echo "Launching..."
open "$DEST"

echo ""
echo "Done: $DEST"
