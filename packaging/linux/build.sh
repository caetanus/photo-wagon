#!/bin/sh
# Builds Photo Wagon for the Linux distribution this runs on, against THAT distribution's Qt,
# and stages an installable tree:
#
#   packaging/linux/build.sh <stage-dir>
#
# Meant for a fresh container of the target distribution (the CI runs one per flavour), as root.
# Every package is built on the flavour it is for because the app links the system Qt, and the
# DSide binding is generated from that Qt's own headers: Qt's private API carries its release
# in the mangled names, so a binary made against one Qt minor does not load against another.
#
# What the distributions do not ship in a usable version is built here and kept private to the
# package, under /usr/lib/photo-wagon: OpenCV 5 (every distribution is on 4.x) and ngtcp2 with
# its OpenSSL backend (linked statically). The LDC compiler comes from its upstream release.
#
# DEPS (default /opt/pw-deps) holds those builds; the CI caches it per flavour.
#
# QT_SOURCE=qtio is the AppImage build: Qt comes from qt.io (QT_VERSION, default the DSide pin)
# into DEPS/qt instead of from the distribution, and an OpenSSL >= 3.5 is built when the
# system's is older (ngtcp2's OpenSSL backend needs the 3.5 QUIC API).
set -eu
[ $# -eq 1 ] || { echo "usage: $0 <stage-dir>" >&2; exit 2; }
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)          # the photo-wagon checkout
TOP=$(cd "$SRC/.." && pwd)              # where the sibling repositories live
. "$SRC/packaging/versions.env"
mkdir -p "$1"
STAGE=$(cd "$1" && pwd)
DEPS=${DEPS:-/opt/pw-deps}
JOBS=${JOBS:-$(nproc)}
. /etc/os-release

say() { echo "==> $*"; }

# ---------------------------------------------------------------- distribution packages
install_build_deps() {
    case "$ID" in
    debian|ubuntu)
        export DEBIAN_FRONTEND=noninteractive
        qtpkgs="qt6-base-dev qt6-base-private-dev qt6-declarative-dev qt6-declarative-private-dev
            qt6-multimedia-dev qt6-location-dev qt6-positioning-dev"
        # qt.io's Qt needs the libraries its own build links, not the distribution's Qt
        [ "${QT_SOURCE:-}" = qtio ] && qtpkgs="python3-pip libgl-dev libegl-dev libxkbcommon-dev
            libfontconfig1-dev libfreetype-dev libxkbcommon-x11-0 libxcb-cursor0 libxcb-icccm4
            libxcb-image0 libxcb-keysyms1 libxcb-randr0 libxcb-render-util0 libxcb-shape0
            libxcb-xinerama0 libxcb-xkb1 libwayland-client0 libwayland-cursor0 libwayland-egl1
            libdbus-1-3 libpulse0 libasound2t64 libgstreamer-plugins-base1.0-0"
        apt-get update -qq
        # shellcheck disable=SC2086
        apt-get install -y -qq --no-install-recommends $qtpkgs \
            build-essential cmake ninja-build meson pkg-config git curl ca-certificates xz-utils \
            python3 file patchelf dpkg-dev fakeroot \
            clang libclang-dev llvm-dev \
            libsqlite3-dev libgexiv2-dev libvips-dev libglib2.0-dev libqrencode-dev \
            libcurl4-openssl-dev libsodium-dev libc-ares-dev libssl-dev \
            libtesseract-dev libleptonica-dev zlib1g-dev
        ;;
    fedora)
        dnf install -y -q \
            gcc gcc-c++ make cmake ninja-build meson pkgconf-pkg-config git curl xz python3 file \
            patchelf rpm-build which \
            clang clang-devel llvm-devel \
            qt6-qtbase-devel qt6-qtbase-private-devel qt6-qtdeclarative-devel \
            qt6-qtmultimedia-devel qt6-qtlocation-devel qt6-qtpositioning-devel \
            sqlite-devel libgexiv2-devel vips-devel glib2-devel qrencode-devel \
            libcurl-devel libsodium-devel c-ares-devel openssl-devel \
            tesseract-devel leptonica-devel zlib-devel
        ;;
    arch)
        pacman -Syu --noconfirm --needed \
            base-devel cmake ninja meson git curl python file patchelf which \
            clang llvm \
            qt6-base qt6-declarative qt6-multimedia qt6-location qt6-positioning \
            sqlite libgexiv2 libvips glib2 qrencode curl libsodium c-ares openssl \
            tesseract leptonica zlib
        ;;
    *)
        echo "build: no package list for $ID" >&2; exit 1 ;;
    esac
}

qt_minor() { pkg-config --modversion Qt6Core | cut -d. -f1-2; }

# ---------------------------------------------------------------- toolchain and private libs
install_ldc() {
    [ "${USE_SYSTEM_LDC:-}" = 1 ] && return    # the Arch package builds with the distribution's ldc/dub
    [ -x "$DEPS/ldc/bin/ldc2" ] && return
    say "LDC $LDC_VERSION"
    mkdir -p "$DEPS/ldc"
    curl -fsSL "https://github.com/ldc-developers/ldc/releases/download/v$LDC_VERSION/ldc2-$LDC_VERSION-linux-x86_64.tar.xz" \
        | tar -xJ -C "$DEPS/ldc" --strip-components=1
}

# The AppImage's Qt: qt.io's release, the module set the app imports, through DSide's fetcher
# (it verifies every archive's published sha256 and rewrites the .pc prefixes).
fetch_qt() {
    QT_VERSION=${QT_VERSION:-$(tr -d '[:space:]' < "$TOP/qt-dlang-gen/qt-version.txt")}
    QT_PREFIX="$DEPS/qt/$QT_VERSION/gcc_64"
    if [ ! -f "$QT_PREFIX/lib/pkgconfig/Qt6Core.pc" ]; then
        say "Qt $QT_VERSION from qt.io"
        python3 -m py7zr --help >/dev/null 2>&1 \
            || pip3 install --quiet --break-system-packages py7zr 2>/dev/null || pip3 install --quiet py7zr
        sed 's/^modules=(.*/modules=(qtmultimedia qtpositioning qtlocation qtshadertools qtimageformats)/' \
            "$TOP/qt-dlang-gen/tools/linux/get-qt.sh" > "$DEPS/get-qt.sh"
        bash "$DEPS/get-qt.sh" --version "$QT_VERSION" --dest "$DEPS/qt" --skip-webengine
    fi
    export PATH="$QT_PREFIX/bin:$PATH"
    export PKG_CONFIG_PATH="$QT_PREFIX/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LD_LIBRARY_PATH="$QT_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export QT_PREFIX
}

# OpenSSL >= 3.5 where the system's is older (Ubuntu 24.04 has 3.0).
build_openssl() {
    pkg-config --atleast-version=3.5 openssl 2>/dev/null && [ ! -d "$DEPS/openssl" ] && return
    if [ ! -f "$DEPS/openssl/lib/pkgconfig/openssl.pc" ]; then
        say "OpenSSL $OPENSSL_VERSION"
        rm -rf "$DEPS/src/openssl" && mkdir -p "$DEPS/src"
        git clone --quiet --depth 1 --branch "openssl-$OPENSSL_VERSION" https://github.com/openssl/openssl.git "$DEPS/src/openssl"
        ( cd "$DEPS/src/openssl" && ./Configure --prefix="$DEPS/openssl" --libdir=lib shared no-tests >/dev/null \
            && make -j "$JOBS" >/dev/null && make install_sw >/dev/null )
        rm -rf "$DEPS/src/openssl"
    fi
    export PKG_CONFIG_PATH="$DEPS/openssl/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    export LIBRARY_PATH="$DEPS/openssl/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export CPATH="$DEPS/openssl/include${CPATH:+:$CPATH}"
    export LD_LIBRARY_PATH="$DEPS/openssl/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
}

build_opencv() {
    [ -f "$DEPS/opencv/lib/pkgconfig/opencv5.pc" ] && return
    say "OpenCV $OPENCV_VERSION (the modules the face and CLIP shims use)"
    rm -rf "$DEPS/src/opencv"
    mkdir -p "$DEPS/src"
    git clone --quiet --depth 1 --branch "$OPENCV_VERSION" https://github.com/opencv/opencv.git "$DEPS/src/opencv"
    cmake -S "$DEPS/src/opencv" -B "$DEPS/src/opencv/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS/opencv" -DCMAKE_INSTALL_LIBDIR=lib \
        -DBUILD_LIST=core,imgproc,imgcodecs,dnn,objdetect,flann,features,geometry \
        -DOPENCV_GENERATE_PKGCONFIG=ON -DBUILD_SHARED_LIBS=ON \
        -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_opencv_apps=OFF \
        -DBUILD_JAVA=OFF -DBUILD_opencv_python3=OFF -DWITH_GTK=OFF -DWITH_QT=OFF \
        -DWITH_FFMPEG=OFF -DWITH_GSTREAMER=OFF -DWITH_V4L=OFF -DWITH_OPENEXR=OFF \
        -DWITH_OPENCL=OFF -DWITH_VA=OFF -DWITH_VA_INTEL=OFF -DWITH_1394=OFF \
        -DBUILD_ZLIB=ON -DBUILD_PNG=ON -DBUILD_JPEG=ON -DBUILD_WEBP=ON -DBUILD_TIFF=ON \
        -DBUILD_OPENJPEG=ON -DWITH_JASPER=OFF -DWITH_AVIF=OFF -DWITH_IMGCODEC_HDR=ON
    cmake --build "$DEPS/src/opencv/build" -j "$JOBS"
    cmake --install "$DEPS/src/opencv/build" >/dev/null
    rm -rf "$DEPS/src/opencv"
}

build_ngtcp2() {
    [ -f "$DEPS/ngtcp2/lib/libngtcp2_crypto_ossl.a" ] && return
    say "ngtcp2 $NGTCP2_VERSION (static, OpenSSL backend)"
    rm -rf "$DEPS/src/ngtcp2"
    mkdir -p "$DEPS/src"
    git clone --quiet --depth 1 --branch "v$NGTCP2_VERSION" https://github.com/ngtcp2/ngtcp2.git "$DEPS/src/ngtcp2"
    cmake -S "$DEPS/src/ngtcp2" -B "$DEPS/src/ngtcp2/build" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$DEPS/ngtcp2" -DCMAKE_INSTALL_LIBDIR=lib \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DENABLE_SHARED_LIB=OFF -DENABLE_STATIC_LIB=ON \
        -DENABLE_OPENSSL=ON -DENABLE_GNUTLS=OFF -DENABLE_BORINGSSL=OFF -DENABLE_PICOTLS=OFF \
        -DENABLE_WOLFSSL=OFF -DBUILD_TESTING=OFF -DENABLE_LIB_ONLY=ON \
        ${OPENSSL_ROOT:+-DOPENSSL_ROOT_DIR=$OPENSSL_ROOT}
    cmake --build "$DEPS/src/ngtcp2/build" -j "$JOBS"
    cmake --install "$DEPS/src/ngtcp2/build" >/dev/null
    rm -rf "$DEPS/src/ngtcp2"
}

# ---------------------------------------------------------------- DSide binding for this Qt
# xiboca links -lclang; Debian/Ubuntu keep libclang.so only under llvm-config's libdir.
libclang_path() {
    for d in "$(llvm-config --libdir 2>/dev/null)" /usr/lib/llvm-*/lib; do
        if [ -n "$d" ] && [ -e "$d/libclang.so" ]; then
            export LIBRARY_PATH="$d${LIBRARY_PATH:+:$LIBRARY_PATH}"
            export LD_LIBRARY_PATH="$d${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            return
        fi
    done
}
build_binding() {
    minor=$(qt_minor)
    b="$TOP/qt-dlang-gen/.build/qt-$minor-cxx-quick"
    say "DSide quick binding for Qt $minor"
    cd "$TOP/qt-dlang-gen"
    libclang_path
    if [ ! -f "$b/libbinding_ldc2.a" ] || [ ! -f "$b/libshims.a" ]; then
        sh "$SRC/packaging/dside-binding.sh" "$TOP/qt-dlang-gen"
    fi
    # dub.sdl names the 6.11 tree; on another Qt minor the binding for THIS Qt answers to it.
    if [ "$minor" != 6.11 ]; then
        ln -sfn "qt-$minor-cxx-quick" .build/qt-6.11-cxx-quick
        mkdir -p generated
        ln -sfn "qt-$minor" generated/qt-6.11
    fi
    cd "$SRC"
}

build_qmlcss() {
    [ -f "$TOP/qml-css-engine/build/libqmlcssengine.a" ] && return
    say "qml-css-engine"
    meson setup "$TOP/qml-css-engine/build" "$TOP/qml-css-engine" \
        --buildtype=release -Db_ndebug=true -Ddefault_library=static >/dev/null
    ninja -C "$TOP/qml-css-engine/build"
}

# ---------------------------------------------------------------- the app
build_app() {
    say "photo-wagon"
    cd "$SRC"
    export PKG_CONFIG_PATH="$DEPS/opencv/lib/pkgconfig:$DEPS/ngtcp2/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
    # cc (LDC's linker driver) searches LIBRARY_PATH for -l: OpenCV and the static ngtcp2.
    export LIBRARY_PATH="$DEPS/opencv/lib:$DEPS/ngtcp2/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"
    export CPATH="$DEPS/ngtcp2/include${CPATH:+:$CPATH}"
    export QMLCSS="$TOP/qml-css-engine"
    # dub resolves each `libs` name through pkg-config first; a .pc under that exact name makes
    # the link take OUR ngtcp2 (and, for the AppImage, our OpenSSL 3.5) rather than whatever
    # older copy the distribution has in /usr/lib.
    mkdir -p "$DEPS/pc-compat"
    pc() {   # <name> <libs>
        printf 'Name: %s\nDescription: photo-wagon build compat\nVersion: 0\nLibs: %s\n' "$1" "$2" \
            > "$DEPS/pc-compat/$1.pc"
    }
    pc ngtcp2 "$DEPS/ngtcp2/lib/libngtcp2.a"
    pc ngtcp2_crypto_ossl "$DEPS/ngtcp2/lib/libngtcp2_crypto_ossl.a"
    if [ -d "$DEPS/openssl/lib" ]; then
        pc ssl "-L$DEPS/openssl/lib -lssl"
        pc crypto "-L$DEPS/openssl/lib -lcrypto"
    fi
    export PKG_CONFIG_PATH="$DEPS/pc-compat:$PKG_CONFIG_PATH"
    # gexiv2 0.16 (Fedora 44) installs as gexiv2-0.16 / -lgexiv2-0.16; the calls the app makes are
    # the same there (deprecated, not removed). dub resolves `libs "gexiv2"` through pkg-config,
    # so a gexiv2.pc that points at it is all the link needs.
    if ! pkg-config --exists gexiv2 && pkg-config --exists gexiv2-0.16; then
        sed 's/^Name:.*/Name: gexiv2/' "$(pkg-config --variable=pcfiledir gexiv2-0.16)/gexiv2-0.16.pc" \
            > "$DEPS/pc-compat/gexiv2.pc"
    fi
    rm -f csrc/*.a csrc/*.o
    dub build --compiler=ldc2 -c app -b package
}

stage() {
    say "staging into $STAGE"
    rm -rf "$STAGE" && mkdir -p "$STAGE"
    install -Dm755 "$SRC/photo-wagon" "$STAGE/usr/bin/photo-wagon"
    install -Dm755 "$SRC/packaging/fetch-models.sh" "$STAGE/usr/bin/photo-wagon-fetch-models"
    # OpenCV 5, private to the app
    mkdir -p "$STAGE/usr/lib/photo-wagon"
    for so in "$DEPS"/opencv/lib/libopencv_*.so.*; do
        [ -L "$so" ] && continue
        cp "$so" "$STAGE/usr/lib/photo-wagon/"
    done
    ( cd "$STAGE/usr/lib/photo-wagon" && for f in libopencv_*.so.*.*.*; do
        soname=$(readelf -d "$f" | sed -n 's/.*SONAME.*\[\(.*\)\].*/\1/p')
        [ -n "$soname" ] && [ "$soname" != "$f" ] && ln -sf "$f" "$soname"
      done )
    patchelf --set-rpath /usr/lib/photo-wagon "$STAGE/usr/bin/photo-wagon"
    for f in "$STAGE"/usr/lib/photo-wagon/libopencv_*.so.*.*.*; do patchelf --set-rpath '$ORIGIN' "$f"; done
    strip --strip-unneeded "$STAGE/usr/bin/photo-wagon" "$STAGE"/usr/lib/photo-wagon/libopencv_*.so.*.*.*
    # desktop entry and icons
    mkdir -p "$STAGE/usr/share/applications"
    sed "s|@EXEC@|/usr/bin/photo-wagon|" "$SRC/share/photo-wagon.desktop" > "$STAGE/usr/share/applications/photo-wagon.desktop"
    for s in 48 128 256 512; do
        install -Dm644 "$SRC/share/icon-$s.png" "$STAGE/usr/share/icons/hicolor/${s}x${s}/apps/photo-wagon.png"
    done
    install -Dm644 "$SRC/share/photo-wagon.svg" "$STAGE/usr/share/icons/hicolor/scalable/apps/photo-wagon.svg"
    # what the package tooling needs to know about this build
    {
        echo "QT_MINOR=$(qt_minor)"
        echo "DISTRO_ID=$ID"
        echo "DISTRO_VERSION=${VERSION_ID:-rolling}"
        echo "DISTRO_CODENAME=${VERSION_CODENAME:-}"
    } > "$STAGE/../build-info.env"
}

[ "${SKIP_DEPS:-}" = 1 ] || install_build_deps
install_ldc
export PATH="$DEPS/ldc/bin:$PATH"
# xiboca type-checks generated snippets with `dmd -o-`; LDC's dmd-compatible driver does that
mkdir -p "$DEPS/dmd-shim"
ln -sf "$(command -v ldmd2)" "$DEPS/dmd-shim/dmd"
export PATH="$PATH:$DEPS/dmd-shim"
[ -d "$TOP/qt-dlang-gen" ] || { echo "build: the sibling repositories are missing (packaging/fetch-sources.sh)" >&2; exit 1; }
[ "${QT_SOURCE:-}" = qtio ] && fetch_qt
build_openssl
[ -d "$DEPS/openssl" ] && OPENSSL_ROOT="$DEPS/openssl"
build_opencv
build_ngtcp2
build_binding
build_qmlcss
build_app
stage
say "done: $STAGE"
