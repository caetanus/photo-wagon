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
| `daemon.auth` over libp2p | the phone opens `/photowagon/ipc/1.0.0` on the computer's node and sends every line of this protocol as a length-prefixed frame; the first must be `daemon.auth {token}` (libp2p says who the peer is, the pairing token says it is allowed in) | as over TCP |
| (filter) `q` | any `library.page` / `library.dates` filter may add `q`: a piece of the file path (name or folder), case-insensitive for ASCII |
| `photo.delete` | `{ids: [...], permanent?}` | `{deleted, failed: [{id, message}]}` — the files go to the freedesktop trash (`permanent: true` removes them) and the photos leave the library, faces and album entries with them |
| `photo.region` | `{id, x, y, w, h, maxEdge?}` | `{mime, base64}` — the region (fractions of the rotated image) at the original's resolution, shrunk only past `maxEdge` (default 2048): the zoomed viewer |
| `library.byHash` | `{sha256}` | `{id, path}` or `not_found` |
| `library.autoSync` (phone) | `{on}` | the sync status below; the setting persists |
| `library.syncStatus` (phone) | `{}` | `{enabled, connected, active, pending, total, done, sent, skipped, failed, error}`; also pushed as the `sync.status` event |
| `phone.pairing` | `{enable?: bool}` | `{enabled, port, addrs, code, qr: {width, rows}, qrImage}` — turns the LAN listener (0.0.0.0) on/off; `code` is `pw://<token>@<ip>:<port>[,…]`, `qrImage` a PNG data: URL of it |
| `daemon.auth` | `{token}` | `{ok: true}` or `unauthorized` |
| `library.import` | `{name, base64, takenAt?}` or `{name, sha256, probe: true}` | `{existed, path?, id?}` — the probe form only asks whether a file with that content hash is here (no bytes sent); the full form stores the bytes under `<data dir>/imports/<yyyy-mm>/` and indexes them; a photo already in the library (same hash) is reported with `existed: true` |

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
| `library.page` | `{offset, limit, year?, month?, day?, rootId?, albumId?, personId?, favorites?, kind?, q?, place?, country?, scene?, mood?, weather?, holiday?, keyword?}` | `{total, offset, items: [Photo]}` newest first; inside an album, album order |
| `library.dates` | same filter as `library.page` (dates ignored) | `{years: [{year, count, cover, months: [{month, count, cover, days: [{day, count}]}]}]}` — `cover` is the thumbnail URL of the newest photo of that year/month |
| `photo.favorite` | `{id, on?}` | `{id, favorite}` (default on) |
| `library.stats` | — | `{total, kinds: {photo, screenshot, meme, unknown}}` |
| `photo.setKind` | `{id, kind}` | `Photo` — the user's word on what a picture is (`photo`, `screenshot`, `meme`); a photograph gets its faces scanned, anything else loses them |
| `photo.get` | `{id}` | `Photo` |
| `photo.neighbours` | `{id, year?, month?, day?, rootId?, albumId?}` | `{prev: id?, next: id?}` in the same order `library.page` uses |

`Photo`:

```json
{"id": 123, "hash": "sha256-hex", "path": "/abs/file.jpg", "fileUrl": "file:///abs/file.jpg",
 "thumbUrl": "file:///.../store/ab/cdef...", "takenAt": "2024-05-01T12:00:00Z", "takenTs": 1714564800,
 "width": 4000, "height": 3000, "orientation": 1, "camera": "Canon EOS R6",
 "lat": null, "lon": null, "size": 3456789, "remote": false, "favorite": false,
 "kind": "photo", "kindBy": "auto", "place": "São Paulo", "country": "Brazil",
 "scene": "Beach", "mood": "Joyful", "weather": "Sunny", "holiday": null, "keywords": ["praia 2020"]}
```

`keywords` are the user's own tags (any words, any number; see *keywords*).

`scene`, `mood`, `weather` and `holiday` are the tags of *scenes, moods, weather,
holidays*; null when nothing in particular fits or the photo has not been looked at.

`place` and `country` are the city a photo was taken in: from the GPS, through
a compiled-in table of the world's cities (nearest one within 100 km; a 0,0
position counts as no fix), or the user's own word (`photo.setPlace`). Null
until known.

`kind` is `photo`, `screenshot` or `meme` (null until classified): a camera in
the EXIF makes a photograph; a screen-sized image, a "Screenshots" folder or a
"Screenshot_" name a screenshot; otherwise the look of the pixels (flat areas,
few colours, mostly white, dense hard edges) marks a meme. `kindBy` says whether
the user chose it. Faces are only looked for in photographs.

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
| `face.candidates` | `{id, inline?}` | `{faceId, people: [{id, name?, faces, coverUrl?, similarity}]}` — who the face most likely is, closest first |
| `people.remove` | `{id}` | `{faces}` — the person leaves People; the detections stay, unnamed (unlike `people.delete`) |
| `people.setCover` | `{id, faceId?}` | `{}` — this face is the person's portrait; no `faceId` returns to the automatic choice (the biggest confident face) |
| `people.list` | `{inline?}` (`inline: true` → `coverUrl` as a data: URL) | `{people: [{id, name?, faces, coverUrl?}]}` most faces first |
| `people.rename` | `{id, name}` | `{}` (empty name = unnamed again; the name of an existing person merges into that person) |
| `people.merge` | `{id, into}` | `{}` — faces of `id` join `into`, `id` disappears |
| `photo.faces` | `{id}` | `{photoId, faces: [{id, photoId, x, y, w, h, score, thumbUrl?, personId?, name?}]}` |
| `face.setPerson` | `{faceId, personId?, name?}` | `{personId?, followed}` — an existing person, a person by name (created when new), or nobody. A face in an automatic (unnamed) group names or merges that whole group (`followed` = how many others). A face taken out of a named person pulls along the faces of that person that look more like the new one: name one face of a look-alike sibling and hers move with it |
| `people.similar` | `{id}` | `{person, candidates: [{id, name?, faces, coverUrl?, similarity}]}` — people who may be the same one: centroids ≥ 0.42 apart and never in a photo together; the UI asks "same person?" after a naming |
| `face.delete` | `{faceId}` | `{}` — "not a face": the detection is removed |
| `people.delete` | `{id}` | `{faces}` — "not a person": the group and all its detections are removed |
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

### places

| method | params | result |
|---|---|---|
| `places.list` | `{inline?}` | `{places: [{place, country, count, cover}]}` most photos first; `cover` is the newest photo's thumbnail URL (a data: URL with `inline: true`) |
| `places.suggest` | `{q}` | `{places: [{place, country, own}]}` for a name being typed: the library's own places (`own: true`) first, then the world's cities, accents and case aside |
| `photo.setPlace` | `{ids, place, country?}` | `{}` — the user's word; a known city typed without a country gets its country; an empty `place` clears, and the GPS will not put it back |

### scenes, moods, weather, holidays

Every photograph gets a CLIP ViT-B/32 image embedding (from its thumbnail, stored in
`photo_clip`) and one tag per group — `scene`, `mood`, `weather`, `holiday` — the label
of `data/scenes/labels.tsv` whose text embedding is closest, when it takes at least
30 % of the group's softmax (logit scale 100) and is not the group's "nothing in
particular" class (None, Neutral, Indoors). For `holiday` the calendar speaks first
(`holidays.d`: Christmas, New Year, Carnival, Easter, Halloween, Festa Junina, Mother's,
Father's, Children's and Valentine's Day on the Brazilian dates; `by: "date"`). Needs
`models/clip_vision.onnx`; without it the methods answer with empty lists.

| method | params | result |
|---|---|---|
| `tags.list` | `{inline?}` | `{scene: [{tag, count, cover}], mood: […], weather: […], holiday: […], available}` most photos first |
| `tags.labels` | — | `{scene: [names], mood: […], weather: […], holiday: […]}` — what `photo.setTag` accepts |
| `photo.tags` | `{id}` | `{scene, mood, weather, holiday, by: {group: auto|date|user}, scores: {group: [{tag, prob}] ×3}}` |
| `photo.setTag` | `{ids, group, tag}` | `{}` — the user's word; `tag: ""` = nothing in particular; sticks through re-scoring |

### keywords (the user's own tags)

| method | params | result |
|---|---|---|
| `keywords.list` | `{inline?}` | `{keywords: [{keyword, count, cover}]}` most photos first |
| `photo.addKeywords` | `{ids, keywords: ["a", "b"] \| "a, b"}` | `{}` — trimmed, deduplicated case-insensitively, the user's spelling kept |
| `photo.removeKeyword` | `{ids, keyword}` | `{}` (case-insensitive) |
| `keywords.rename` | `{from, to}` | `{}` — everywhere; merges into `to` when it exists |

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
| `kinds.progress` | `{done, total}` |
| `kinds.done` | `{photos, counts, seconds}` |
| `faces.progress` | `{done, total, faces}` |
| `faces.done` | `{photos, faces, seconds}` |
| `people.changed` | `{}` — people or face assignments changed |
| `places.changed` | `{}` | places were assigned (a GPS pass or `photo.setPlace`); re-list them |
| `tags.progress` | `{done, total}` | scenes and moods being computed |
| `tags.done` | `{photos, tagged, seconds}` | the pass is over |
| `tags.changed` | `{}` | tags were assigned or changed; re-list them |
| `keywords.changed` | `{}` | the user's tags changed; re-list them |
| `log` | `{level, message}` |
