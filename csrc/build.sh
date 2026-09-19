#!/bin/sh
# Compiles the C/C++ files of the project (the face and CLIP shims over OpenCV, sqlite-vec) into
# csrc/libface_opencv.a. Run by dub (preBuildCommands); skipped when the archive is
# newer than the sources.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

# The "node" sync-hub build (PW_NO_OPENCV): sqlite-vec only, no OpenCV face/CLIP shims.
# Produces libface_novision.a so it never clashes with the full libface_opencv.a.
if [ -n "${PW_NO_OPENCV:-}" ]; then
    if [ libface_novision.a -nt sqlite-vec.c ] && [ libface_novision.a -nt sqlite-vec.h ]; then
        exit 0
    fi
    ${CC:-gcc} -std=gnu11 -O2 -fPIC -c sqlite-vec.c -o sqlite-vec.o
    rm -f libface_novision.a
    ar rcs libface_novision.a sqlite-vec.o
    echo "csrc: built libface_novision.a (sqlite-vec only, no OpenCV)"
    exit 0
fi
fresh=1
for f in face_opencv.cpp face_opencv.h clip_opencv.cpp clip_opencv.h ocr_tesseract.cpp ocr_tesseract.h sqlite-vec.c sqlite-vec.h clipboard_qt.cpp clipboard_qt.h; do
    [ libface_opencv.a -nt "$f" ] || fresh=0
done
[ $fresh = 1 ] && exit 0
PKG=${OPENCV_PC:-opencv5}
pkg-config --exists "$PKG" || { echo "csrc: pkg-config cannot find $PKG (set OPENCV_PC)" >&2; exit 1; }
${CXX:-g++} -std=c++17 -O2 -fPIC $(pkg-config --cflags "$PKG") -c face_opencv.cpp -o face_opencv.o
${CXX:-g++} -std=c++17 -O2 -fPIC $(pkg-config --cflags "$PKG") -c clip_opencv.cpp -o clip_opencv.o
# OCR (Tesseract): reads text in screenshots / memes / documents. Independent of OpenCV.
if pkg-config --exists tesseract; then
    ${CXX:-g++} -std=c++17 -O2 -fPIC $(pkg-config --cflags tesseract lept) -c ocr_tesseract.cpp -o ocr_tesseract.o
else
    echo "csrc: pkg-config cannot find tesseract — OCR will be off" >&2
    rm -f ocr_tesseract.o
fi
# sqlite-vec (vector search inside SQLite): a loadable extension compiled in and registered
# by core/db/sqlite.d through sqlite3_auto_extension
${CC:-gcc} -std=gnu11 -O2 -fPIC -c sqlite-vec.c -o sqlite-vec.o
rm -f libface_opencv.a
ar rcs libface_opencv.a face_opencv.o clip_opencv.o sqlite-vec.o $([ -f ocr_tesseract.o ] && echo ocr_tesseract.o)
# the clipboard shim needs Qt: a separate archive, linked by the "app" configuration only
if pkg-config --exists Qt6Gui; then
    ${CXX:-g++} -std=c++17 -O2 -fPIC $(pkg-config --cflags Qt6Gui Qt6Core) -c clipboard_qt.cpp -o clipboard_qt.o
    rm -f libclipboard_qt.a
    ar rcs libclipboard_qt.a clipboard_qt.o
fi
echo "csrc: built libface_opencv.a"
