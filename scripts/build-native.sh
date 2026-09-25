#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
PREFIX="$PWD/.build/native"
SOURCES="$PWD/.build/native-sources"
export MACOSX_DEPLOYMENT_TARGET=13.0
export CFLAGS="-mmacosx-version-min=13.0"
export CXXFLAGS="-mmacosx-version-min=13.0"
export LDFLAGS="-mmacosx-version-min=13.0"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
python3 scripts/fetch-native.py
mkdir -p "$PREFIX"
cmake -S "$SOURCES/pcre2" -B .build/pcre2-native -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_SHARED_LIBS=ON -DPCRE2_BUILD_PCRE2_8=ON -DPCRE2_BUILD_PCRE2_16=OFF -DPCRE2_BUILD_PCRE2_32=OFF -DPCRE2_BUILD_TESTS=OFF -DPCRE2_BUILD_PCRE2GREP=OFF
cmake --build .build/pcre2-native --parallel 4
cmake --install .build/pcre2-native
if [ ! -f .build/glib-native/build.ninja ]; then
    meson setup .build/glib-native "$SOURCES/glib" --prefix="$PREFIX" --buildtype=release -Dtests=false -Dinstalled_tests=false -Ddocumentation=false -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled -Dselinux=disabled
fi
meson compile -C .build/glib-native -j 4
meson install -C .build/glib-native
cmake -S "$SOURCES/lensfun" -B .build/lensfun-native -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_OSX_DEPLOYMENT_TARGET=13.0 -DBUILD_TESTS=OFF -DBUILD_LENSTOOL=OFF -DBUILD_DOC=OFF -DINSTALL_HELPER_SCRIPTS=OFF -DINSTALL_PYTHON_MODULE=OFF -DPYTHON=OFF
cmake --build .build/lensfun-native --parallel 4
cmake --install .build/lensfun-native
mkdir -p .build/lcms-native
cd .build/lcms-native
"$SOURCES/little-cms2/configure" --prefix="$PREFIX" --without-jpeg --without-tiff --disable-static
make -j4
make install
