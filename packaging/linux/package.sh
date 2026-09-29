#!/bin/sh
# Turns the tree staged by build.sh into this distribution's package:
#
#   packaging/linux/package.sh <stage-root> <version> <out-dir>
#
# Debian/Ubuntu → .deb (dependencies computed by dpkg-shlibdeps against this system),
# Fedora → .rpm (rpm's own ELF dependency generator). Arch builds through its PKGBUILD instead.
# The file name carries the flavour (photo-wagon_0.3.0-1~ubuntu26.04_amd64.deb) because each
# package links the Qt of the release it was built on.
set -eu
[ $# -eq 3 ] || { echo "usage: $0 <stage-root> <version> <out-dir>" >&2; exit 2; }
ROOT=$(cd "$1" && pwd)
PKGVER=$2   # not VERSION: /etc/os-release, sourced below, sets that
mkdir -p "$3"
OUT=$(cd "$3" && pwd)
. /etc/os-release
FLAVOUR="$ID${VERSION_ID:+$VERSION_ID}"
SUMMARY="Local-first photo library with faces, places and peer-to-peer sync"

deb() {
    work=$(mktemp -d)
    # dpkg-shlibdeps wants a debian/control to exist; it only reads the package list from it.
    mkdir -p "$work/debian"
    printf 'Source: photo-wagon\n\nPackage: photo-wagon\nArchitecture: any\n' > "$work/debian/control"
    # --ignore-missing-info: the private OpenCV libraries belong to no package, so they have no
    # shlibs entry; everything they and the app link from the system still gets its dependency.
    shlibs=$(cd "$work" && dpkg-shlibdeps -O --ignore-missing-info -l"$ROOT/usr/lib/photo-wagon" \
        "$ROOT/usr/bin/photo-wagon" "$ROOT"/usr/lib/photo-wagon/libopencv_*.so.*.*.* \
        | sed -n 's/^shlibs:Depends=//p')
    rm -rf "$work"
    [ -n "$shlibs" ] || { echo "package: dpkg-shlibdeps found no dependencies" >&2; exit 1; }
    # What the ELF dependencies cannot see: the QML modules and Qt plugins loaded at run time.
    qml="qml6-module-qtquick, qml6-module-qtquick-controls, qml6-module-qtquick-layouts,
 qml6-module-qtquick-window, qml6-module-qtquick-dialogs, qml6-module-qtquick-effects,
 qml6-module-qtquick-shapes, qml6-module-qtquick-templates, qml6-module-qtqml-workerscript,
 qml6-module-qtmultimedia, qml6-module-qtlocation, qml6-module-qtpositioning, qt6-image-formats-plugins,
 qt6-wayland, curl"
    pkg="$OUT/pkgroot"
    rm -rf "$pkg" && mkdir -p "$pkg/DEBIAN"
    cp -a "$ROOT"/. "$pkg"/
    size=$(du -sk "$pkg" | cut -f1)
    debver="$PKGVER-1~$FLAVOUR"
    cat > "$pkg/DEBIAN/control" <<EOF
Package: photo-wagon
Version: $debver
Architecture: amd64
Maintainer: Marcelo A Caetano <rockristao@gmail.com>
Installed-Size: $size
Depends: $shlibs, $(echo "$qml" | tr -d '\n')
Recommends: tesseract-ocr-por
Section: graphics
Priority: optional
Homepage: https://github.com/caetanus/photo-wagon
Description: $SUMMARY
 Photo Wagon organizes every photo you own on your own devices: faces,
 places, natural-language search, OCR, non-destructive edits, and
 peer-to-peer sync between your computers and your phone. No cloud.
 .
 Run photo-wagon-fetch-models once to download the local AI models.
EOF
    file="$OUT/photo-wagon_${debver}_amd64.deb"
    dpkg-deb --root-owner-group --build "$pkg" "$file" >/dev/null
    rm -rf "$pkg"
    echo "$file"
}

rpm_() {
    top=$(mktemp -d)
    mkdir -p "$top/SPECS" "$top/BUILDROOT"
    rel="1.$FLAVOUR"
    cat > "$top/SPECS/photo-wagon.spec" <<EOF
# The OpenCV 5 in /usr/lib/photo-wagon is private to the app: neither provided nor required.
%global __provides_exclude_from ^/usr/lib/photo-wagon/.*\$
%global __requires_exclude ^libopencv_.*\$
%global debug_package %{nil}
%global __strip /bin/true
Name:           photo-wagon
Version:        $PKGVER
Release:        $rel
Summary:        $SUMMARY
License:        MIT
URL:            https://github.com/caetanus/photo-wagon
Requires:       qt6-qtdeclarative qt6-qtmultimedia qt6-qtlocation qt6-qtpositioning
Requires:       qt6-qtimageformats qt6-qtwayland curl
Recommends:     tesseract-langpack-por

%description
Photo Wagon organizes every photo you own on your own devices: faces, places,
natural-language search, OCR, non-destructive edits, and peer-to-peer sync
between your computers and your phone. No cloud.

Run photo-wagon-fetch-models once to download the local AI models.

%install
cp -a $ROOT/. %{buildroot}/

%files
/usr/bin/photo-wagon
/usr/bin/photo-wagon-fetch-models
/usr/lib/photo-wagon
/usr/share/applications/photo-wagon.desktop
/usr/share/icons/hicolor/*/apps/photo-wagon.*
EOF
    rpmbuild --quiet --define "_topdir $top" --define "_rpmdir $OUT" \
        --define "_build_name_fmt %%{NAME}-%%{VERSION}-%%{RELEASE}.%%{ARCH}.rpm" \
        -bb "$top/SPECS/photo-wagon.spec"
    rm -rf "$top"
    echo "$OUT/photo-wagon-$PKGVER-$rel.x86_64.rpm"
}

case "$ID" in
    debian|ubuntu) deb ;;
    fedora) rpm_ ;;
    *) echo "package: no package format for $ID" >&2; exit 1 ;;
esac
