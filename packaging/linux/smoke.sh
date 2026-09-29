#!/bin/sh
# Proves a built package on a fresh system of its distribution, in two steps:
#
#   packaging/linux/smoke.sh install <package-file>   # with network: the distribution's package
#                                                     # manager has to resolve every dependency
#   packaging/linux/smoke.sh run [shot.png]           # WITHOUT network: no unresolved library,
#                                                     # and the real UI loads and photographs itself
#
# The run step is meant for a container started with --network=none: a CI machine has no
# business joining the public DHT, and the headless capture does not complete while the node
# is online (open investigation), so the check is deterministic only offline.
set -eu
. /etc/os-release
case "${1:-}" in
install)
    PKG=$(readlink -f "$2")
    case "$ID" in
        debian|ubuntu)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq "$PKG" ;;
        fedora) dnf install -y -q "$PKG" ;;
        arch) pacman -Sy --noconfirm >/dev/null; pacman -U --noconfirm "$PKG" ;;
        *) echo "smoke: unknown distribution $ID" >&2; exit 1 ;;
    esac
    ;;
run)
    SHOT=${2:-/tmp/photo-wagon-smoke.png}
    missing=$(ldd /usr/bin/photo-wagon | grep 'not found' || true)
    [ -z "$missing" ] || { echo "smoke: unresolved libraries:"; echo "$missing"; exit 1; } >&2
    export HOME=/tmp/smoke-home
    mkdir -p "$HOME"
    rm -f "$SHOT"
    QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software PW_SHOT="$SHOT" \
        timeout 180 photo-wagon --data "$HOME/library" || { echo "smoke: photo-wagon exited with $?" >&2; exit 1; }
    [ -s "$SHOT" ] || { echo "smoke: the UI did not produce $SHOT" >&2; exit 1; }
    echo "smoke: ok ($ID ${VERSION_ID:-}; $(wc -c < "$SHOT") byte screenshot)"
    ;;
*)
    echo "usage: $0 install <package-file> | run [shot.png]" >&2; exit 2 ;;
esac
