#!/bin/sh
# Writes the PKGBUILD for this photo-wagon commit and the sibling commits it was built with:
#
#   packaging/arch/make-pkgbuild.sh <pkgver> <out-dir>
#
# The commits are read from the checkouts next to photo-wagon (packaging/fetch-sources.sh).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)
TOP=$(cd "$SRC/.." && pwd)
mkdir -p "$2"
rev() { git -C "$TOP/$1" rev-parse HEAD; }
sed -e "s/@PKGVER@/$1/" \
    -e "s/@PW_COMMIT@/$(rev photo-wagon)/" \
    -e "s/@DSIDE_COMMIT@/$(rev qt-dlang-gen)/" \
    -e "s/@HYPERSWARM_COMMIT@/$(rev d-hyperswarm)/" \
    -e "s/@LIBP2P_COMMIT@/$(rev libp2p-dlang)/" \
    -e "s/@WEBRTC_COMMIT@/$(rev d-webrtc-v3)/" \
    -e "s/@QMLCSS_COMMIT@/$(rev qml-css-engine)/" \
    "$HERE/PKGBUILD.in" > "$2/PKGBUILD"
echo "$2/PKGBUILD"
