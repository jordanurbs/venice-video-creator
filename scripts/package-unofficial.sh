#!/bin/bash
set -euo pipefail

# Usage: scripts/package-unofficial.sh
#
# Builds an ad-hoc signed "Venice Video Creator.app" (no Developer ID, no
# notarization) and packs it into dist/VeniceVideoCreator-<version>-unsigned.zip.
# Users install by unzipping and right-click → Open to bypass Gatekeeper.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PLIST="$ROOT/Sources/VeniceVideoCreator/Resources/Info.plist"
DIST="$ROOT/dist"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$PLIST")"
APP="$ROOT/.build/Venice Video Creator.app"
ZIP="$DIST/VeniceVideoCreator-$VERSION+b$BUILD-unsigned.zip"

"$ROOT/scripts/bundle.sh" release

mkdir -p "$DIST"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"

echo ""
echo "==> Done: $ZIP"
echo "    Unofficial build — ad-hoc signed, not notarized."
echo "    Install: unzip, right-click the app → Open → Open."
