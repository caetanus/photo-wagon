# Architecture

Photo Wagon is two D programs.

```
 photo-wagon      Qt Quick UI in D (DSide binding), one thread, Qt event loop
     │  JSON lines over loopback TCP           docs/ipc.md
 photowagond      vibe-core fibers: indexer · content store · SQLite · libp2p node
     │
 ~/.local/share/photowagon/   library.db · store/ab/cdef… (thumbnails, shared blobs)
```

Why two processes and not one: the UI binding pins every `QObject` to a single
thread and aborts on a violation, while libp2p-dlang and the indexer live on
vibe-core fibers with their own event loop. Two loops in one process would mean
one of them polling the other. Two processes also let the daemon run headless
(the future web/TV front-end) and keep a UI crash from taking the node down.

## Daemon (`daemon/`)

| package | owns |
|---|---|
| `app` | startup, wiring, shutdown |
| `config` | data directory, port file, defaults |
| `ipc` | TCP listener, JSON-lines framing, method dispatch, event fan-out |
| `db` | SQLite handle, schema, migrations, typed queries |
| `store` | content-addressed blob store: `sha256 → store/ab/cdef…` |
| `metadata` | EXIF/XMP via gexiv2: timestamp, camera, orientation, GPS |
| `thumbs` | thumbnails via libvips into the store |
| `indexer` | walks roots, hashes files, calls metadata + thumbs, writes rows, emits progress |
| `library` | read-side queries: pages, date tree, neighbours, albums |
| `p2p` | libp2p `Host` (TCP · Noise · yamux), identify, ping, Kademlia, the album protocol |

Rules that shape the code:

- **The UI never touches files or the database.** It asks the daemon; the daemon
  answers with data and `file://` URLs it chose to expose.
- **Originals stay where they are.** Import indexes by reference; the store holds
  derived and shared blobs only. Editing (later) is a recipe over the original.
- **CPU-bound work leaves the fiber loop.** Hashing and vips run through
  `vibe.core.concurrency.async` on worker threads; SQLite stays on the main
  thread, one statement at a time.
- **Fibers have owners.** Every `runTask` is reachable from an object whose
  `close()` interrupts and joins it (same law as libp2p-dlang's DESIGN.md).

## UI (`ui/`)

- `app.d` builds the `QGuiApplication` and a `QQmlApplicationEngine`, registers
  the `.qrc` in CTFE, exposes one `@QObject` (`Library`) as a context property.
- `Library` (`backend.d`) is the only object QML sees. Lists cross as
  `@Property string` JSON (route B from the DSide notes): one page at a time,
  parsed with `JSON.parse` in QML. Commands are `@Slot`s.
- `client.d` owns the `QTcpSocket`, the request table and the daemon lifecycle
  (`QProcess` spawn when no port file is present).
- QML under `ui/qml/`: `Main.qml` (ApplicationWindow, sidebar + grid + viewer),
  `PhotoGrid.qml`, `DateTreeSidebar.qml`, `PhotoFocusView.qml`, `PeersPanel.qml`.

## P2P

An album is published as a **manifest**: JSON listing photo hashes, thumbnail
hashes and metadata, itself stored by hash. Publishing puts the manifest hash on
the Kademlia DHT as a provider record. A peer that receives
`<peerId>/<manifest>` opens `/photowagon/blob/1.0.0` streams and asks for the
manifest, then each blob, verifying every hash on arrival. Identify and ping run
on every connection. QUIC, relay and hole punching come from libp2p-dlang as
those transports are wired in (see ROADMAP.md).
