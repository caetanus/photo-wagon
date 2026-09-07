# ROADMAP — Photo Wagon

## Milestone 0 — Dev Loop
- repo structure
- backend service
- QML UI skeleton
- SQLite schema

## Milestone 1 — Photos Library
Backend:
- import folder
- dedupe
- EXIF read
- thumbnail generation

UI:
- gallery grid
- photo viewer
- search

Definition of done:
- import 1000 photos
- smooth browsing

## Milestone 2 — Metadata
- places view
- moments grouping
- SQLite FTS search

## Milestone 3 — People
- face detection
- embeddings
- clustering
- name UI

## Milestone 4 — Editor
- rotate
- crop
- exposure/gamma
- presets

## Milestone 5 — P2P Sharing
libp2p sidecar:
- QUIC
- DHT
- encrypted blobs
- album manifests

Goal:
share albums directly between peers.

## Milestone 6 — NAT Traversal
- hole punching
- relay fallback

## Milestone 7 — Web / SmartTV
- web UI
- TV mode
- QR open on phone

## Milestone 8 — Polish
- incremental indexing
- caching improvements
- Flatpak / AppImage
