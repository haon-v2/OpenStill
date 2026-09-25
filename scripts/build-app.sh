#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PKG_CONFIG_PATH="$PWD/.build/native/lib/pkgconfig"
if [ ! -f .build/native/lib/liblcms2.dylib ] || [ ! -f .build/native/lib/liblensfun.dylib ]; then bash scripts/build-native.sh; fi

if [ ! -f .build/llama-native/bin/llama-completion ]; then bash scripts/build-logo-helper.sh; fi
swift build -c release "$@"
BIN_DIR="$(swift build -c release --show-bin-path "$@")"
APP="$PWD/dist/OpenStill.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OpenStill" "$APP/Contents/MacOS/OpenStill"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/LUTs "$APP/Contents/Resources/"
cp -R Resources/AI "$APP/Contents/Resources/"
cp -R Resources/LensProfiles "$APP/Contents/Resources/"
cp -R Resources/Licenses "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Helpers"
cp .build/llama-native/bin/llama-completion "$APP/Contents/Helpers/OpenStillLogoInference"
codesign --force --sign - "$APP/Contents/Helpers/OpenStillLogoInference"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp LICENSE "$APP/Contents/Resources/LICENSE.txt"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
python3 scripts/bundle-native.py "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"
