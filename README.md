49 times... I've got her picture on my photo-wagon

<div align="center">
  <img src="docs/img/icon.png" width="128" alt="Photo Wagon icon">
  <h1>Photo Wagon</h1>
  <p><strong>A full photo library for Linux. Your photos, on your own devices.</strong></p>
</div>

Photo Wagon is a local-first photo app with an ambitious goal: become a
**feature-complete alternative to Google Photos and Apple Photos**, with
peer-to-peer sharing through **Hyperswarm** instead of cloud storage.

Linux is the priority. It deserves a photo app that makes a lifetime of pictures
easy to browse, search, organize, edit, and share. Photo Wagon also runs on
Windows and macOS, and has an Android companion. Building a great Linux photo
app on a cross-platform foundation means every platform benefits from that work.

**The goal is feature completeness; the project is still in active development.**
There is already a working library, editor, on-device analysis, and device sync.
The sections below describe what is available today and where work is ongoing.

<p align="center">
  <img src="docs/img/desktop.png" width="900" alt="Photo Wagon desktop library with a photo grid and sidebar for dates, people, places, and tags">
</p>
<p align="center"><sub>The real desktop app, browsing the demo library. All people and photos are AI-generated.</sub></p>

Try the [demo inside the app](docs/demo-photos/README.md): Lucy, Alice, Joe, Nina,
and Leo at the beach, by the pool, celebrating birthdays, going out, and on
vacation. It includes dated photos, named people, places, favorites, and albums.
After building the app and installing its face models:

```sh
python3 tools/demo.py --open
```

The demo creates its own library and settings, separate from your personal photos.

## What you can do today

- **Browse your library** by year, month, day, or moment, with favorites, albums,
  a zoomable grid, and a full-screen viewer.
- **Find people** with local face detection and clustering. Name people, correct
  matches, and choose their portraits.
- **Explore places** using offline GPS-to-city lookup, or add a place by hand.
- **Search your photos** by file name, tags, people, dates, and text recognized in
  images. With the CLIP models installed, search by meaning and find visually
  similar photos.
- **Organize automatically** with on-device scene, mood, and weather suggestions,
  holiday tags, and separate views for photos, screenshots, and memes.
- **Edit without replacing the original image**: filters, brightness, contrast,
  saturation, warmth, crop, rotate, and flip. Revert edits or save a copy.
- **Rediscover memories** through On This Day, throwbacks, and collections of
  people, places, and moments.
- **Bring your phone into the library** with QR pairing, resumable transfers, and
  people names shared between phone and desktop.
- **Show photos on a TV** through Google Cast or DLNA, including slideshows.

See the [desktop guide](docs/desktop.md) for controls, keyboard shortcuts,
metadata behavior, and details about each feature.

<p align="center">
  <img src="docs/img/people.png" width="900" alt="Photo Wagon People view with Lucy, Alice, Joe, Nina, and Leo and their photo counts">
</p>
<p align="center"><sub>The demo's recurring people, named in the actual library.</sub></p>

<p align="center">
  <img src="docs/img/viewer.png" width="900" alt="A beach photo of Lucy and Alice open in Photo Wagon, with the filmstrip and photo information">
</p>

## Your library stays yours

The library, thumbnails, face analysis, and search index live on your devices.
Browsing, organizing, editing, and running the local models do not require a
cloud account or a hosted photo service. Models are downloaded separately;
photo analysis then runs locally.

Adding a folder indexes the photos where they already live. Photo Wagon keeps
its database and derived files separately. It reads standard EXIF, XMP, and IPTC
metadata, and supports writing keywords back to XMP/IPTC so other applications
can use them. **Image edits are non-destructive; metadata writeback does modify
file metadata.** See [Tags](docs/desktop.md#tags) for that distinction.

Sharing is explicit: publish an album or pair a device to exchange photos.
Peer-to-peer sharing still needs connectivity between devices; it does not put
a permanent copy of your library on a hosted service.

### Hyperswarm and the current transport

Hyperswarm is the direction for peer discovery and device-to-device sharing.
The repository includes a D Hyperswarm integration, alongside the existing
libp2p transport.

**The migration is ongoing:** the current default still uses libp2p. The desktop
Hyperswarm path is experimental and enabled with `PW_HS=1`; the phone requires a
matching Hyperswarm build. This is not yet a completed transport replacement.
Both paths serve the same goal: sharing between your devices without a cloud
photo library.

## On your phone

<p align="center">
  <img src="docs/img/mobile.png" width="250" alt="Photo Wagon Android app showing the phone photo library">
  <img src="docs/img/android-people.png" width="250" alt="People and their portraits in the Android app">
  <img src="docs/img/android-viewer.png" width="250" alt="An AI-generated picnic photo open in the Android viewer">
</p>
<p align="center"><sub>The Android APK running in headless Waydroid, captured at 1080×2400 with the same AI-generated demo photos.</sub></p>

The Android app browses the camera roll, sends photos and videos to the desktop,
and brings the desktop's library and people names into the phone experience.
Transfers use a persistent queue with progress in an Android notification.

To pair, open **Phone** on the desktop and scan its QR code from the phone's
settings. Use **Send all** or **Send to computer** in the viewer to transfer photos.
The [Android guide](ANDROID.md) covers building, installing, pairing, and debugging.

## Build and run

The instructions below target Linux development. The build currently expects
several sibling repositories and native libraries; it is not yet a standalone
checkout-and-build setup. Desktop packaging and easier installation remain work
in progress.

### Dependencies

- **D compiler and build tool:** LDC (`ldc2`, 1.42+) and DUB. The desktop binding
  also has a DMD configuration.
- **Qt 6.11 and DSide:** `../qt-dlang-gen`, with the generated bindings under
  `generated/qt-6.11/cxx-quick` and the matching archives under
  `.build/qt-6.11-cxx-quick/` (`libbinding_ldc2.a` and `libshims.a` for LDC).
- **Networking:** `../libp2p-dlang` (and its sibling `d-webrtc-v3`) and
  `../d-hyperswarm`.
- **Desktop theming:** a built `qml-css-engine` at `~/lab/qml-css-engine`, or set
  `QMLCSS` to its location. The desktop configuration links `csrc/libcss.a`,
  produced from its `build/libqmlcssengine.a` by the native build script.
- **Native build tools:** a C/C++ toolchain and `pkg-config`.
- **System libraries:** SQLite, gexiv2, libvips, GLib/GObject, qrencode, libcurl,
  libsodium, c-ares, OpenSSL 3.5+, ngtcp2 with its OpenSSL backend, OpenCV 5,
  Tesseract, and Leptonica. The OpenCV pkg-config name defaults to `opencv5`;
  override it with `OPENCV_PC` if needed.

[dub.sdl](dub.sdl) and [csrc/build.sh](csrc/build.sh) define the build dependencies.

### Desktop

```sh
dub build --compiler=ldc2
QT_FORCE_STDERR_LOGGING=1 ./photo-wagon
```

Choose **Add Folder to Library…** to index an existing photo folder. On Linux,
app data defaults to `$XDG_DATA_HOME/photowagon`, or
`~/.local/share/photowagon` when `XDG_DATA_HOME` is unset. To use another location:

```sh
QT_FORCE_STDERR_LOGGING=1 ./photo-wagon --data /path/to/library-data
```

Install the desktop launcher and icon for your user with:

```sh
sh share/install-desktop.sh
```

### Local models

Put models in `models/` beside the executable, or choose a directory with
`--models DIR`.

| Feature | Model files |
| --- | --- |
| Face detection and recognition | `face_detection_yunet_2023mar.onnx`, `face_recognition_sface_2021dec.onnx` from the OpenCV Zoo |
| Scene suggestions and similar photos | `clip_vision.onnx` — the CLIP ViT-B/32 image encoder |
| Search by meaning | `clip_text.onnx` — the matching CLIP text encoder, in addition to the image encoder |

The CLIP files used by the project are `onnx/vision_model.onnx` and
`onnx/text_model.onnx` from
[Xenova/clip-vit-base-patch32](https://huggingface.co/Xenova/clip-vit-base-patch32),
using the fp32 versions, renamed as above. Without the CLIP models, ordinary
library browsing and text search still work; the corresponding visual analysis features are unavailable.
OCR uses Tesseract's installed language data.

### Headless

Run the core without the desktop UI, for example on an always-on device of your
own:

```sh
dub build -c headless --compiler=ldc2
./photo-wagon-headless
```

The full desktop binary also supports `--headless`. A smaller sync-node
configuration omits OpenCV and the vision features:

```sh
dub build -c node --compiler=ldc2
./photo-wagon-node
```

Headless mode exposes the [IPC protocol](docs/ipc.md) on loopback TCP. It writes
`daemon.port` under `$XDG_RUNTIME_DIR/photowagon`, falling back to the data
directory when `XDG_RUNTIME_DIR` is unset.

## Development

Photo Wagon is written in **D**, with a **Qt Quick** interface through DSide.
The desktop runs the UI on the main thread and a **vibe-core** event loop on a
second thread. SQLite stores the library; libvips handles image processing;
gexiv2 handles metadata; OpenCV and CLIP provide local image analysis.

The separate core thread is the current implementation. DSide supports a shared
Qt/vibe-core loop; the [integration investigation](docs/event-loop.md) documents
the working driver and the remaining migration requirements.

| Location | Responsibility |
| --- | --- |
| `source/photowagon/core/` | Indexing, database, storage, metadata, analysis, and peer networking |
| `source/photowagon/ui/` | Qt application, Library facade, and bridge to the core |
| `qml/` | Desktop interface, with phone components under `qml/mobile/` |
| `mobile/` | Phone client and Android build tooling |
| `csrc/` | Native library integration and embedded sqlite-vec |
| `tests/` | Core tests and integration scripts |
| `legacy/` | Earlier prototype, kept for reference |

Read [AGENTS.md](AGENTS.md) for repository conventions,
[ARCHITECTURE.md](ARCHITECTURE.md) for the UI/core boundary, and
[docs/ipc.md](docs/ipc.md) for the protocol. [ROADMAP.md](ROADMAP.md) tracks
milestones; some historical entries predate the current implementation.

Contributions toward everyday usability, search and organization, reliable P2P
sharing, Linux packaging, and cross-platform support are welcome. The ambition
is a complete photo app, and improvements on any platform help the whole project.

### Verification

```sh
dub build --compiler=ldc2
dub test --compiler=ldc2

# Two headless nodes: index, publish an album, and fetch over libp2p.
tests/e2e.py /folder/with/nine/images

# Capture the desktop without a display.
QT_FORCE_STDERR_LOGGING=1 QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software \
  PW_SHOT=/tmp/photo-wagon.png ./photo-wagon
```

## Why “Photo Wagon”?

> “I think my cooking is awesome, I've got her picture on my photo-wagon…”

The name comes from **“Bushes of Love” by Bad Lip Reading**. A photo wagon seemed
like a good place to keep your pictures.

<p align="center">
  <img src="docs/img/chicken-duck-woman.png" width="220" alt="A chicken duck woman thing, a nod to Bushes of Love">
</p>
