#!/bin/sh
# Builds the Photo Wagon UI (D + DSide, Qt Quick) against the already-generated
# cxx-quick binding. The link line follows reggae/qtd_build.d:1305 (qtdApp): both
# archives inside --start-group, the generated dir on -I, Qt via pkg-config.
# -J lets qrcRegister read qml/ui.qrc and every file it lists at compile time.
set -e

DSIDE=${DSIDE:-$HOME/lab/qt-dlang-gen}
QT=${QT:-qt-6.11}
SPEC=cxx-quick
DC=${DC:-ldc2}
HERE=$(cd "$(dirname "$0")" && pwd)

GEN="$DSIDE/generated/$QT/$SPEC"
BUILD="$DSIDE/.build/$QT-$SPEC"

[ -d "$GEN" ]                    || { echo "binding not generated: $GEN" >&2; exit 1; }
[ -f "$BUILD/libbinding_$DC.a" ] || { echo "archive missing: $BUILD/libbinding_$DC.a" >&2; exit 1; }

LIBS=$(pkg-config --libs Qt6Quick Qt6QmlModels Qt6Qml Qt6Gui Qt6Network Qt6Core | sed 's/-l/-L-l/g')

# Compiled from inside ui/ so __FILE__ paths stay relative.
cd "$HERE"

exec "$DC" -of=photo-wagon \
    source/app.d source/backend.d source/client.d \
    -I"$GEN" \
    -I"$DSIDE/runtime/qrc" \
    -Isource \
    -J=qml \
    -L--gc-sections -L--as-needed \
    -L--start-group \
      -L="$BUILD/libbinding_$DC.a" \
      -L="$BUILD/libshims.a" \
    -L--end-group \
    $LIBS -L-lstdc++
