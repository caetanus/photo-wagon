# IPC — UI ⟷ daemon

One TCP connection on the loopback interface. Both directions carry **one JSON
object per line** (`\n` terminated, no pretty-printing). The daemon writes the
port it picked to `$XDG_RUNTIME_DIR/photowagon/daemon.port` (fallback
`~/.local/share/photowagon/daemon.port`); the UI reads that file, and if it is
missing or stale it spawns `photowagond` and waits for the file to appear.

Three message shapes:

```
request   {"id": 7, "method": "library.page", "params": {"offset": 0, "limit": 60}}
response  {"id": 7, "result": {...}}          or   {"id": 7, "error": {"code": "not_found", "message": "..."}}
event     {"event": "index.progress", "data": {...}}
```

`id` is chosen by the client and echoed back. Responses may arrive out of order.
Events are unsolicited and go to every connected client. Unknown methods answer
`{"error": {"code": "unknown_method"}}`. A client never blocks: every request
has a matching response, even on failure.

## Methods

### daemon

| method | params | result |
|---|---|---|
| `daemon.hello` | — | `{version, dataDir, peerId, addrs: [multiaddr], methods}` — `peerId` is null with `--no-p2p` |
| `daemon.shutdown` | — | `{}` then the daemon exits |

### library

| method | params | result |
|---|---|---|
| `library.roots` | — | `{roots: [{id, path, photos}]}` |
| `library.addRoot` | `{path}` | `{id}` — starts an index job; progress arrives as events |
| `library.removeRoot` | `{id}` | `{}` |
| `library.rescan` | `{id?}` | `{}` — all roots when `id` is omitted |
| `library.page` | `{offset, limit, year?, month?, day?, rootId?, albumId?}` | `{total, offset, items: [Photo]}` newest first; inside an album, album order |
| `library.dates` | `{rootId?}` | `{years: [{year, count, months: [{month, count, days: [{day, count}]}]}]}` |
| `photo.get` | `{id}` | `Photo` |
| `photo.neighbours` | `{id, year?, month?, day?, rootId?, albumId?}` | `{prev: id?, next: id?}` in the same order `library.page` uses |

`Photo`:

```json
{"id": 123, "hash": "sha256-hex", "path": "/abs/file.jpg", "fileUrl": "file:///abs/file.jpg",
 "thumbUrl": "file:///.../store/ab/cdef...", "takenAt": "2024-05-01T12:00:00Z", "takenTs": 1714564800,
 "width": 4000, "height": 3000, "orientation": 1, "camera": "Canon EOS R6",
 "lat": null, "lon": null, "size": 3456789, "remote": false}
```

`path` and `fileUrl` are null and `remote` is true for a photo known only through a
peer (its thumbnail is in the store; the original has not been fetched). `width`
and `height` are already rotated by `orientation`.

### albums

| method | params | result |
|---|---|---|
| `album.list` | — | `{albums: [{id, name, photos, manifest?, remote, originPeer?}]}` |
| `album.create` | `{name, photoIds: []}` | `{id}` |
| `album.addPhotos` | `{id, photoIds: []}` | `{}` |
| `album.page` | `{id, offset, limit}` | `{total, items: [Photo]}` |
| `album.publish` | `{id}` | `{manifest}` — content hash of the album manifest, announced on the DHT |

### p2p

| method | params | result |
|---|---|---|
| `p2p.status` | — | `{peerId, addrs, peers: [{peerId, addrs, agent, connected, lastSeen?}]}`; `{off: true}` with `--no-p2p` |
| `p2p.connect` | `{multiaddr}` | `{peerId}` — the address must carry `/p2p/<id>`; blocks until the handshake is done |
| `p2p.fetchAlbum` | `{peerId, manifest}` | `{albumId}` — fetches the manifest synchronously, creates the album, then fetches thumbnails in the background (`p2p.fetch` events) |

Methods that need the node answer `{"error": {"code": "p2p_off"}}` when it is not running.

## Events

| event | data |
|---|---|
| `index.progress` | `{rootId, scanned, imported, skipped, total}` |
| `index.done` | `{rootId, imported, skipped, removed, seconds}` |
| `library.changed` | `{}` — something in `library.page` / `library.dates` is stale |
| `p2p.peer` | `{peerId, connected: bool}` |
| `p2p.fetch` | `{albumId, done, total}` |
| `log` | `{level, message}` |
