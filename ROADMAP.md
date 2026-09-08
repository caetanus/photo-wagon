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
- places view (GPS clusters), moments grouping, FTS search

## M3 — People
- face detection + embeddings (OpenCV 5 through its C API or ONNX runtime)
- clustering, naming UI (models already in `models/`)

## M4 — Editor
- non-destructive recipes: rotate, crop, exposure

## M5 — Sharing
- album manifests, `/photowagon/blob/1.0.0`, DHT provider records
- fetch with hash verification, progress events

## M6 — Reachability
- QUIC transport, circuit relay v2, DCUtR, AutoNAT (all present in libp2p-dlang)

## M7 — Other screens (mobile started 2026-09-07)
- [x] `mobile/`: the same Qt Quick UI in D as a phone client of `photo-wagon --serve` (TcpBridge,
  thumbnails and photos as data: URLs through `library.thumbs` / `photo.file`)
- [ ] Android package (arm64): LDC cross build + DSide binding for Qt Android, see ANDROID.md
- [ ] discovery of the desktop on the LAN (mDNS) instead of typing host:port
- [ ] the core itself on the phone (needs libsodium, openssl, c-ares, sqlite, vips, gexiv2 for Android)
- HTTP front-end from the core for a TV

## M8 — Polish
- Flatpak / AppImage, caching, startup time
