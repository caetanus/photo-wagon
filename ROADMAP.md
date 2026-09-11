# ROADMAP

## M0 — Rebuild in D (done 2026-09-07)
- [x] repo layout, docs, IPC protocol (`docs/ipc.md`)
- [x] core: config, SQLite schema, content store, IPC server
- [x] core: indexer (walk · hash · gexiv2 · vips) with progress events, incremental rescan, dedupe by hash
- [x] core: libp2p host up (TCP · Noise · yamux · identify · ping · Kademlia)
- [x] core: album manifests + `/photowagon/blob/1.0.0` (publish on A, fetch on B — `tests/e2e.py`)
- [x] UI: DSide app, `Library` facade
- [x] UI: sidebar by date, grid, viewer, peers panel
- [x] one process: core on its own thread, `InProcessLink` instead of a socket; `--headless` keeps the TCP protocol

Known gaps carried into M1: a second path with identical bytes is skipped rather
than recorded; `p2p.status` reports the listen address as given (a `0.0.0.0`
listen needs interface expansion before a peer can dial it); originals of a
fetched album are not pulled, only thumbnails.

## M1 — Library
- import 1000+ photos with smooth scrolling, dedupe by hash
- neighbours in the viewer, keyboard navigation
- incremental rescan (mtime + size)

## M2 — Metadata
- [x] media types: every picture is a photograph, a screenshot or a meme (camera EXIF, screen sizes,
  folder names, and a small logistic model over pixel statistics fitted on a real library; the user can
  override in Info); faces are only looked for in photographs — 2026-09-09
- moments grouping, FTS search, natural-language search over the CLIP embeddings (image side in sqlite-vec since 2026-09-11; photo.similar already runs on it) (places: done 2026-09-11, city per photo from GPS or by hand; a map is still open)

## M3 — People (done 2026-09-09)
- [x] face detection + embeddings: YuNet + SFace through `csrc/face_opencv.cpp`, the one C++ file
  (OpenCV 5 has no C API for them); scan runs on worker threads after every index job
- [x] clustering by cosine similarity (SFace threshold 0.363), face crops in the store
- [x] UI: People list in the sidebar (filter, rename), face boxes in the viewer with "Who is this?"
- [ ] batch naming ("is this the same person?"), per-person cover choice
- [ ] faces in photos fetched from peers (only local originals are scanned)

## M4 — Editor
- non-destructive recipes: rotate, crop, exposure

## M5 — Sharing
- album manifests, `/photowagon/blob/1.0.0`, DHT provider records
- fetch with hash verification, progress events

## M6 — Reachability
- QUIC transport, circuit relay v2, DCUtR, AutoNAT (all present in libp2p-dlang)

## M7 — Other screens (mobile started 2026-09-07)
- [x] `mobile/`: the same Qt Quick UI in D on the phone's own photos (D scan, pure-D EXIF, Qt thumbnails,
  JSON index), sending them to the computer through `library.import`
- [x] Android package (arm64): LDC cross build + DSide binding for Qt Android, verified on a device (`ANDROID.md`)
- [x] pairing by QR code (`phone.pairing` + token, ML Kit scanner in the activity)
- [x] one timeline on the phone: camera roll merged with the computer's library, its albums in the drawer
- [ ] the phone as a libp2p peer (album sharing both ways) once the core's deps build for Android
- [ ] the core itself on the phone (needs libsodium, openssl, c-ares, sqlite, vips, gexiv2 for Android)
- HTTP front-end from the core for a TV

## M8 — Polish
- [x] Photos-style desktop UI (sidebar, Years/Months/Days/All, zoom, selection, in-window viewer, Info panel, People, favorites, albums from a selection) — 2026-09-09
- [x] Back from the old UI: the date tree, the people list and the status in the sidebar, the caption under the photo; `library.dates` follows the filter — 2026-09-10
- [x] Photos over 64 MP would not open (Qt's 256 MB decode limit): the viewer decodes scaled to 4096² — 2026-09-10
- [x] Phone: camera roll found, thumbnails on worker threads, no black window, adb harness, automatic sync surviving crashes with an Android notification — 2026-09-10
- [x] Phone: the computer over libp2p (`/photowagon/ipc/1.0.0`, the lite libp2p build on Android, libsodium cross-built) — 2026-09-10
- [x] Phone: the computer's faces on the phone's own photos (by hash), names and corrections both ways — 2026-09-10
- [x] Desktop: search as you type (people, albums, dates, kinds, file names), folding sidebar sections, a chosen portrait per person and the biggest face by default, "Remove from People", likely people first when naming a face, zoom and full screen in the viewer, a context menu (copy files, copy paths, show in folder, favorite, add to album, mark as photo / screenshot / meme) for one photo or a selection, a stronger mouse wheel — 2026-09-10
- [x] Phone: an x86_64 build for the emulator (LDC runtime built, DSide binding, libsodium), the adb harness on it; the Back key no longer tears the D runtime down; the DSide holder map is locked (GC finalizers on worker threads) — 2026-09-10
- [x] Desktop: the library timeline is photographs only (screenshots and memes under Media Types), Shift-click / Shift+arrows / Ctrl+A selection, a row-and-a-half wheel step with touchpad deltas, pages of 240 fetched ahead, full screen leaves again, SIGTERM ends the process — 2026-09-11
- [x] Dates: a photo without EXIF is dated from its name (IMG_20210321_150104, IMG-20200213-WA0000, Screenshot_2020-10-07-…, PXL_…) or its folder (2020/02/13) before the file's mtime; a one-time pass at startup re-dates what was already indexed (2,314 of the user's 2,386 EXIF-less photos left 2026) — 2026-09-11
- [x] Delete → the desktop's trash, Shift+Delete → gone for good (asked first); also in the context menu; the photos leave the library with their faces and album entries — 2026-09-11
- [ ] Phone: videos from the camera roll (index, thumbnails, playback, sync)
- [ ] Phone: the computer found without the QR (LAN beacon / DHT), faces cached for offline
- [ ] Phone: the libp2p event loop still ends with vibe's "May not process events within an active yieldLock()" once per session on Android; a fresh thread takes over, the cause is open
- [x] Scenes and moods: CLIP zero-shot tags (2026-09-11)
- [x] Tags on photos (chips, keywords) and non-destructive editing: filters, adjust, rotate, crop (2026-09-11)
- [x] Places (city from GPS via an offline GeoNames table, or "Set Place…" by hand); [ ] Memories; [ ] a map view
- Flatpak / AppImage, caching, startup time
