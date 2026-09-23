#!/bin/bash
# Build AgentHQ.app — a menu-bar-only bundle.
set -euo pipefail

cd "$(dirname "$0")"

# By default the build is installed over /Applications/AgentHQ.app, because
# that is the copy the user launches: a bundle left only in the repo meant the
# running app silently stayed older than every fix. --no-install skips it.
INSTALL=1
for arg in "$@"; do
    case "$arg" in
        --no-install) INSTALL=0 ;;
        *) echo "usage: $0 [--no-install]" >&2; exit 2 ;;
    esac
done

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
    <key>NSAppleEventsUsageDescription</key><string>Reveal brings the selected herdr conversation to the front in Ghostty.</string>
</dict>
</plist>
PLIST

echo "==> Signing"
# A Developer ID if one is available, then an Apple Development certificate,
# ad-hoc otherwise. Ad-hoc is fine on the machine that built it, but its
# signature changes every build, so macOS privacy grants reset each time;
# Gatekeeper will object to anything but Developer ID on any other Mac.
# Apple Development is matched by SHA-1 hash because two certificates with
# the same common name make codesign refuse an ambiguous match.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)"/\1/' || true)"
DEV_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk '/Apple Development/ {print $2; exit}' || true)"
if [ -n "$IDENTITY" ]; then
    codesign --force --options runtime --timestamp \
        --entitlements Resources/AgentHQ.entitlements --sign "$IDENTITY" "$APP_DIR"
    echo "    signed with: $IDENTITY"
elif [ -n "$DEV_IDENTITY" ]; then
    codesign --force --options runtime \
        --entitlements Resources/AgentHQ.entitlements --sign "$DEV_IDENTITY" "$APP_DIR"
    echo "    signed with Apple Development: $DEV_IDENTITY"
else
    codesign --force --entitlements Resources/AgentHQ.entitlements --sign - "$APP_DIR"
    echo "    ad-hoc signed (no Developer ID found)"
fi

echo
echo "Built $APP_DIR"

if [ "$INSTALL" = 0 ]; then
    echo "  run:  open $APP_DIR"
    echo "  quit: osascript -e 'quit app \"$APP_NAME\"'  (or the panel's Quit item)"
    exit 0
fi

INSTALL_DIR="/Applications/$APP_DIR"
echo "==> Installing to $INSTALL_DIR"

# Only one copy may run: TunnelReaper in the one starting up tears down the
# other's tunnels. So quit whichever copy is running, wait for it to exit,
# and relaunch the installed one only if something was running before.
WAS_RUNNING=0
if pgrep -xq "$APP_NAME"; then
    WAS_RUNNING=1
    osascript -e "quit app id \"dev.yongkang.agenthq\"" >/dev/null 2>&1 || true
    for _ in $(seq 50); do
        pgrep -xq "$APP_NAME" || break
        sleep 0.1
    done
    pgrep -xq "$APP_NAME" && { echo "$APP_NAME did not quit; not installing" >&2; exit 1; }
fi

rm -rf "$INSTALL_DIR"
ditto "$APP_DIR" "$INSTALL_DIR"
echo "    installed $INSTALL_DIR"

if [ "$WAS_RUNNING" = 1 ]; then
    open "$INSTALL_DIR"
    echo "    relaunched"
else
    echo "  run:  open $INSTALL_DIR"
fi
