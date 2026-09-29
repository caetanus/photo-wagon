#!/bin/sh
# Clones the sibling repositories photo-wagon builds against (dub.sdl names them as ../<dir>)
# next to this checkout, at the refs pinned in packaging/versions.env. A directory that already
# exists is left alone, so a developer tree is never touched.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/versions.env"
TOP=$(cd "$HERE/../.." && pwd)

clone() {   # <url> <ref> <dir>
    if [ -d "$TOP/$3/.git" ]; then
        echo "fetch-sources: $3 already present, left as is"
        return
    fi
    git clone --quiet --depth 1 --branch "$2" "$1" "$TOP/$3"
    echo "fetch-sources: $3 @ $(git -C "$TOP/$3" rev-parse --short HEAD)"
}
clone "$DSIDE_REPO" "$DSIDE_REF" qt-dlang-gen
clone "$HYPERSWARM_REPO" "$HYPERSWARM_REF" d-hyperswarm
clone "$LIBP2P_REPO" "$LIBP2P_REF" libp2p-dlang
clone "$WEBRTC_REPO" "$WEBRTC_REF" d-webrtc-v3
clone "$QMLCSS_REPO" "$QMLCSS_REF" qml-css-engine
