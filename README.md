# Photo Wagon

Local-first photo manager written in D: a Qt Quick UI, an indexer, and a
libp2p node for sharing albums directly between machines, all in one program.

Everything runs on your computer. Nothing is uploaded anywhere unless you share
an album with a peer you chose.

## The desktop app

Dates come from EXIF, else from the file name or folder (WhatsApp, screenshots,
camera and Pixel names, `2020/02/13/` folders), and only then from the file's
modification time. A Photos-style window — the Library timeline shows photographs; screenshots
and memes live under Media Types (an album or a search shows everything) — with
a source list (Library, Favorites, People, Places, Imports;
the **years → months → days** tree with counts, one click to any day, the same
node again clears it; the named **people** with portraits and counts (right-click: show photos, rename, remove from People); Media
Types — Photos, Screenshots, Memes — albums, the phone and the peers; the
connection / indexing status in the footer), a toolbar with **Years / Months / Days / All
Photos**, a zoom slider and search, the grid (click selects, ⌘/Ctrl-click
extends, double-click opens, hover shows the heart), the viewer in place of the
grid with a caption line (date, camera, size, file), a filmstrip and an **ⓘ Info** panel (camera, size, folder, the people
in the photo with round portraits and "Name" for the unnamed ones; naming a
face lists the likely people first, then everyone alphabetically with their
portraits, narrowed as you type, ↑/↓ and Return pick one; "Use as portrait"
makes that face the person's picture; a right-click on a face offers to change
or rename the person, use the face as portrait, remove the tag, or mark it as
not a face), zoom (wheel, double-click, +/−/0,
drag) and full screen (F), a right-click menu on a photo or a selection
(copy the files, copy the paths, show in folder, favorite, add to an album,
set the place, mark as photo / screenshot / meme, move to the trash, delete permanently;
Delete and Shift+Delete do the last two from the keyboard), a
People page with round portraits, and a **Places** page: one card per city with
its newest photo and count, the cities listed in the sidebar too. A photo with a
GPS position lands in the nearest city (a compiled-in GeoNames table, offline;
a 0,0 position from a phone with location tags off counts as none); the others
get a place by hand — select, right-click, "Set Place…", which suggests your own
places first and then the world's cities as you type, or keeps any name you
enter. **Scenes and Moods**: every photograph is tagged by CLIP (ViT-B/32, zero-shot,
offline) with a scene — Beach, Pool, Snow, Mountains, Party, Birthday, Food, Pets, Baby,
Selfie, Night… — and a mood — Joyful, Calm, Romantic, Energetic, Nostalgic, Cozy,
Festive, Melancholic…, the weather — Sunny, Cloudy, Rainy, Stormy, Foggy, Snowy, Hot,
Cold — and the holiday: Christmas, New Year, Carnival, Easter, Halloween, Festa Junina,
Mother's / Father's / Children's / Valentine's Day come from the calendar (Brazilian
dates), Birthday, Wedding and Graduation from the picture. All four are sections of the
sidebar with counts, rows of the ⓘ Info panel (with the model's top guesses), and
submenus of the right-click menu to correct them (the vocabulary lives in
`data/scenes/labels.tsv`). Light or dark follows the system.

## Requirements

- `ldc2` (1.42+) or `dmd`, and `dub`
- Qt 6.11 with the DSide binding built at `../qt-dlang-gen`
  (`generated/qt-6.11/cxx-quick` + `.build/qt-6.11-cxx-quick/libbinding_ldc2.a`)
- `libp2p-dlang` checked out at `../libp2p-dlang` (and its sibling `d-webrtc-v3`)
- System libraries: `sqlite3`, `gexiv2`, `vips`, `libsodium`, `openssl`, `c-ares`,
  `qrencode`, OpenCV 5 (`opencv5.pc`; only for the face scan, see `csrc/`)
- The face models in `models/` (`face_detection_yunet_2023mar.onnx`,
  `face_recognition_sface_2021dec.onnx` from the OpenCV zoo); `--models DIR`
  points elsewhere

## Build and run

```sh
dub build --compiler=ldc2      # ./photo-wagon
./photo-wagon                   # data in ~/.local/share/photowagon
./photo-wagon --data /tmp/lib   # somewhere else
```

Without the Qt binding (a server, a TV box, CI):

```sh
dub build -c headless --compiler=ldc2   # ./photo-wagon-headless, core only
./photo-wagon --headless                # the full binary can do it too
```

Headless mode speaks the protocol of `docs/ipc.md` on loopback TCP and writes
the port to `$XDG_RUNTIME_DIR/photowagon/daemon.port`:

```sh
printf '{"id":1,"method":"daemon.hello"}\n' | nc 127.0.0.1 "$(cat "$XDG_RUNTIME_DIR/photowagon/daemon.port")"
```

The window and launcher icon: `sh share/install-desktop.sh` puts `photo-wagon.desktop`
and the icon under `~/.local/share` (Wayland compositors take the icon from there,
by the app id `photo-wagon`; X11 gets it from the binary itself).

The scene and mood tags need the CLIP image encoder next to the face models:
`models/clip_vision.onnx` is `onnx/vision_model.onnx` of
[Xenova/clip-vit-base-patch32](https://huggingface.co/Xenova/clip-vit-base-patch32)
(335 MB, fp32). Without it everything else works and the two sections stay empty.
`data/scenes/make-prompts.py` regenerates the text side after editing the vocabulary.

## Phone

`mobile/` is Photo Wagon on the phone: a libp2p peer of the computer's node
(the pairing QR carries its addresses), it keeps the computer up to date by itself
(a persistent queue, progress in an Android notification), shows the computer's
faces and names on the phone's own photos and names them back, shows the phone's own photos and
sends them to your computer's library. Click **Phone** on the computer, scan the
QR code with the app (⚙ → Scan QR code), then **Send all** or **Send to
computer** in the viewer. `mobile/build-android.sh` builds the arm64 APK,
installs it and launches it on the attached phone; `ANDROID.md` has the
toolchain and the pairing details. The same client builds for the desktop for
offscreen tests: `cd mobile && dub build -c desktop --compiler=ldc2`.

## Tests

```sh
dub test --compiler=ldc2                 # unit tests of every core module
tests/e2e.py /some/folder/with/nine/images   # two headless nodes: index, publish, fetch over libp2p
tests/faces.py /folder/with/the/lena+messi/set  # face detection, clustering, naming, merging
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software PW_SHOT=/tmp/shot.png ./photo-wagon   # UI screenshot
```

## Layout

```
source/photowagon/core/   indexer, store, SQLite, gexiv2, vips, faces, libp2p node, IPC
csrc/                     the one C++ file: OpenCV's YuNet + SFace behind a C surface
source/photowagon/ui/     app, Library facade, bridge to the core thread
source/photowagon/main.d  picks UI + core thread, or headless
mobile/                   the phone client (D, TcpBridge), Android packaging and toolchain
qml/                      the interface; qml/mobile/ the phone layout
docs/ipc.md               the line protocol between UI and core
tests/                    unit test runner, e2e.py
models/                   face-detection models (used from milestone 3 on)
legacy/                   the previous C++/Qt + D prototype, kept for reference only
```

See `ARCHITECTURE.md` for how the pieces fit and `ROADMAP.md` for what is done.
