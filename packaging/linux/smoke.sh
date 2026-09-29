#!/bin/sh
# Installs a built package into this (fresh) container with the distribution's own package
# manager — so every dependency it declares has to resolve — and proves the app starts: no
# unresolved library, and the real UI loads and photographs itself offscreen.
#
#   packaging/linux/smoke.sh <package-file> [shot.png]
set -eu
PKG=$(readlink -f "$1")
SHOT=${2:-/tmp/photo-wagon-smoke.png}
. /etc/os-release
case "$ID" in
    debian|ubuntu)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y -qq "$PKG" ;;
    fedora) dnf install -y -q "$PKG" ;;
    arch) pacman -Sy --noconfirm >/dev/null; pacman -U --noconfirm "$PKG" ;;
    *) echo "smoke: unknown distribution $ID" >&2; exit 1 ;;
esac

missing=$(ldd /usr/bin/photo-wagon | grep 'not found' || true)
[ -z "$missing" ] || { echo "smoke: unresolved libraries:"; echo "$missing"; exit 1; } >&2

export HOME=/tmp/smoke-home
mkdir -p "$HOME"
rm -f "$SHOT"
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software PW_SHOT="$SHOT" \
    timeout 300 photo-wagon --data "$HOME/library" || { echo "smoke: photo-wagon exited with $?" >&2; exit 1; }
[ -s "$SHOT" ] || { echo "smoke: the UI did not produce $SHOT" >&2; exit 1; }
echo "smoke: ok ($ID ${VERSION_ID:-}; $(wc -c < "$SHOT") byte screenshot)"
