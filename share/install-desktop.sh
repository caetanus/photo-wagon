#!/bin/sh
# Installs the launcher entry and the icon for the current user, so the desktop
# (Wayland compositors included) shows the Photo Wagon icon for the window and
# in the application menu. Re-run after moving the binary.
set -e
here=$(cd "$(dirname "$0")" && pwd)
exe=${1:-$here/../photo-wagon}
exe=$(cd "$(dirname "$exe")" && pwd)/$(basename "$exe")
data=${XDG_DATA_HOME:-$HOME/.local/share}
mkdir -p "$data/applications" "$data/icons/hicolor/scalable/apps"
for s in 48 128 256 512; do
  mkdir -p "$data/icons/hicolor/${s}x${s}/apps"
  cp "$here/icon-$s.png" "$data/icons/hicolor/${s}x${s}/apps/photo-wagon.png"
done
cp "$here/photo-wagon.svg" "$data/icons/hicolor/scalable/apps/photo-wagon.svg"
sed "s|@EXEC@|$exe|" "$here/photo-wagon.desktop" > "$data/applications/photo-wagon.desktop"
command -v update-desktop-database >/dev/null && update-desktop-database "$data/applications" || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -q -t "$data/icons/hicolor" 2>/dev/null || true
echo "installed $data/applications/photo-wagon.desktop → $exe"
