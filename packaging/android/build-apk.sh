#!/bin/bash
# Builds the phone app's APK from nothing but the network, the way ANDROID.md describes the
# toolchain — for CI, where none of the local pieces (~/lab/android-d, ~/Qt, the cross-built
# archives in mobile/toolchain/android-libs) exist:
#
#   packaging/android/build-apk.sh <out-dir>
#
# Needs: an Android SDK at ANDROID_SDK_ROOT with sdkmanager, JDK 17 at JAVA_HOME, python3
# with pip (3.11 for the model converter), and the sibling repositories next to photo-wagon
# (packaging/fetch-sources.sh). Everything else lands under WORK (default ~/pw-android).
# arm64-v8a only (the phones); the x86_64 emulator build stays a local affair.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SRC=$(cd "$HERE/../.." && pwd)
TOP=$(cd "$SRC/.." && pwd)
mkdir -p "$1"
OUT=$(cd "$1" && pwd)
WORK=${WORK:-$HOME/pw-android}
JOBS=${JOBS:-$(nproc)}
mkdir -p "$WORK"

LDC_ANDROID_VERSION=1.42.0       # the device runtime and the host compiler must match (ANDROID.md)
QT_VERSION=6.11.1
NDK_VERSION=27.2.12479018
LIBSODIUM_VERSION=1.0.20-RELEASE
OPENSSL_ANDROID_VERSION=3.6.4
. "$SRC/packaging/versions.env"  # NGTCP2_VERSION
LITERT_VERSION=2.2.0
LITERT_SHA256_ARM64=97355a36cb8ac7628cf407773291e98da79f3ef184cc43cb0e57dedf5f0c0637

: "${ANDROID_SDK_ROOT:?set ANDROID_SDK_ROOT}"
: "${JAVA_HOME:?set JAVA_HOME (JDK 17)}"
NDK=$ANDROID_SDK_ROOT/ndk/$NDK_VERSION
TC=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
LIBS=$SRC/mobile/toolchain/android-libs/arm64
say() { echo "==> $*"; }

sdk() {
    [ -d "$NDK" ] && [ -d "$ANDROID_SDK_ROOT/platforms/android-36" ] && [ -d "$ANDROID_SDK_ROOT/build-tools/36.0.0" ] && return
    say "Android SDK: NDK $NDK_VERSION, platform 36, build-tools 36"
    local sm
    sm=$(ls "$ANDROID_SDK_ROOT"/cmdline-tools/*/bin/sdkmanager | head -1)
    yes | "$sm" --licenses >/dev/null || true
    "$sm" --install "ndk;$NDK_VERSION" "platforms;android-36" "build-tools;36.0.0" >/dev/null
}

ldc() {
    LDC_HOST=$WORK/ldc2-$LDC_ANDROID_VERSION-linux-x86_64
    LDC_DEVICE=$WORK/ldc2-$LDC_ANDROID_VERSION-android-aarch64
    local base=https://github.com/ldc-developers/ldc/releases/download/v$LDC_ANDROID_VERSION
    if [ ! -x "$LDC_HOST/bin/ldc2" ]; then
        say "LDC $LDC_ANDROID_VERSION (host compiler)"
        curl -fsSL "$base/ldc2-$LDC_ANDROID_VERSION-linux-x86_64.tar.xz" | tar -xJ -C "$WORK"
    fi
    if [ ! -d "$LDC_DEVICE/lib" ]; then
        say "LDC $LDC_ANDROID_VERSION (Android aarch64 runtime)"
        curl -fsSL "$base/ldc2-$LDC_ANDROID_VERSION-android-aarch64.tar.xz" | tar -xJ -C "$WORK"
    fi
    export LDC=$LDC_HOST/bin/ldc2
    # xiboca type-checks generated snippets with `dmd -o-`; LDC's dmd-compatible driver does that
    mkdir -p "$WORK/dmd-shim"
    ln -sf "$LDC_HOST/bin/ldmd2" "$WORK/dmd-shim/dmd"
    export PATH="$LDC_HOST/bin:$PATH:$WORK/dmd-shim"
}

qt() {
    QT_ROOT=$WORK/Qt
    python3 -m pip install --quiet py7zr
    [ -x "$QT_ROOT/$QT_VERSION/gcc_64/bin/androiddeployqt" ] \
        || python3 "$SRC/packaging/qt-fetch.py" "$QT_VERSION" linux_gcc_64 "$QT_ROOT"
    [ -f "$QT_ROOT/$QT_VERSION/android_arm64_v8a/lib/libQt6Multimedia_arm64-v8a.so" ] \
        || python3 "$SRC/packaging/qt-fetch.py" "$QT_VERSION" android_arm64_v8a "$QT_ROOT" qtmultimedia qtshadertools
    export QT_HOST=$QT_ROOT/$QT_VERSION/gcc_64
    export QT_ANDROID=$QT_ROOT/$QT_VERSION/android_arm64_v8a
}

# The toolchain files under mobile/toolchain name one machine's paths; render them for this one.
toolchain_files() {
    TCW=$WORK/toolchain
    mkdir -p "$TCW/pkgconfig"
    local subst=(-e "s|/home/caetano/Qt/6.11.1|$QT_ROOT/$QT_VERSION|g"
                 -e "s|/opt/android-sdk/ndk/27.2.12479018|$NDK|g"
                 -e "s|/home/caetano/lab/android-d|$WORK|g"
                 -e "s|/home/caetano/lab/qt-dlang-gen|$TOP/qt-dlang-gen|g")
    sed "${subst[@]}" "$SRC/mobile/toolchain/ldc2-android.conf" > "$TCW/ldc2-android.conf"
    sed "${subst[@]}" "$SRC/mobile/toolchain/spec_cxx_quick_android.json" > "$TCW/spec_cxx_quick_android.json"
    for pc in "$SRC"/mobile/toolchain/pkgconfig/*.pc; do sed "${subst[@]}" "$pc" > "$TCW/pkgconfig/$(basename "$pc")"; done
    export LDC_CONF=$TCW/ldc2-android.conf
}

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

binding() {
    local b=$TOP/qt-dlang-gen/.build/qt-6.11-android-arm64-cxx-quick
    [ -f "$b/libbinding_ldc2.a" ] && [ -f "$b/libshims.a" ] && return
    say "DSide quick binding for Qt $QT_VERSION android arm64"
    libclang_path
    (cd "$TOP/qt-dlang-gen/xiboca" && dub build --quiet --compiler=ldc2)
    DSIDE=$TOP/qt-dlang-gen NDK=$NDK QT_ANDROID=$QT_ANDROID SPEC=$TCW/spec_cxx_quick_android.json \
        PKGCONF_DIR=$TCW/pkgconfig ABI=arm64 sh "$SRC/mobile/toolchain/build-binding.sh" generate
    DSIDE=$TOP/qt-dlang-gen NDK=$NDK QT_ANDROID=$QT_ANDROID SPEC=$TCW/spec_cxx_quick_android.json \
        PKGCONF_DIR=$TCW/pkgconfig ABI=arm64 sh "$SRC/mobile/toolchain/build-binding.sh" all
}

dub_packages() {
    say "dub packages the phone build compiles from source"
    for p in eventcore@0.9.39 vibe-core@2.14.0 vibe-container@1.7.1 taggedalgebraic@1.0.1 \
             stdx-allocator@2.77.5 libsodiumd@0.2.0+1.0.18 openssl@3.4.0; do
        dub fetch --cache=user "$p" >/dev/null
        # the build scripts name the old layout, <name>-<version>/; newer dub writes <name>/<version>/
        local n=${p%@*} v=${p#*@} d=$HOME/.dub/packages
        [ -d "$d/$n-${v//+/_}" ] || [ ! -d "$d/$n/$v" ] || ln -s "$n/$v" "$d/$n-${v//+/_}"
    done
}

libsodium() {
    [ -f "$LIBS/libsodium.a" ] && return
    say "libsodium $LIBSODIUM_VERSION (full build, arm64)"
    rm -rf "$WORK/src/libsodium" && mkdir -p "$WORK/src"
    git clone --quiet --depth 1 --branch "$LIBSODIUM_VERSION" https://github.com/jedisct1/libsodium.git "$WORK/src/libsodium"
    (cd "$WORK/src/libsodium" && LIBSODIUM_FULL_BUILD=1 ANDROID_NDK_HOME=$NDK dist-build/android-armv8-a.sh >/dev/null)
    mkdir -p "$LIBS"
    cp "$WORK"/src/libsodium/libsodium-android-armv8-a*/lib/libsodium.a "$LIBS/"
}

openssl_ngtcp2() {
    [ -f "$LIBS/libngtcp2_crypto_ossl.a" ] && [ -f "$LIBS/libssl.a" ] && return
    local o=$WORK/out-arm64
    say "OpenSSL $OPENSSL_ANDROID_VERSION + ngtcp2 $NGTCP2_VERSION (static, arm64)"
    rm -rf "$WORK/src/openssl" "$WORK/src/ngtcp2" && mkdir -p "$WORK/src"
    git clone --quiet --depth 1 --branch "openssl-$OPENSSL_ANDROID_VERSION" https://github.com/openssl/openssl.git "$WORK/src/openssl"
    (cd "$WORK/src/openssl" && PATH=$TC:$PATH ANDROID_NDK_ROOT=$NDK \
        ./Configure android-arm64 -D__ANDROID_API__=35 no-shared no-tests no-apps no-docs --prefix="$o" >/dev/null \
        && PATH=$TC:$PATH make -j"$JOBS" build_libs >/dev/null && make install_dev >/dev/null)
    git clone --quiet --depth 1 --branch "v$NGTCP2_VERSION" https://github.com/ngtcp2/ngtcp2.git "$WORK/src/ngtcp2"
    (cd "$WORK/src/ngtcp2" && autoreconf -i >/dev/null 2>&1 \
        && PKG_CONFIG_LIBDIR=$o/lib/pkgconfig CFLAGS="-fPIC -O2" CXXFLAGS="-fPIC -O2" \
           CC=$TC/aarch64-linux-android35-clang CXX=$TC/aarch64-linux-android35-clang++ \
           AR=$TC/llvm-ar RANLIB=$TC/llvm-ranlib ./configure --host=aarch64-linux-android --build=x86_64-linux-gnu \
           --enable-lib-only --with-openssl --without-libnghttp3 --disable-shared --enable-static --prefix="$o" >/dev/null \
        && make -j"$JOBS" >/dev/null && make install >/dev/null)
    mkdir -p "$LIBS"
    cp "$o"/lib/libssl.a "$o"/lib/libcrypto.a "$o"/lib/libngtcp2.a "$o"/lib/libngtcp2_crypto_ossl.a "$LIBS/"
}

hyperswarm() {
    [ -f "$LIBS/libhsudx-android.a" ] && [ -f "$LIBS/libhsdswarm-android.a" ] && return
    say "d-hyperswarm for arm64 (libudx C core + the D side)"
    ANDROID_NDK=$NDK ARCH=arm64 bash "$TOP/d-hyperswarm/vendor/build-libudx-android.sh" "$WORK/hs"
    LDC=$LDC LDC_CONF=$LDC_CONF ARCH=arm64 bash "$TOP/d-hyperswarm/build-dswarm-android.sh" "$WORK/hs"
    cp "$WORK/hs/libhsudx-android.a" "$WORK/hs/libhsdswarm-android.a" "$LIBS/"
}

litert() {
    local d=$SRC/mobile/android/libs/arm64-v8a
    [ -f "$d/libLiteRt.so" ] && return
    say "LiteRT $LITERT_VERSION (from its AAR on Google Maven)"
    curl -fsSL -o "$WORK/litert.aar" \
        "https://dl.google.com/dl/android/maven2/com/google/ai/edge/litert/litert/$LITERT_VERSION/litert-$LITERT_VERSION.aar"
    rm -rf "$WORK/litert" && mkdir -p "$WORK/litert" "$d"
    (cd "$WORK/litert" && python3 -m zipfile -e "$WORK/litert.aar" .)
    cp "$WORK"/litert/jni/arm64-v8a/libLiteRt.so "$WORK"/litert/jni/arm64-v8a/libLiteRtClGlAccelerator.so "$d/"
    echo "$LITERT_SHA256_ARM64  $d/libLiteRt.so" | sha256sum -c --status \
        || { echo "build-apk: libLiteRt.so is not the one the app was validated with" >&2; exit 1; }
}

models() {
    local t=$SRC/models/tflite
    [ -f "$t/yunet/face_detection_yunet_2023mar_float16.tflite" ] && [ -f "$t/r100/r100_float16.tflite" ] && return
    say "phone face models (ONNX → TFLite float16)"
    sh "$SRC/packaging/fetch-models.sh" "$WORK/onnx" >/dev/null
    sh "$SRC/tools/mlphone/convert.sh" "$WORK/onnx" "$WORK/tflite"
    mkdir -p "$t/yunet" "$t/r100"
    cp "$WORK/tflite/yunet.tflite" "$t/yunet/face_detection_yunet_2023mar_float16.tflite"
    cp "$WORK/tflite/r100.tflite" "$t/r100/r100_float16.tflite"
}

sdk
ldc
qt
toolchain_files
dub_packages
binding
libsodium
openssl_ngtcp2
hyperswarm
litert
models
say "the app"
export DSIDE=$TOP/qt-dlang-gen NDK ANDROID_SDK_ROOT JAVA_HOME
(cd "$SRC/mobile" && ./build-android.sh link && ./build-android.sh package)
cp "$SRC/mobile/build-android/photo-wagon-mobile-debug.apk" "$OUT/"
say "done: $OUT/photo-wagon-mobile-debug.apk"
