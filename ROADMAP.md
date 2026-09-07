# ROADMAP

## M0 — Rebuild in D (done 2026-09-07)
- [x] repo layout, docs, IPC protocol (`docs/ipc.md`)
- [x] daemon: config, SQLite schema, content store, IPC server
- [x] daemon: indexer (walk · hash · gexiv2 · vips) with progress events, incremental rescan, dedupe by hash
- [x] daemon: libp2p host up (TCP · Noise · yamux · identify · ping · Kademlia)
- [x] daemon: album manifests + `/photowagon/blob/1.0.0` (publish on A, fetch on B — `daemon/tests/e2e.py`)
- [x] UI: DSide app, `Library` facade, daemon spawn + reconnect
- [x] UI: sidebar by date, grid, viewer, peers panel

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

## M7 — Other screens
- HTTP front-end from the daemon for TV/phone (the daemon already owns the data)

## M8 — Polish
- Flatpak / AppImage, caching, startup time
