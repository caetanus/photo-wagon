# Android

`mobile/` is Photo Wagon for a phone, written in D like the rest: it shows the
**phone's own photos** (DCIM/ and Pictures/, scanned in D, capture time and
orientation from the pure-D EXIF reader, thumbnails decoded by Qt) in the same
Qt Quick UI, and **sends them to the computer's library**. The core itself does
not run on the phone yet (see ROADMAP M7), so the phone talks to the desktop's
core over the network with the protocol of `docs/ipc.md`.

## Pairing

1. On the computer, click **Phone** in Photo Wagon. The core starts listening
   on the LAN (port chosen by the kernel, a random token) and the panel shows a
   QR code with `pw://<token>@<ip>:<port>`.
2. On the phone, tap ⚙ → **Scan QR code**. QML opens `pwscan://start`; Android
   routes that intent back to `MainActivity`, which runs the Google code scanner
   (ML Kit, `play-services-code-scanner`) and writes the text to
   `files/settings/scanned`; the D side picks it up within a second, saves it,
   connects and authenticates with `daemon.auth`.
3. From then on the viewer's **Send to computer** and the header's **Send all**
   push photos through `library.import`; the computer files them under
   `<data dir>/imports/<yyyy-mm>/` and indexes them. Already-sent photos are
   remembered on the phone.
4. While the computer is reachable the phone shows **one timeline**: its own
   camera roll merged with the computer's library by capture time. A computer
   photo that is the same file as a local one (same name and size, which is how
   "Send" copies it) appears once. Computer photos carry ids above 10⁹, their
   thumbnails arrive as data: URLs (`library.thumbs`) and opening one fetches a
   2048 px rendition (`photo.file`). The drawer lists the computer's albums;
   tapping one browses it. Offline, the phone shows its own photos only.

Typing the address by hand in the same dialog still works for a core started
with `--serve --ipc-address 0.0.0.0`; only the loopback interface is exempt
from the token.

Verified 2026-09-07 on a Samsung SM-M625F (arm64-v8a, Android 13): the D
runtime, GC and TLS work inside Qt's activity, the app indexes the phone and
connects to the computer. The same client, built for the desktop, is what the
offscreen tests drive (`PW_PHONE_ROOTS`, `PW_ENDPOINT=pw://…`, `PW_SHOT_SEND=1`).

## What the build needs

| piece | where | how it was obtained |
|---|---|---|
| Qt 6.11.1 `android_arm64_v8a` and `gcc_64` kits | `~/Qt/6.11.1/` | Qt installer |
| Android SDK: NDK 27.2, platform 36, build-tools 36 | `/opt/android-sdk` | `sdkmanager` |
| JDK 17 | `/usr/lib/jvm/java-17-openjdk` | distro package |
| LDC 1.42 host compiler | `/usr/bin/ldc2` | distro package |
| LDC 1.42 **Android runtime** (druntime + Phobos for aarch64) | `~/lab/android-d/ldc2-1.42.0-android-aarch64/` | `ldc2-1.42.0-android-aarch64.tar.xz` from the LDC GitHub release, unpacked; only its `lib/` is used |
| DSide binding for the Android kit | `~/lab/qt-dlang-gen/generated/qt-6.11-android-arm64/cxx-quick` + `.build/qt-6.11-android-arm64-cxx-quick/{libbinding_ldc2.a,libshims.a}` | `mobile/toolchain/build-binding.sh all` |

`mobile/toolchain/` holds everything that is ours:

- `ldc2-android.conf` — a full ldc2.conf: the host `default` section plus an
  `"aarch64-.*-linux-android"` section that links through the NDK clang with
  `lld` and takes libraries from the Android runtime above. Edit `lib-dirs` if
  the runtime lives elsewhere.
- `pkgconfig/*.pc` — the Qt Android kit ships no `.pc` files; these hand-written
  ones let xiboca (the DSide generator) find headers and libraries.
- `spec_cxx_quick_android.json` — the xiboca spec: the desktop `cxx-quick` spec
  with the kit's paths. `resource_dir` stays the **host** clang's: xiboca parses
  with the host libclang, and the NDK's `arm_neon.h` uses builtins it rejects.
- `build-binding.sh` — generate, then compile the D side (`ldc2` cross,
  `-relocation-model=pic`) and the C++ shims (NDK `clang++`, `-fPIC`).

## Building the app

```sh
mobile/build-android.sh          # link + package + install + launch on the attached phone
mobile/build-android.sh link     # only libphotowagon_arm64-v8a.so
mobile/build-android.sh package  # only the APK: mobile/build-android/photo-wagon-mobile-debug.apk
```

What the script does, in case it has to be done by hand:

1. **Link.** The D sources of the mobile app plus `ui/backend.d`, `ui/transport.d`
   and DSide's `runtime/qrc/qrc.d` are compiled with
   `ldc2 -conf=toolchain/ldc2-android.conf -mtriple=aarch64-linux-android -shared -relocation-model=pic`
   into `libphotowagon_arm64-v8a.so`, against the two binding archives (inside
   `--start-group`) and the kit's `libQt6*_arm64-v8a.so`, `libc++_shared`, `liblog`,
   `libandroid`. Qt's activity loads that library and calls its exported `main`;
   LDC's C `main` initialises druntime, so a plain D `main` is all it takes.
2. **Package.** `androiddeployqt` from the **host** kit, with a deployment JSON
   the script writes (`build-android/android-deployment-settings.json`), our
   `mobile/android/AndroidManifest.xml` as the package source, `qml/` as the QML
   root so the import scanner bundles QtQuick.Controls, and `--android-platform
   android-36` (the androidx the template pulls in refuses 35). Gradle comes from
   the wrapper Qt generates.
3. **Run.** `adb install -r`, `am start`, a screenshot and a logcat excerpt.

## The emulator

The app runs on the Android emulator two ways. The arm64 APK runs on the
x86_64 image through Android's ARM translation (the API 35 Google APIs image
has it), which is enough to see the UI come up but not to trust: the D
garbage collector crashes under the translator within a minute. So the real
emulator build is native x86_64:

1. LDC ships no x86_64 Android runtime; `ldc-build-runtime` makes one (static
   libraries only — the shared druntime fails to link, and against API 33 or
   later, because x86_64 bionic offers `__tls_get_addr` only from there):

   ```sh
   ldc-build-runtime --ninja --targetSystem="Android;Linux;UNIX" \
       --dFlags="-mtriple=x86_64-linux-android" --buildDir=/tmp/ldc-x86_64 \
       BUILD_SHARED_LIBS=OFF CMAKE_TOOLCHAIN_FILE=$NDK/build/cmake/android.toolchain.cmake \
       ANDROID_ABI=x86_64 ANDROID_NATIVE_API_LEVEL=33 ANDROID_PLATFORM=android-33 ANDROID_STL=c++_static
   mkdir -p ~/lab/android-d/ldc2-1.42.0-android-x86_64 && cp -r /tmp/ldc-x86_64/lib ~/lab/android-d/ldc2-1.42.0-android-x86_64/
   ```
   `toolchain/ldc2-android.conf` has the matching `x86_64-.*-linux-android` section.
2. The DSide binding for x86_64 reuses the arm64 generated sources (both are
   LP64, the Qt headers are the same): `ABI=x86_64 toolchain/build-binding.sh d`
   then `shims`, against `~/Qt/6.11.1/android_x86_64` through
   `toolchain/pkgconfig-x86_64`.
3. libsodium for x86_64: `dist-build/android-x86_64.sh` (its output folder is
   named after the CPU, `libsodium-android-westmere`) → `toolchain/android-libs/x86_64/`.
4. `ABI=x86_64 mobile/build-android.sh` builds `build-android/x86_64/…apk`.

An AVD: `avdmanager create avd -n photowagon -k "system-images;android-35;google_apis;x86_64" -d pixel_6`,
booted headless with `emulator -avd photowagon -no-window -no-audio -gpu swiftshader_indirect`.
Test photos go to `/sdcard/DCIM/Camera` with `adb push`. With a phone attached
as well, `ANDROID_SERIAL=emulator-5554` picks the emulator for adb and the
harness: `ANDROID_SERIAL=emulator-5554 APK=mobile/build-android/x86_64/photo-wagon-mobile-debug.apk mobile/adb-harness.sh --install --clear-data --exercise`.

What the emulator does not give: once the app pairs and the sync starts, Qt's
Android window on this image stops rendering ("Skipping create egl on invalid
or not yet created surface" from qt.qpa.window, the scene graph's render
thread gone) while the process, the Qt event loop and the D threads go on —
a surface/EGL problem of the emulator's swiftshader path, not seen on the
phone. Use the emulator for launch, permission, indexing and crash hunting;
use the phone for the UI.

Two things the translated run taught, kept in the code: QtLoader's environment
(`QT_PLUGIN_PATH`, QML paths) is invisible to a translated libc, so
`MainActivity` writes it to `files/settings/qt-env` and `main.d` adopts it
when missing; and stdout/stderr of the process go nowhere, so `plog.d`
relays them to logcat (tag `photowagon-io`) — that is how vibe-core's
"TaskFiber getting terminated" messages became readable.

## Testing on the phone: the adb harness

`mobile/adb-harness.sh [--install] [--clear-data] [--exercise] [--seconds N] [--force]`
installs the APK, cold-launches the app, presses Allow on the permission dialog
(uiautomator), optionally swipes the grid and opens a photo every few seconds,
and watches: memory (PSS) every 3 s, the D log (logcat tag `photowagon`), ANRs,
crashes, a screenshot every 15 s with a black-window check, and the QML
heartbeat (`ui alive #n` every 10 s, `ui stalled N ms` when a 250 ms timer came
late — `dumpsys gfxinfo` does not count Qt's GL frames). Everything lands in
`mobile/build-android/harness/` (`app.log`, `logcat.txt` incl. the crash buffer,
`memory.tsv`, `screen-*.png`). It refuses to take the phone while another app is
in front unless `--force`.

Diagnostics built into the app: `slow: <op> N ms` for any bridge request or
index step over 30 ms, `phone: decoded N/M in S s; gc …` every 100 photos with
the D GC's pause statistics, `QSG_RENDER_TIMING` per-frame lines from Qt, and a
SIGSEGV/SIGABRT handler that writes a libunwind backtrace to logcat — Samsung's
shipping builds keep no tombstones for third-party apps.

## The computer over libp2p

The pairing code carries the computer's libp2p addresses after a `#`
(`pw://<token>@<ip>:<port>#/ip4/<ip>/tcp/<port>/p2p/<peer id>,…`). The phone
runs a small libp2p host of its own — the "lite" build of libp2p-dlang: TCP
transport, Noise, yamux, Ed25519 only, IP addresses only (`-d-version=LibP2P_Lite`
leaves OpenSSL and c-ares out) — on a vibe-core event loop on its own thread,
with an identity in `files/settings/identity.seed`. It dials the computer, opens
`/photowagon/ipc/1.0.0` and carries the JSON lines of `docs/ipc.md` as
length-prefixed frames; the Qt thread reaches that thread through the same
`InProcessLink` the desktop UI uses for its core (`mobile/…/p2pbridge.d`). A
plain `host:port` typed by hand still goes over TCP (`tcpbridge.d` underneath).
libsodium for arm64 is the archive in `toolchain/android-libs/arm64/`, built
from the 1.0.20 release with `dist-build/android-armv8-a.sh`
(`ANDROID_NDK_HOME=/opt/android-sdk/ndk/27.2.12479018`); vibe-core, eventcore,
vibe-container, taggedalgebraic, stdx-allocator and libsodiumd come from
`~/.dub/packages` (a `dub build` in `mobile/` fetches them) and are compiled
into the app's `.so` by `build-android.sh`.

## Faces on the phone

The phone runs no face model; the computer's face database is what it shows.
Opening a photo asks the computer for its faces: a computer photo by id, one
of the phone's own by content hash (`library.byHash`, so the phone's copy and
the computer's copy are the same photo), with the face crops and the people's
portraits inline as data: URLs (`photo.faces` / `people.list` with
`inline: true`). Naming a face in the viewer sends `face.setPerson` to the
computer; renames, merges, "not a face" and "not a person" go the same way,
and the computer's `people.changed` / `faces.done` events come back, so a name
given on either side shows on both. Without the computer the viewer shows no
faces. `tests/phone-sync.py <photos> <faces dir>` covers it: the computer finds
the people in what the phone sent, the phone gets one face for its own
lena.jpg, and a name lands in the computer's people.

## Sync to the computer

The phone keeps the computer up to date by itself once "Keep the computer up to
date" is on (the Sync button turns it on). The queue is the phone index: each
photo carries `sent`, `tries` and `hash`, saved after every step, so a crash or
a kill loses nothing and the next launch resumes. A file is read, hashed and
base64-encoded on a thread; the computer is asked by hash
(`library.import {probe: true, sha256}`) and the bytes go only when it lacks
them; after three failures a photo waits for the next press of Sync. The D side
writes `files/settings/sync-status`; `MainActivity` reads it every 2 s and drives
`SyncService`, a foreground service whose notification shows the progress and
keeps the process alive (and unfrozen) in the background. Android 13 asks for
`POST_NOTIFICATIONS` the first time a sync starts.
`tests/phone-sync.py <dir>` runs the desktop build of the phone client against
a headless core: nothing moves with the setting off, everything goes once, a
second launch re-sends nothing, and a SIGKILL mid-sync resumes on restart.

The app remembers the pairing in its config dir
(`/data/data/org.photowagon.mobile/files/settings/endpoint`, the `pw://` code
or `host:port`). For a USB-only test, `adb reverse tcp:47111 tcp:47111` makes
the phone's `127.0.0.1:47111` reach a core started with `--serve --port 47111`.

## Known limits

- arm64 only. The LDC 1.42 release has no x86_64 Android runtime, so the x86_64
  emulator image cannot run it; an arm64 device is needed.
- Only the `cxx-quick` binding was generated for Android (Controls come as QML
  plugins, no D binding needed).
- The core's native dependencies (sqlite3, gexiv2, vips, openssl, c-ares) have
  no Android builds here, which is why the phone keeps a JSON index of its own
  photos and sends them to the computer instead of running the core. libsodium
  is built for arm64 (see above), which is what libp2p needs.
- `QImageReader::read()` returning `QImage` by value is mis-bound (sret); the
  phone index uses the `read(QImage*)` overload. The binding never frees a
  `QImage` or `QImageReader` (no deleter yet): the decoders reuse one of each
  per worker thread instead of one per photo.
- `QStandardPaths::PicturesLocation` is the app's private
  `Android/data/<pkg>/files/Pictures`; the camera roll lives in the shared
  storage that folder sits in (`main.d`, `photoRoots`).
- The photo permission is asked by the D side (`pwperm://request`) once the
  window is up; asking in `onCreate` left the window black on the SM-M625F.
- New D modules must be added to the source list in `build-android.sh`.
- `main()` must not return: Qt's Back key closes the window and `exec()`
  returns; a D `main` returning runs `rt_term` while the decoder, sync and
  libp2p threads still run, and their next allocation is a SIGSEGV. `main.d`
  calls `exit()` instead, and the QML `onClosing` closes the viewer or the
  drawer before letting the window go.
- DSide's holder map (`runtime/holder/qtd_holder.cpp` in qt-dlang-gen) is
  locked since 2026-09-10: a wrapper's GC finalizer unregisters it from
  whichever thread collected, while the Qt thread registers new ones.
- vibe-core's event loop on the libp2p thread ends once per session with
  "May not process events within an active yieldLock()" (cause open); the
  thread hands over to a fresh one and parks, the UI is told the link dropped
  and the session redials. Ending the old thread instead crashed in vibe's
  thread destructor.
- The scanner needs Google Play services on the phone (the model is fetched on
  first use).
