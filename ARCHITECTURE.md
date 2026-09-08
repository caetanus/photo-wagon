# Architecture

Photo Wagon is one D program with two threads.

```
 main thread    Qt Quick UI (DSide binding) — the only thread that touches QObjects
     │  InProcessLink: JSON lines in two queues; wake by pipe ↑ / vibe event ↓   (docs/ipc.md)
 core thread    vibe-core event loop: indexer · content store · SQLite · libp2p node
     │
 ~/.local/share/photowagon/   library.db · store/ab/cdef… (thumbnails, shared blobs)
```

Why a thread and not the same loop: the UI binding pins every `QObject` to the
thread that created it and aborts on a violation, while libp2p-dlang and the
indexer live on vibe-core fibers with their own event loop. Each loop gets its
own thread; they share nothing but the two queues. The UI is woken through a
`QSocketNotifier` on a pipe, so a response is handled on the Qt thread; the core
is woken through a shared vibe `ManualEvent`, so a request is handled on a fiber.

The same core also runs alone (`--headless`, or the `headless` dub configuration
for a machine without Qt) and then speaks the identical line protocol over
loopback TCP — that is what `tests/e2e.py` and a future TV/web front-end use.

## Core (`source/photowagon/core/`)

| package | owns |
|---|---|
| `daemon` | wiring and lifecycle; `runCore` (this thread) and `CoreThread` (behind a UI) |
| `config` | data directory, port file, defaults, flags |
| `ipc` | `protocol` (methods, errors), `handler` (one request → one fiber → one reply), `link` (in-process queues), `server` (TCP, headless), `events` (fan-out) |
| `db` | SQLite handle, schema, migrations |
| `store` | content-addressed blob store: `sha256 → store/ab/cdef…` |
| `metadata` | EXIF/XMP via gexiv2: timestamp, camera, orientation, GPS |
| `thumbs` | thumbnails via libvips into the store |
| `indexer` | walks roots, hashes files, calls metadata + thumbs, writes rows, emits progress |
| `library` | read-side queries: photos, pages, date tree, neighbours, roots, albums |
| `p2p` | libp2p `Host` (TCP · Noise · yamux), identify, ping, Kademlia, `/photowagon/blob/1.0.0`, album manifests |
| `api` | binds the services to method names |

Rules that shape the code:

- **The UI never touches files or the database.** It asks the core; the core
  answers with data and `file://` URLs it chose to expose.
- **Originals stay where they are.** Import indexes by reference; the store holds
  derived and shared blobs only. Editing (later) is a recipe over the original.
- **CPU-bound work leaves the fiber loop.** Hashing, EXIF and vips run through
  `vibe.core.concurrency.async` on worker threads; SQLite is used from the core
  thread only, one statement at a time.
- **Fibers have owners.** Every `runTask` is reachable from an object whose
  `close()` interrupts and joins it (same law as libp2p-dlang's DESIGN.md).

## UI (`source/photowagon/ui/`)

- `app.d` builds the `QGuiApplication` and a `QQmlApplicationEngine`, registers
  the `.qrc` in CTFE, exposes one `@QObject` (`Library`) as a context property.
- `Library` (`backend.d`) is the only object QML sees. Lists cross as
  `@Property string` JSON, one page at a time, parsed with `JSON.parse` in QML.
  Commands are `@Slot`s.
- `bridge.d` (`CoreBridge`) owns the request table and the wake-up from the core.
- QML under `qml/`: `Main.qml` (ApplicationWindow, sidebar + grid + viewer),
  `PhotoGrid.qml`, `DateTreeSidebar.qml`, `PhotoFocusView.qml`, `PeersPanel.qml`.

## P2P

An album is published as a **manifest**: JSON listing photo hashes, thumbnail
hashes and metadata, itself stored by hash. Publishing puts the manifest hash on
the Kademlia DHT as a provider record. A peer that receives
`<peerId>/<manifest>` opens `/photowagon/blob/1.0.0` streams and asks for the
manifest, then each blob, verifying every hash on arrival. Identify and ping run
on every connection. QUIC, relay and hole punching come from libp2p-dlang as
those transports are wired in (see ROADMAP.md).
