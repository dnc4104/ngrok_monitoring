#!/bin/bash
set -euo pipefail

# Build an unsigned NgrokMonitor.app for local development.
#
# Environment overrides:
#   NGROK_MONITOR_APP_DIR   Output .app path (default: ~/Applications/NgrokMonitor.app)
#   CODESIGN_IDENTITY       If set, codesign the bundle with this identity.
#                           Example: "Developer ID Application: David Nguyen (TEAMID)"
#
# For release builds (signed + notarized + zipped), use ./scripts/release.sh.

echo "🔨 Building NgrokMonitor..."

swift build -c release

BINARY=".build/release/NgrokMonitor"
if [ ! -f "$BINARY" ]; then
    echo "❌ Build failed - binary not found"
    exit 1
fi

APP_DIR="${NGROK_MONITOR_APP_DIR:-$HOME/Applications/NgrokMonitor.app}"
mkdir -p "$(dirname "$APP_DIR")"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/NgrokMonitor"

# Copy PNG resources directly into Contents/Resources/ (canonical macOS .app layout).
# We deliberately do NOT embed SwiftPM's .build/release/NgrokMonitor_NgrokMonitor.bundle:
# it's a flat directory with no Contents/Info.plist, so `codesign --deep` rejects it as
# an unsuitable bundle. The loader code falls back through Bundle.main → Bundle.module
# so both `./build.sh` and `swift run` workflows resolve resources correctly.
cp Sources/NgrokMonitor/Resources/ngrok-black.png "$APP_DIR/Contents/Resources/"
cp Sources/NgrokMonitor/Resources/ngrok-green.png "$APP_DIR/Contents/Resources/"

cp Sources/NgrokMonitor/Resources/bundle.plist "$APP_DIR/Contents/Info.plist"

# Generate AppIcon.icns from the green ngrok logo.
SRC_ICON="Sources/NgrokMonitor/Resources/ngrok-green.png"
ICONSET_PARENT=$(mktemp -d)
ICONSET="$ICONSET_PARENT/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
    size=${spec%% *}
    name=${spec#* }
    sips -z "$size" "$size" "$SRC_ICON" --out "$ICONSET/icon_$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_DIR/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET_PARENT"

if [ -n "${CODESIGN_IDENTITY:-}" ]; then
    # Strip macOS metadata that codesign rejects ("resource fork, Finder information,
    # or similar detritus not allowed"). Sources include Finder tags on source files,
    # quarantine xattrs from downloaded assets, and stray .DS_Store files.
    find "$APP_DIR" -name '.DS_Store' -delete
    xattr -cr "$APP_DIR"

    echo "🔏 Codesigning with: $CODESIGN_IDENTITY"
    codesign --deep --force --options runtime \
        --entitlements NgrokMonitor.entitlements \
        --sign "$CODESIGN_IDENTITY" \
        --timestamp \
        "$APP_DIR"
    codesign -dv --verbose=2 "$APP_DIR" 2>&1 | head -10
fi

echo "✅ NgrokMonitor built at $APP_DIR"
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "ℹ️  Unsigned build. First launch may require:"
    echo "   xattr -dr com.apple.quarantine \"$APP_DIR\""
fi
