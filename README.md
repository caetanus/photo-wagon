# Photo Wagon

Local-first photo manager written in D: a Qt Quick UI, an indexer, and a
libp2p node for sharing albums directly between machines, all in one program.

Everything runs on your computer. Nothing is uploaded anywhere unless you share
an album with a peer you chose.

## The desktop app

A Photos-style window: a source list (Library, Favorites, People, Imports;
the **years → months → days** tree with counts, one click to any day, the same
node again clears it; the named **people** with portraits and counts; Media
Types — Photos, Screenshots, Memes — albums, the phone and the peers; the
connection / indexing status in the footer), a toolbar with **Years / Months / Days / All
Photos**, a zoom slider and search, the grid (click selects, ⌘/Ctrl-click
extends, double-click opens, hover shows the heart), the viewer in place of the
grid with a caption line (date, camera, size, file), a filmstrip and an **ⓘ Info** panel (camera, size, folder, the people
in the photo with round portraits and "Name" for the unnamed ones), and a
People page with round portraits. Light or dark follows the system.

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

## Phone

`mobile/` is Photo Wagon on the phone: it shows the phone's own photos and
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
