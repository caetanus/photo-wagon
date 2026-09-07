#!/bin/sh
# ./build.sh            both halves
# ./build.sh daemon     photowagond (dub, in daemon/)
# ./build.sh ui         photo-wagon (ldc2 against DSide, in ui/)
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
what=${1:-all}

build_daemon() {
    echo "== daemon"
    (cd "$HERE/daemon" && dub build ${DUB_BUILD:+--build=$DUB_BUILD})
}

build_ui() {
    echo "== ui"
    "$HERE/ui/build.sh"
}

case "$what" in
    daemon) build_daemon ;;
    ui)     build_ui ;;
    all)    build_daemon; build_ui ;;
    *) echo "usage: $0 [daemon|ui|all]" >&2; exit 2 ;;
esac
