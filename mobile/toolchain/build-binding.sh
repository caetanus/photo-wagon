#!/bin/sh
# Builds the DSide cxx-quick binding for Qt 6.11.1 android_arm64_v8a:
#   generate   xiboca with the cross spec (host libclang, host clang resource dir)
#   d          libbinding_ldc2.a  — every generated .d, ldc2 cross, PIC (goes into a .so)
#   shims      libshims.a         — the generated .cpp, NDK clang++
#   all        d + shims (generate first if the gen dir is missing)
# Mirrors reggae/qtd_build.d (qtdBindLib / the shims target) with the cross toolchain swapped in.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
DSIDE=${DSIDE:-$HOME/lab/qt-dlang-gen}
QT_ANDROID=${QT_ANDROID:-$HOME/Qt/6.11.1/android_arm64_v8a}
NDK=${NDK:-/opt/android-sdk/ndk/27.2.12479018}
NDK_BIN=$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin
API=${API:-35}
TRIPLE=aarch64-linux-android
CONF=$HERE/ldc2-android.conf
SPEC=$HERE/spec_cxx_quick_android.json
GEN=$DSIDE/generated/qt-6.11-android-arm64/cxx-quick
BUILD=$DSIDE/.build/qt-6.11-android-arm64-cxx-quick
MODS="Qt6Quick Qt6QmlModels Qt6Qml Qt6Gui Qt6Core"
export PKG_CONFIG_PATH=$HERE/pkgconfig

generate() {
    (cd "$DSIDE" && ./xiboca/xiboca "$SPEC")
}

build_d() {
    mkdir -p "$BUILD"
    rm -rf "$BUILD/od_ldc2" && mkdir -p "$BUILD/od_ldc2"
    (cd "$GEN" && ldc2 -conf="$CONF" -mtriple=$TRIPLE -relocation-model=pic -O -c -oq \
        -od="$BUILD/od_ldc2" -I. $(find . -name '*.d'))
    rm -f "$BUILD/libbinding_ldc2.a"
    "$NDK_BIN/llvm-ar" rcs "$BUILD/libbinding_ldc2.a" "$BUILD"/od_ldc2/*.o
    echo "-> $BUILD/libbinding_ldc2.a"
}

build_shims() {
    mkdir -p "$BUILD"
    rm -rf "$BUILD/ocpp" && mkdir -p "$BUILD/ocpp"
    CFLAGS=$(pkg-config --cflags $MODS)
    # the spec's include_paths: the private-header dirs of every module, for every unit
    INC=$(python3 -c "import json,sys; print(' '.join('-I'+p for p in json.load(open(sys.argv[1]))['include_paths']))" "$SPEC")
    CXX="$CFLAGS $INC -std=c++17 -fPIC -O2 -ffunction-sections -fdata-sections"
    echo yes > "$BUILD/qml-enabled"
    for c in "$GEN"/*.cpp; do
        b=$(basename "$c" .cpp)
        case "$b" in qtdmoc|qtdmoc_qml) EX="-DQTD_ENABLE_QML";; *) EX=;; esac
        "$NDK_BIN/clang++" $CXX $EX -c "$c" -o "$BUILD/ocpp/$b.o"
    done
    rm -f "$BUILD/libshims.a"
    "$NDK_BIN/llvm-ar" rcs "$BUILD/libshims.a" "$BUILD"/ocpp/*.o
    echo "-> $BUILD/libshims.a"
}

case "${1:-all}" in
    generate) generate ;;
    d) build_d ;;
    shims) build_shims ;;
    all) [ -d "$GEN" ] || generate; build_d; build_shims ;;
    *) echo "usage: $0 [generate|d|shims|all]" >&2; exit 2 ;;
esac
