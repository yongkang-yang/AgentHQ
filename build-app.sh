#!/bin/bash
# Build AgentHQ.app — a menu-bar-only bundle.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="AgentHQ"
APP_DIR="${APP_NAME}.app"
VERSION="0.1.0"

echo "==> Building release binary"
swift build -c release --product AgentHQApp

BINARY="$(find .build -name AgentHQApp -type f -perm +111 2>/dev/null | grep -v dSYM | head -1)"
[ -n "$BINARY" ] || { echo "could not find the built AgentHQApp binary" >&2; exit 1; }

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY" "$APP_DIR/Contents/MacOS/$APP_NAME"

# The icon. LSUIElement means no Dock icon, but this is still what Finder,
# notifications, the About panel and the disk image show.
cp Resources/AgentHQ.icns "$APP_DIR/Contents/Resources/AgentHQ.icns"

cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>dev.yongkang.agenthq</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AgentHQ</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon, no app switcher entry. -->
    <key>LSUIElement</key><true/>
    <key>NSHumanReadableCopyright</key><string>GPL-3.0</string>
</dict>
</plist>
PLIST

echo "==> Signing"
# A Developer ID if one is available, ad-hoc otherwise. Ad-hoc is fine on the
# machine that built it; Gatekeeper will object on any other Mac.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)"/\1/' || true)"
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP_DIR"
    echo "    signed with: $IDENTITY"
else
    codesign --force --sign - "$APP_DIR"
    echo "    ad-hoc signed (no Developer ID found)"
fi

echo
echo "Built $APP_DIR"
echo "  run:  open $APP_DIR"
echo "  quit: osascript -e 'quit app \"$APP_NAME\"'  (or the panel's Quit item)"
