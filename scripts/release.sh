#!/bin/bash
# Builds the app, zips it, signs the zip for Sparkle and adds it to appcast.xml.
# Needs the Sparkle private key in this Mac's keychain, created once with generate_keys (README → Updates).
set -euo pipefail
cd "$(dirname "$0")/.."
PLIST=Resources/Info.plist
read_plist() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null; }
read_plist SUPublicEDKey >/dev/null || { echo "Add SUPublicEDKey to $PLIST first (README → Updates)." >&2; exit 1; }
VERSION="$(read_plist CFBundleShortVersionString)"
BUILD="$(read_plist CFBundleVersion)"
MINIMUM="$(read_plist LSMinimumSystemVersion)"
if grep -q "<sparkle:version>$BUILD</sparkle:version>" appcast.xml; then
    echo "appcast.xml already has build $BUILD. Raise CFBundleVersion (and CFBundleShortVersionString) in $PLIST first." >&2; exit 1
fi

bash scripts/build-app.sh
SIGN_UPDATE="$(find .build/artifacts -type f -name sign_update -path '*/bin/*' | head -1)"
[ -n "$SIGN_UPDATE" ] || { echo "Sparkle's sign_update wasn't found under .build/artifacts." >&2; exit 1; }
ZIP="dist/OpenStill-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent dist/OpenStill.app "$ZIP"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SIGN_UPDATE" "$ZIP")"
# The build is for this Mac's architecture only; keep Intel Macs from being offered an Apple silicon build.
ARCHS="$(lipo -archs dist/OpenStill.app/Contents/MacOS/OpenStill)"

VERSION="$VERSION" BUILD="$BUILD" MINIMUM="$MINIMUM" SIGNATURE="$SIGNATURE" ARCHS="$ARCHS" python3 scripts/appcast-add.py

cat <<EOF
Next:
  1. Create the GitHub release v$VERSION and attach $ZIP.
  2. Commit appcast.xml and push it to main. Apps pick up the update from there.
EOF
