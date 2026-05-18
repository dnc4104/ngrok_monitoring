#!/bin/bash
set -euo pipefail

# Build, sign, notarize, staple, and zip NgrokMonitor for distribution.
#
# Required environment:
#   CODESIGN_IDENTITY   "Developer ID Application: <Name> (TEAMID)"
#   NOTARY_PROFILE      Keychain profile created with
#                       `xcrun notarytool store-credentials`
#
# Output: dist/NgrokMonitor-<version>.zip

if [ -z "${CODESIGN_IDENTITY:-}" ]; then
    echo "❌ CODESIGN_IDENTITY is not set."
    echo "   Example: export CODESIGN_IDENTITY=\"Developer ID Application: David Nguyen (TEAMID)\""
    exit 1
fi
if [ -z "${NOTARY_PROFILE:-}" ]; then
    echo "❌ NOTARY_PROFILE is not set. Create one with:"
    echo "   xcrun notarytool store-credentials <profile-name> --apple-id ... --team-id ... --password ..."
    exit 1
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Sources/NgrokMonitor/Resources/bundle.plist)
echo "📦 Releasing NgrokMonitor $VERSION"

DIST_DIR="dist"
APP_DIR="$DIST_DIR/NgrokMonitor.app"
ZIP_PATH="$DIST_DIR/NgrokMonitor-$VERSION.zip"

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

# Build and sign.
NGROK_MONITOR_APP_DIR="$APP_DIR" CODESIGN_IDENTITY="$CODESIGN_IDENTITY" ./build.sh

# Notarize.
echo "📤 Submitting for notarization (this can take a few minutes)..."
NOTARY_ZIP="$DIST_DIR/NgrokMonitor-notary-input.zip"
ditto -c -k --keepParent "$APP_DIR" "$NOTARY_ZIP"
xcrun notarytool submit "$NOTARY_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$NOTARY_ZIP"

# Staple.
echo "📎 Stapling..."
xcrun stapler staple "$APP_DIR"

# Verify.
echo "🔍 Verifying..."
spctl --assess -vvv --type execute "$APP_DIR"

# Final distributable zip.
ditto -c -k --keepParent "$APP_DIR" "$ZIP_PATH"
SHA=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')

echo ""
echo "✅ Release ready: $ZIP_PATH"
echo "   SHA256: $SHA"
echo ""
echo "Next steps:"
echo "   git tag v$VERSION && git push origin v$VERSION"
echo "   Create a GitHub Release for v$VERSION and attach $ZIP_PATH"
