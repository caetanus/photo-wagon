#!/bin/sh
# Compiles the one C++ file of the project into csrc/libface_opencv.a.
# Run by dub (preBuildCommands); skipped when the archive is newer than the sources.
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"
if [ libface_opencv.a -nt face_opencv.cpp ] && [ libface_opencv.a -nt face_opencv.h ]; then
    exit 0
fi
PKG=${OPENCV_PC:-opencv5}
pkg-config --exists "$PKG" || { echo "csrc: pkg-config cannot find $PKG (set OPENCV_PC)" >&2; exit 1; }
${CXX:-g++} -std=c++17 -O2 -fPIC $(pkg-config --cflags "$PKG") -c face_opencv.cpp -o face_opencv.o
rm -f libface_opencv.a
ar rcs libface_opencv.a face_opencv.o
echo "csrc: built libface_opencv.a"
