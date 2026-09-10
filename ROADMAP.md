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
- places view (GPS clusters), moments grouping, FTS search

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
- [ ] Phone: the computer found without the QR (LAN beacon / DHT), faces cached for offline
- [ ] Memories / Places (needs GPS clusters and a map)
- Flatpak / AppImage, caching, startup time
