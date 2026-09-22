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
    SRC="$DUBP/$d/source"
    # VIBE_CORE_SRC=<dir>: build against a patched copy of vibe-core's source tree instead of the
    # dub package (a debugging aid — e.g. a more talkative assert); never the default.
    case "$d" in vibe-core-*) [ -n "${VIBE_CORE_SRC:-}" ] && SRC="$VIBE_CORE_SRC" && echo "vibe-core: using $SRC" ;; esac
    [ -d "$SRC" ] || { echo "missing dub package $d (run dub build in mobile/ once)" >&2; exit 1; }
    P2P_INCLUDES="$P2P_INCLUDES -I$SRC"
    P2P_SOURCES="$P2P_SOURCES $(find "$SRC" -name '*.d')"
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
# EXTRA_DVERSIONS="-d-version=X …": extra version identifiers for a diagnostic build (e.g. the
# lib's -d-version=Libp2pReadTrace wire tracing).
# QUIC (/quic-v1) as a libp2p transport: libp2p's transport/quic/*.d (version Libp2pQuic)
# over ngtcp2 with its OpenSSL crypto backend. Needs, in toolchain/android-libs/<abi>/,
# libngtcp2.a + libngtcp2_crypto_ossl.a and an OpenSSL >= 3.5 libssl.a/libcrypto.a (the
# QUIC TLS API; see ANDROID.md for the cross-build). On when all four are present;
# PW_NO_QUIC=1 leaves the transport out (the phone then dials TCP+Noise only).
QUIC_VERSION=""
QUIC_INCLUDES=""
QUIC_SOURCES=""
QUIC_LIBS=""
if [ -z "${PW_NO_QUIC:-}" ]; then
    QUIC_OK=1
    for a in libngtcp2.a libngtcp2_crypto_ossl.a libssl.a libcrypto.a; do
        [ -e "$HERE/toolchain/android-libs/$ABI_DIR/$a" ] || { echo "QUIC: $a missing for $ABI_DIR — transport left out" >&2; QUIC_OK=""; }
    done
    if [ -n "$QUIC_OK" ]; then
        OPENSSL_DI=$(ls -d "$DUBP"/openssl-3.4.0/openssl/source 2>/dev/null | head -1)
        [ -n "$OPENSSL_DI" ] || { echo "QUIC: the deimos openssl-3.4.0 binding is not under $DUBP" >&2; exit 1; }
        # DeimosOpenSSL_3_0: the binding's version switch. Without it the .di files assume
        # OpenSSL 1.1 and declare SSL_get_peer_certificate, which 3.x only has as
        # SSL_get1_peer_certificate (the binding aliases it under 3.0) — an undefined symbol.
        QUIC_VERSION="-d-version=Libp2pQuic -d-version=DeimosOpenSSL_3_0"
        # quic/punch.d reuses the STUN message codec of d-webrtc-v3 (std + libsodium only) for
        # its server-reflexive address; the rest of the webrtc transport stays out of this build.
        WEBRTC_SRC=$HERE/../../d-webrtc-v3/source
        [ -e "$WEBRTC_SRC/webrtc/stun/message.d" ] || { echo "QUIC: $WEBRTC_SRC/webrtc/stun/message.d missing (clone d-webrtc-v3 next to photo-wagon)" >&2; exit 1; }
        # The deimos modules must be COMPILED in, not only imported: the quic modules'
        # ModuleInfo lists them (they carry inline helpers), so their ModuleInfo has to exist
        # at link time. LDC generates no code for a .di on the command line, so the binding
        # is copied to .d files under $OUT and those are compiled (applink is Windows glue).
        DEIMOS_COPY=$OUT/deimos-openssl
        rm -rf "$DEIMOS_COPY"
        mkdir -p "$DEIMOS_COPY/deimos/openssl"
        for f in "$OPENSSL_DI"/deimos/openssl/*.di; do
            b=$(basename "$f" .di)
            [ "$b" = applink ] || cp "$f" "$DEIMOS_COPY/deimos/openssl/$b.d"
        done
        QUIC_INCLUDES="-I$DEIMOS_COPY -I$WEBRTC_SRC"
        QUIC_SOURCES="$WEBRTC_SRC/webrtc/stun/message.d $(find "$DEIMOS_COPY" -name '*.d')"
        # start-group: crypto_ossl → ngtcp2 + ssl, ssl ↔ crypto; let the linker resolve all ways.
        QUIC_LIBS="-L--start-group -L=$HERE/toolchain/android-libs/$ABI_DIR/libngtcp2_crypto_ossl.a -L=$HERE/toolchain/android-libs/$ABI_DIR/libngtcp2.a -L=$HERE/toolchain/android-libs/$ABI_DIR/libssl.a -L=$HERE/toolchain/android-libs/$ABI_DIR/libcrypto.a -L--end-group"
        echo "QUIC: transport ON (ngtcp2 + OpenSSL for $ABI_DIR)"
    fi
fi
# Optional, PW_UDX=1: the UDX/hyperswarm sync transport (Holepunch stack) — parked, its
# relayed hole punch never passed live acceptance. Two archives dropped into
# toolchain/android-libs/<abi>/ by the d-hyperswarm build: libhsudx-android.a (the libudx C
# core, compiled as plain C with the NDK clang) and libhsdswarm-android.a (the D side:
# facade.d's hsuv_* libuv shim + hyperswarm/dht/noise + the Connection surface). Linked
# inside the start-group so the shim and the core resolve each other; the nm pre-flight
# below aborts on any hsuv_*/udx_* left unresolved.
# PW_HS=1 builds the udx/hyperdht/hyperswarm FLAVOR in (a selectable second transport; at
# runtime it is chosen by files/settings/hs-flavor). It adds -d-version=PwHyperswarm, the
# transport source (hswarm.d), the mux + piece protocol, the d-hyperswarm include path, and
# links the two archives. PW_UDX is the old alias.
UDX_LIBS=""
HS_VERSION=""
HS_SOURCES=""
HS_INCLUDES=""
if [ -n "${PW_HS:-}${PW_UDX:-}" ]; then
    for a in libhsudx-android.a libhsdswarm-android.a; do
        [ -e "$HERE/toolchain/android-libs/$ABI_DIR/$a" ] || { echo "PW_HS: $a missing for $ABI_DIR (run d-hyperswarm ARCH=$ABI_DIR build scripts)" >&2; exit 1; }
        UDX_LIBS="$UDX_LIBS -L=$HERE/toolchain/android-libs/$ABI_DIR/$a"
    done
    HS_VERSION="-d-version=PwHyperswarm"
    HS_INCLUDES="-I$HERE/../../d-hyperswarm/source"
    HS_SOURCES="../source/photowagon/core/p2p/hswarm.d ../source/photowagon/core/sync/muxstream.d"
    echo "PW_HS: hyperswarm flavor ON for $ABI_DIR:$UDX_LIBS"
fi
# UDX_WHOLE=1: force every member of the two archives into the .so (--whole-archive). Until
# P2pBridge references the hyperswarm API nothing pulls them in, so the nm pre-flight would
# be vacuously green; with the whole archives linked, "0 unresolved" is a real static proof
# that dlopen on the phone will succeed. A debug knob — normal builds let --gc-sections trim.
if [ -n "$UDX_LIBS" ] && [ -n "${UDX_WHOLE:-}" ]; then
    UDX_LIBS="-L--whole-archive $UDX_LIBS -L--no-whole-archive"
    echo "UDX: --whole-archive forced (UDX_WHOLE=1) for a dlopen-readiness proof"
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
    "$LDC" -conf="$LDC_CONF" -mtriple=$TRIPLE -shared -relocation-model=pic -O -g -lowmem \
        -d-version=PhotoWagonMobile \
        -of="$OUT/lib${APP}_${ABI}.so" \
        source/photowagon/mobile/main.d source/photowagon/mobile/plog.d source/photowagon/mobile/tcpbridge.d \
        source/photowagon/mobile/p2pbridge.d \
        source/photowagon/mobile/localbridge.d source/photowagon/mobile/phoneindex.d \
        ../source/photowagon/ui/backend.d ../source/photowagon/ui/transport.d ../source/photowagon/ui/bridge.d \
        ../source/photowagon/core/ipc/link.d ../source/photowagon/core/p2p/identity.d \
        $P2P_SOURCES $QUIC_SOURCES $HS_SOURCES -d-version=LibP2P_Lite -d-version=EventcoreEpollDriver $TLS_VERSION $QUIC_VERSION $HS_VERSION ${EXTRA_DVERSIONS:-} $P2P_INCLUDES $TLS_INCLUDES $QUIC_INCLUDES $HS_INCLUDES \
        ../source/photowagon/core/indexer/scan.d ../source/photowagon/core/library/calendar.d ../source/photowagon/core/jobs/memguard.d \
        ../source/photowagon/core/library/kind.d ../source/photowagon/core/thumbs/imagestats.d \
        ../source/photowagon/core/metadata/exifparse.d ../source/photowagon/core/metadata/datefromname.d \
        ../source/photowagon/core/pairingcode.d ../source/photowagon/core/sync/pieces.d \
        "$DSIDE/runtime/qrc/qrc.d" \
        -Isource -I../source -I"$GEN" -I"$DSIDE/runtime/qrc" -J=../qml \
        -L--gc-sections -L--as-needed \
        -L--start-group -L="$BUILD/libbinding_ldc2.a" -L="$BUILD/libshims.a" -L--end-group \
        -L="$OUT/videothumb_$ABI.o" \
        -L--start-group $UDX_LIBS -L="$HERE/toolchain/android-libs/$ABI_DIR/libsodium.a" -L--end-group \
        $TLS_LIBS $QUIC_LIBS \
        -L-L"$QT_ANDROID/lib" \
        -L-lQt6Quick_${ABI} -L-lQt6QmlModels_${ABI} -L-lQt6Qml_${ABI} -L-lQt6Network_${ABI} \
        -L-lQt6Gui_${ABI} -L-lQt6Core_${ABI} \
        -L-lc++_shared -L-llog -L-landroid
    NM_BIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-nm"
    "$NM_BIN" -D "$OUT/lib${APP}_${ABI}.so" | grep -q ' T main$'
    # pre-flight: catch symbols Android's bionic does not provide (glibc-only) HERE, as an
    # abort, instead of as a "cannot locate symbol" dlopen crash on the phone. (2026-09-19:
    # memguard's mallinfo2/malloc_trim did exactly that.) Also abort on any udx_*/hsuv_*
    # left UNRESOLVED: the udx transport (libhsudx-android.a) and its libuv shim (facade.d)
    # must be fully linked in — a missing shim symbol would otherwise only show up as a
    # dlopen crash on the device.
    # …and on unresolved libsodium (crypto_*/sodium_*): the dswarm archive leans on it, so a
    # link-order slip would otherwise pass here and die at dlopen on the phone.
    BAD=$("$NM_BIN" -D -u "$OUT/lib${APP}_${ABI}.so" | grep -oE 'mallinfo2|malloc_trim|malloc_stats|malloc_info|secure_getenv|\<pthread_cancel\>|\<__d_hsuv_[A-Za-z0-9_]+|\<hs_udx_[A-Za-z0-9_]+|\<udx_[A-Za-z0-9_]+|\<crypto_[A-Za-z0-9_]+|\<sodium_[A-Za-z0-9_]+' | sort -u | tr '\n' ' ')
    [ -n "$BAD" ] && { echo "ABORT: libphotowagon has symbols bionic lacks or unresolved udx/hsuv/libsodium symbols: $BAD" >&2; exit 1; }
    # …and, generically, on ANY undefined symbol that carries no library version tag and is
    # not C++-mangled: bionic/liblog/libandroid exports are versioned (foo@LIBC), Qt and
    # libc++ are _Z-mangled, GLES2 comes as gl* through Qt, libc++abi as __cxa*/__dynamic_cast/
    # _Unwind_*. Anything else is a plain C symbol nothing provides — exactly the dlopen crash
    # this pre-flight exists to prevent (2026-09-20: win_filter_reset, a libudx file left out
    # of the arm64 archive, slipped past the prefix list above and killed the app at launch).
    LOOSE=$("$NM_BIN" -D -u "$OUT/lib${APP}_${ABI}.so" | awk '{print $NF}' \
        | grep -vE '@|^_Z|^__cxa|^__gxx|^__dynamic_cast|^_Unwind_|^__gcc_personality|^__gnu_|^__android_log_|^gl[A-Z]' \
        | sort -u | tr '\n' ' ')
    [ -n "$LOOSE" ] && { echo "ABORT: libphotowagon has undefined symbols no library provides (would fail at dlopen): $LOOSE" >&2; exit 1; }
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
