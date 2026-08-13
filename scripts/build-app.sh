#!/bin/sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "Building release binary..."
swift build -c release

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$ROOT/dist/vt-reborn.app"

echo "Assembling $APP..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN_DIR/VTPuncher" "$APP/Contents/MacOS/vt-reborn"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>vt-reborn</string>
	<key>CFBundleDisplayName</key>
	<string>vt-reborn</string>
	<key>CFBundleIdentifier</key>
	<string>local.vt-reborn.app</string>
	<key>CFBundleExecutable</key>
	<string>vt-reborn</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
	<key>NSHighResolutionCapable</key>
	<true/>
</dict>
</plist>
PLIST

echo "Signing (ad-hoc)..."
codesign --force --deep --sign - "$APP"

echo ""
echo "Done: $APP"
echo "Open with: open \"$APP\""
