#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
export PKG_CONFIG_PATH="$PWD/.build/native/lib/pkgconfig"
if [ ! -f .build/native/lib/liblcms2.dylib ] || [ ! -f .build/native/lib/liblensfun.dylib ]; then bash scripts/build-native.sh; fi
TEST_STORAGE="$(mktemp -d /tmp/openstill-tests.XXXXXX)"
export OPENSTILL_STORAGE_ROOT="$TEST_STORAGE"
trap 'rm -rf "$TEST_STORAGE"' EXIT
DEVELOPER_DIR_PATH="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_DIR_PATH/Library/Developer/Frameworks"
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
    swift test "$@" -Xlinker -rpath -Xlinker "$PWD/.build/native/lib" -Xswiftc -F -Xswiftc "$FRAMEWORKS" -Xlinker -F -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS" -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
else
    swift test "$@" -Xlinker -rpath -Xlinker "$PWD/.build/native/lib"
fi
