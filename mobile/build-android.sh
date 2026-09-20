#!/bin/sh
# Builds the mobile app for Android arm64, packages it, installs and launches it
# on the attached phone.
#   ./build-android.sh          link + package + install + launch
#   ./build-android.sh link     just libphotowagon_arm64-v8a.so
#   ./build-android.sh package  the APK
#   ./build-android.sh run      install + launch + screenshot + logcat excerpt
#
# Prerequisites (see ../ANDROID.md): the LDC Android runtime referenced by
# toolchain/ldc2-android.conf, the DSide binding for the Qt Android kit
# (toolchain/build-binding.sh all), Qt 6.11 android_arm64_v8a + gcc_64 kits,
# SDK with NDK 27 and platform 36, JDK 17.
set -e

HERE=$(cd "$(dirname "$0")" && pwd)
DSIDE=${DSIDE:-$HOME/lab/qt-dlang-gen}
LDC_CONF=${LDC_CONF:-$HERE/toolchain/ldc2-android.conf}
# Android is pinned to LDC 1.42 (see ldc2-android.conf): the 1.42 device runtime, so the
# compiler must be 1.42 too. The host's PATH ldc2 may be newer (1.43+) and would emit
# druntime symbols the 1.42 runtime / the device lacks. Override with LDC= if needed.
LDC=${LDC:-$HOME/lab/android-d/ldc2-1.42.0-linux-x86_64/bin/ldc2}
# ABI=arm64-v8a (the phone, default) or ABI=x86_64 (the emulator; see ANDROID.md)
ABI=${ABI:-arm64-v8a}
case "$ABI" in
    arm64-v8a) TRIPLE=aarch64-linux-android; KIT=android_arm64_v8a; ABI_DIR=arm64;  BINDING=qt-6.11-android-arm64-cxx-quick ;;
    x86_64)    TRIPLE=x86_64-linux-android;  KIT=android_x86_64;    ABI_DIR=x86_64; BINDING=qt-6.11-android-x86_64-cxx-quick ;;
    *) echo "ABI must be arm64-v8a or x86_64" >&2; exit 2 ;;
esac
QT_ANDROID=${QT_ANDROID:-$HOME/Qt/6.11.1/$KIT}
QT_HOST=${QT_HOST:-$HOME/Qt/6.11.1/gcc_64}
NDK=${NDK:-/opt/android-sdk/ndk/27.2.12479018}
export ANDROID_SDK_ROOT=${ANDROID_SDK_ROOT:-/opt/android-sdk}
export JAVA_HOME=${JAVA_HOME:-/usr/lib/jvm/java-17-openjdk}
GEN=$DSIDE/generated/qt-6.11-android-arm64/cxx-quick
BUILD=$DSIDE/.build/$BINDING
APP=photowagon          # lib${APP}_${ABI}.so, the name QtActivity loads
OUT=$HERE/build-android
[ "$ABI" = arm64-v8a ] || OUT=$HERE/build-android/$ABI
PKG_NAME=org.photowagon.mobile

for p in "$LDC_CONF" "$BUILD/libbinding_ldc2.a" "$BUILD/libshims.a" "$GEN/cxxrt.d"; do
    [ -e "$p" ] || { echo "missing: $p (see ../ANDROID.md)" >&2; exit 1; }
done
mkdir -p "$OUT"

# libp2p (lite: no webrtc transport, no c-ares), vibe-core, eventcore and the
# libsodium binding, as sources; libsodium itself is the archive in toolchain/android-libs.
DUBP=$HOME/.dub/packages
LIBP2P=$HERE/../../libp2p-dlang/source
P2P_INCLUDES="-I$LIBP2P"
P2P_SOURCES=$(find "$LIBP2P" -name '*.d' | grep -v '/transport/webrtc/' | grep -v 'dns_cares.d')
for d in eventcore-0.9.39/eventcore vibe-core-2.14.0/vibe-core vibe-container-1.7.1/vibe-container taggedalgebraic-1.0.1/taggedalgebraic stdx-allocator-2.77.5/stdx-allocator libsodiumd-0.2.0_1.0.18/libsodiumd; do
    [ -d "$DUBP/$d/source" ] || { echo "missing dub package $d (run dub build in mobile/ once)" >&2; exit 1; }
    P2P_INCLUDES="$P2P_INCLUDES -I$DUBP/$d/source"
    P2P_SOURCES="$P2P_SOURCES $(find "$DUBP/$d/source" -name '*.d')"
done
# Optional: WSS-to-relay. The public libp2p relays are /dns4/.../tls/ws only, so the phone
# needs a TLS-over-WebSocket transport to reach them. Off by default (plain /ws is compiled
# in either way). P2P_TLS=1 turns WSS on: it compiles libp2p's ws_tls_openssl.d (guarded by
# version LibP2P_OpensslTls), adds the deimos openssl binding to the include path, and links
# the arm64 libssl/libcrypto archives cross-built into toolchain/android-libs (see ANDROID.md).
# The security is still Noise (which authenticates the peer); the WSS TLS is transport compat,
# so the provider uses verify_none — no CA trust store on the phone.
TLS_VERSION=""
TLS_INCLUDES=""
TLS_LIBS=""
if [ -n "${P2P_TLS:-}" ]; then
    OPENSSL_DI=$(ls -d "$DUBP"/openssl-3.4.0/openssl/source 2>/dev/null | head -1)
    [ -n "$OPENSSL_DI" ] || { echo "P2P_TLS set but the deimos openssl-3.4.0 binding is not under $DUBP" >&2; exit 1; }
    for a in libssl.a libcrypto.a; do
        [ -e "$HERE/toolchain/android-libs/$ABI_DIR/$a" ] || { echo "P2P_TLS set but $a is missing for $ABI_DIR (cross-build openssl, see ANDROID.md)" >&2; exit 1; }
    done
    TLS_VERSION="-d-version=LibP2P_OpensslTls"
    TLS_INCLUDES="-I$OPENSSL_DI"
    # start-group: libssl references libcrypto and vice-versa; let the linker resolve both ways.
    TLS_LIBS="-L--start-group -L=$HERE/toolchain/android-libs/$ABI_DIR/libssl.a -L=$HERE/toolchain/android-libs/$ABI_DIR/libcrypto.a -L--end-group"
    echo "P2P_TLS: WSS-to-relay ON (deimos $OPENSSL_DI + arm64 libssl/libcrypto)"
fi
link() {
    # -shared: Qt for Android loads lib<app>_<abi>.so and calls its exported main().
    # -relocation-model=pic: everything in a .so must be PIC (the binding archive was built so too).
    # qrc.d is compiled in (not only imported) or the link wants "ModuleInfo for qrc".
    cd "$HERE"
    # videothumb.c: Android video frame thumbnails via JNI (MediaMetadataRetriever).
    # Compiled with the NDK clang for this ABI/API and linked into the .so below.
    CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/${TRIPLE}35-clang"
    "$CC" -c -fPIC -O2 "$HERE/jni/videothumb.c" -o "$OUT/videothumb_$ABI.o"
    "$LDC" -conf="$LDC_CONF" -mtriple=$TRIPLE -shared -relocation-model=pic -O -lowmem \
        -d-version=PhotoWagonMobile \
        -of="$OUT/lib${APP}_${ABI}.so" \
        source/photowagon/mobile/main.d source/photowagon/mobile/plog.d source/photowagon/mobile/tcpbridge.d \
        source/photowagon/mobile/p2pbridge.d \
        source/photowagon/mobile/localbridge.d source/photowagon/mobile/phoneindex.d \
        ../source/photowagon/ui/backend.d ../source/photowagon/ui/transport.d ../source/photowagon/ui/bridge.d \
        ../source/photowagon/core/ipc/link.d ../source/photowagon/core/p2p/identity.d \
        $P2P_SOURCES -d-version=LibP2P_Lite -d-version=EventcoreEpollDriver $TLS_VERSION $P2P_INCLUDES $TLS_INCLUDES \
        ../source/photowagon/core/indexer/scan.d ../source/photowagon/core/library/calendar.d ../source/photowagon/core/jobs/memguard.d \
        ../source/photowagon/core/library/kind.d ../source/photowagon/core/thumbs/imagestats.d \
        ../source/photowagon/core/metadata/exifparse.d ../source/photowagon/core/metadata/datefromname.d \
        ../source/photowagon/core/pairingcode.d \
        "$DSIDE/runtime/qrc/qrc.d" \
        -Isource -I../source -I"$GEN" -I"$DSIDE/runtime/qrc" -J=../qml \
        -L--gc-sections -L--as-needed \
        -L--start-group -L="$BUILD/libbinding_ldc2.a" -L="$BUILD/libshims.a" -L--end-group \
        -L="$OUT/videothumb_$ABI.o" \
        -L="$HERE/toolchain/android-libs/$ABI_DIR/libsodium.a" \
        $TLS_LIBS \
        -L-L"$QT_ANDROID/lib" \
        -L-lQt6Quick_${ABI} -L-lQt6QmlModels_${ABI} -L-lQt6Qml_${ABI} -L-lQt6Network_${ABI} \
        -L-lQt6Gui_${ABI} -L-lQt6Core_${ABI} \
        -L-lc++_shared -L-llog -L-landroid
    NM_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm"
    "$NM_BIN" -D "$OUT/lib${APP}_${ABI}.so" | grep -q ' T main$'
    # pre-flight: catch symbols Android's bionic does not provide (glibc-only) HERE, as an
    # abort, instead of as a "cannot locate symbol" dlopen crash on the phone. (2026-09-19:
    # memguard's mallinfo2/malloc_trim did exactly that.)
    BAD=$("$NM_BIN" -D -u "$OUT/lib${APP}_${ABI}.so" | grep -oE 'mallinfo2|malloc_trim|malloc_stats|malloc_info|secure_getenv|\<pthread_cancel\>' | sort -u | tr '\n' ' ')
    [ -n "$BAD" ] && { echo "ABORT: libphotowagon references symbols bionic lacks: $BAD" >&2; exit 1; }
    echo "-> $OUT/lib${APP}_${ABI}.so (nm pre-flight ok)"
}

settings() {
    # Modelled on a qt-cmake generated deployment file; absolute paths are required.
    cat > "$OUT/android-deployment-settings.json" <<EOF
{
   "description": "androiddeployqt settings for Photo Wagon mobile (generated by build-android.sh)",
   "qt": { "$ABI": "$QT_ANDROID" },
   "qtDataDirectory": { "$ABI": "." },
   "qtLibExecsDirectory": { "$ABI": "libexec" },
   "qtLibsDirectory": { "$ABI": "lib" },
   "qtPluginsDirectory": { "$ABI": "plugins" },
   "qtQmlDirectory": { "$ABI": "qml" },
   "sdk": "$ANDROID_SDK_ROOT",
   "sdkBuildToolsRevision": "36.0.0",
   "ndk": "$NDK",
   "toolchain-prefix": "llvm",
   "tool-prefix": "llvm",
   "useLLVM": true,
   "toolchain-version": "clang",
   "ndk-host": "linux-x86_64",
   "abi": "$ABI",
   "architectures": { "$ABI": "$TRIPLE" },
   "android-legacy-packaging": true,
   "android-package-source-directory": "$HERE/android",
   "android-package-name": "$PKG_NAME",
   "android-app-name": "Photo Wagon",
   "android-version-name": "0.4.0",
   "android-version-code": "4",
   "permissions": [ { "name": "android.permission.INTERNET" } ],
   "application-binary": "$APP",
   "qml-root-path": [ "$HERE/../qml" ],
   "qml-importscanner-binary": "$QT_HOST/libexec/qmlimportscanner",
   "qml-dom-binary": "$QT_HOST/bin/qmldom",
   "rcc-binary": "$QT_HOST/libexec/rcc",
   "extraPrefixDirs": [ "$QT_ANDROID" ],
   "extraLibraryDirs": [ ],
   "zstdCompression": false,
   "generate-java-qtquickview-contents": false,
   "stdcpp-path": "$NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot/usr/lib/"
}
EOF
}

package() {
    settings
    mkdir -p "$OUT/pkg/libs/$ABI"
    cp "$OUT/lib${APP}_${ABI}.so" "$OUT/pkg/libs/$ABI/"
    # android-36: the androidx.core the Qt template pulls in requires compileSdk >= 36.
    "$QT_HOST/bin/androiddeployqt" --input "$OUT/android-deployment-settings.json" \
        --output "$OUT/pkg" --android-platform android-36 --gradle
    cp "$OUT/pkg/build/outputs/apk/debug/pkg-debug.apk" "$OUT/photo-wagon-mobile-debug.apk"
    echo "-> $OUT/photo-wagon-mobile-debug.apk"
}

run() {
    adb install -r "$OUT/photo-wagon-mobile-debug.apk"
    adb logcat -c
    adb shell am start -n "$PKG_NAME/.MainActivity"
    sleep 8
    adb exec-out screencap -p > "$OUT/phone.png"
    echo "-> $OUT/phone.png"
    adb logcat -d | grep -E 'bridge:|qml rootObjects|D qml|AndroidRuntime|FATAL|photowagon' | tail -20
}

case "${1:-all}" in
    link) link ;;
    package) package ;;
    run) run ;;
    all) link; package; run ;;
    *) echo "usage: $0 [link|package|run|all]" >&2; exit 2 ;;
esac
