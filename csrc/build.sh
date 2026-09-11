#!/bin/sh
# Compiles the C++ files of the project (the face and CLIP shims over OpenCV) into
# csrc/libface_opencv.a. Run by dub (preBuildCommands); skipped when the archive is
# newer than the sources.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
fresh=1
for f in face_opencv.cpp face_opencv.h clip_opencv.cpp clip_opencv.h; do
    [ libface_opencv.a -nt "$f" ] || fresh=0
done
[ $fresh = 1 ] && exit 0
PKG=${OPENCV_PC:-opencv5}
pkg-config --exists "$PKG" || { echo "csrc: pkg-config cannot find $PKG (set OPENCV_PC)" >&2; exit 1; }
${CXX:-g++} -std=c++17 -O2 -fPIC $(pkg-config --cflags "$PKG") -c face_opencv.cpp -o face_opencv.o
${CXX:-g++} -std=c++17 -O2 -fPIC $(pkg-config --cflags "$PKG") -c clip_opencv.cpp -o clip_opencv.o
rm -f libface_opencv.a
ar rcs libface_opencv.a face_opencv.o clip_opencv.o
echo "csrc: built libface_opencv.a"
