# ARCHITECTURE.md

## Photo Wagon Architecture

### Layers

1. UI (Qt / QML)
2. Photo Library Service (backend)
3. Content Store (hash-addressed blobs)

### UI Responsibilities
- gallery view
- timeline
- photo viewer
- lightweight editing UI
- search

The UI never reads photos directly. It queries the backend API.

### Backend Responsibilities
- folder scanning
- EXIF parsing
- thumbnail generation
- SQLite indexing
- optional OpenCV jobs

### Content Store

Assets stored by hash:

sha256(photo)
sha256(thumbnail)

Example:

store/
  ab/
    cdef123...
  91/
    ff22aa...

Benefits:
- deduplication
- integrity
- simple P2P distribution

### Metadata

Stored in SQLite:

- timestamp
- GPS
- camera model
- orientation

### Computer Vision (optional)

OpenCV:
- face detection
- object detection
- scene classification

### P2P Sharing (Phase 2)

libp2p:
- DHT discovery
- QUIC transport
- NAT traversal
- relay fallback
