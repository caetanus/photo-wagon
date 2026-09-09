# IPC — UI ⟷ core

Both directions carry **one JSON object per line** (`\n` terminated, no
pretty-printing). Inside the application the lines travel through
`InProcessLink` (two queues between the Qt thread and the core thread). In
headless mode (`--headless`, or `--serve` alongside the UI) the same lines go
over one TCP connection on the loopback interface; the core writes the port it
picked to `$XDG_RUNTIME_DIR/photowagon/daemon.port` (fallback
`<data dir>/daemon.port`).

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

### pairing and authentication

| method | params | result |
|---|---|---|
| `phone.pairing` | `{enable?: bool}` | `{enabled, port, addrs, code, qr: {width, rows}, qrImage}` — turns the LAN listener (0.0.0.0) on/off; `code` is `pw://<token>@<ip>:<port>[,…]`, `qrImage` a PNG data: URL of it |
| `daemon.auth` | `{token}` | `{ok: true}` or `unauthorized` |
| `library.import` | `{name, base64, takenAt?}` | `{existed, path, id?}` — stores the bytes under `<data dir>/imports/<yyyy-mm>/` and indexes them; a photo already in the library (same hash) is reported with `existed: true` |

A client that is not on the loopback interface must send `daemon.auth` with the
token from the pairing code before anything but `daemon.hello`; every other
method answers `{"error": {"code": "unauthorized"}}` until then. The token is
created once per library (`<data dir>/pair.token`).

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

### media (for a front-end on another machine)

| method | params | result |
|---|---|---|
| `library.thumbs` | `{ids: []}` (≤ 200) | `{thumbs: {"<id>": base64-jpeg}}` — ids without a thumbnail are absent |
| `photo.thumb` | `{id}` | `{mime, base64}` |
| `photo.file` | `{id, maxEdge?}` | `{mime, size, base64}` — the original, or a JPEG no larger than `maxEdge` on its longest side |

### people and faces

Every local photo is scanned after indexing (YuNet detector + SFace embeddings,
OpenCV). Faces are grouped into people by embedding similarity; a person has no
name until the user gives one. Face boxes are fractions of the rotated image.

| method | params | result |
|---|---|---|
| `people.list` | — | `{people: [{id, name?, faces, coverUrl?}]}` most faces first |
| `people.rename` | `{id, name}` | `{}` (empty name = unnamed again; the name of an existing person merges into that person) |
| `people.merge` | `{id, into}` | `{}` — faces of `id` join `into`, `id` disappears |
| `photo.faces` | `{id}` | `{photoId, faces: [{id, photoId, x, y, w, h, score, thumbUrl?, personId?, name?}]}` |
| `face.setPerson` | `{faceId, personId?, name?}` | `{personId?, followed}` — an existing person, a person by name (created when new), or nobody. A face in an automatic (unnamed) group names or merges that whole group (`followed` = how many others). A face taken out of a named person pulls along the faces of that person that look more like the new one: name one face of a look-alike sibling and hers move with it |
| `faces.scan` | — | `{}` — scans what is unscanned (also runs after every index job) |
| `faces.recluster` | — | `{}` — regroups every unnamed face with the current rule (named people keep theirs) |
| `faces.status` | — | `{available, running, scanned, total, known, people}` |

Grouping: detections below 0.75 are discarded. A face joins the person whose
centroid is closest when the cosine is ≥ 0.45 and the runner-up is at least
0.05 behind (otherwise the face is left unassigned for the user); persons closer than 0.75 are merged after a scan (never two named
ones; siblings measure about 0.72). Faces narrower than 48 px or scored below 0.8 are kept but not grouped:
they show in the viewer as "Who is this?" and can be named by hand. Nobody is
in a photo twice: two faces of one picture never share a person; when the user
names one, another face of that person in the same photo becomes unassigned.

`library.page` and `photo.neighbours` accept `personId` to restrict to one person.

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
| `faces.progress` | `{done, total, faces}` |
| `faces.done` | `{photos, faces, seconds}` |
| `people.changed` | `{}` — people or face assignments changed |
| `log` | `{level, message}` |
