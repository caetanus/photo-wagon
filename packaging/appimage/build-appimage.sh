#!/bin/sh
# Builds the Photo Wagon AppImage:
#
#   packaging/appimage/build-appimage.sh <version> <out-dir>
#
# Runs in an ubuntu:24.04 container (the oldest glibc we target, so the image runs on every
# distribution from there on). Qt comes from qt.io and is bundled, with the rest of the
# non-base libraries, by linuxdeploy and its Qt plugin. The AppImage installs itself into
# ~/.local on first run (see AppRun).
set -eu
[ $# -eq 2 ] || { echo "usage: $0 <version> <out-dir>" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)
VERSION=$1
mkdir -p "$2"
OUT=$(cd "$2" && pwd)
DEPS=${DEPS:-/opt/pw-deps}
WORK=${WORK:-/tmp/pw-appimage}
export QT_SOURCE=qtio

rm -rf "$WORK" && mkdir -p "$WORK"
sh "$SRC/packaging/linux/build.sh" "$WORK/AppDir"

QT_VERSION=$(tr -d '[:space:]' < "$SRC/../qt-dlang-gen/qt-version.txt")
QT_PREFIX="$DEPS/qt/$QT_VERSION/gcc_64"
APPDIR="$WORK/AppDir"
mkdir -p "$APPDIR/usr/share/photo-wagon"
echo "$VERSION-$(date -u +%Y%m%d%H%M%S)" > "$APPDIR/usr/share/photo-wagon/build-id"

# linuxdeploy and its Qt plugin (continuous builds; they are what the AppImage world uses)
for t in linuxdeploy-x86_64.AppImage linuxdeploy-plugin-qt-x86_64.AppImage; do
    [ -x "$DEPS/bin/$t" ] && continue
    mkdir -p "$DEPS/bin"
    case "$t" in
        linuxdeploy-x86_64*) u=https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/$t ;;
        *) u=https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/continuous/$t ;;
    esac
    curl -fsSL -o "$DEPS/bin/$t" "$u" && chmod 755 "$DEPS/bin/$t"
done
# qt.io's TIFF image plugin links libtiff.so.5, which 24.04 no longer ships; TIFF thumbnails
# and previews come from libvips anyway.
rm -f "$QT_PREFIX/plugins/imageformats/libqtiff.so"
export PATH="$DEPS/bin:$QT_PREFIX/bin:$PATH"
export APPIMAGE_EXTRACT_AND_RUN=1          # no FUSE in a container
export QMAKE="$QT_PREFIX/bin/qmake"
export QML_SOURCES_PATHS="$SRC/qml"
export EXTRA_QT_MODULES="location;positioning;waylandclient;svg;imageformats"
export EXTRA_PLATFORM_PLUGINS="libqwayland.so"
export LD_LIBRARY_PATH="$APPDIR/usr/lib/photo-wagon:$QT_PREFIX/lib${DEPS:+:$DEPS/openssl/lib}"
export LDAI_OUTPUT="$OUT/Photo_Wagon-$VERSION-x86_64.AppImage"
export VERSION

cd "$WORK"
linuxdeploy-x86_64.AppImage --appdir "$APPDIR" \
    --executable "$APPDIR/usr/bin/photo-wagon" \
    --desktop-file "$APPDIR/usr/share/applications/photo-wagon.desktop" \
    --icon-file "$APPDIR/usr/share/icons/hicolor/256x256/apps/photo-wagon.png" \
    --custom-apprun "$HERE/AppRun" \
    --plugin qt
# Qt's network stack and the app's QUIC load libssl.so.3 by name: bundle the 3.5 we built,
# never the older system one.
if [ -d "$DEPS/openssl/lib" ]; then
    cp -L "$DEPS/openssl/lib/libssl.so.3" "$DEPS/openssl/lib/libcrypto.so.3" "$APPDIR/usr/lib/"
fi
linuxdeploy-x86_64.AppImage --appdir "$APPDIR" --output appimage
echo "$LDAI_OUTPUT"
