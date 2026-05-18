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

# SwiftPM-generated resource bundle has to sit next to the executable so Bundle.module resolves.
RESOURCE_BUNDLE=".build/release/NgrokMonitor_NgrokMonitor.bundle"
if [ -d "$RESOURCE_BUNDLE" ]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_DIR/Contents/MacOS/"
fi

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
    echo "🔏 Codesigning with: $CODESIGN_IDENTITY"
    codesign --deep --force --options runtime \
        --entitlements NgrokMonitor.entitlements \
        --sign "$CODESIGN_IDENTITY" \
        "$APP_DIR"
    codesign -dv --verbose=2 "$APP_DIR" 2>&1 | head -10
fi

echo "✅ NgrokMonitor built at $APP_DIR"
if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "ℹ️  Unsigned build. First launch may require:"
    echo "   xattr -dr com.apple.quarantine \"$APP_DIR\""
fi
