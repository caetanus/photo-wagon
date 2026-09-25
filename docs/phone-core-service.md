# The phone core in its own process

**Status.** This is the target design. Implemented so far: the `:core` service scaffold
(CoreService + coremain.d, a heartbeat — the core does not run there yet) and **stage 1**
below (the core is built by `corefactory.buildPhoneCore()` and the UI talks to it only
through `uiadapter.UiBridge`, still in the UI process). Stages 2–7 follow.

**Why.** On the phone the UI and the core shared one process: the indexer's decodes and face
inference ran on the UI's Qt thread (the p2p stack already had its own thread, and index
saves and upload preparation use workers), and a crash anywhere — typically in the p2p stack
— took the screen down with it. The target: the core runs in an Android service in a
separate process (`:core`) and the UI talks to it over a local socket. That buys **process, crash and
GC isolation** and moves the remaining Qt-thread work off the UI; it is isolation, not a
survival guarantee — Android may still reclaim either process (see Lifecycle).

## Ownership

| UI process (`org.photowagon.mobile`) | core process (`org.photowagon.mobile:core`) |
|---|---|
| `MainActivity` (QtActivity), `main.d` → QGuiApplication + QML | `CoreService` (QtService), `main.d` sees `-service` → `coremain.serviceMain()` → QAndroidService |
| `Library` (the QML model), QML, viewer/editor rendering | `PhoneIndex` (scan, decode, thumbnails, faces), `LocalBridge` (local queries, paging, sync), `P2pBridge` |
| permission prompts, the share sheet (the Activity is here) | persistent index and network state; publishes derived files |
| `CoreClient : Bridge` | `CoreServer` (QLocalServer) |

Both load the same `.so`; the manifest gives the service `android.app.arguments="-service"`.

## The seam

`Library` (ui/backend.d) talks to its `Bridge` through exactly: `request` (81 call sites),
`endpoint` (2), `connected` (2), `start`, `setEndpoint`, `remote`, `onEvent`, `onConnected`
(no `requestRaw`). `LocalBridge` overrides only `start`, `connected`, `remote`, `endpoint`,
`setEndpoint`, `request`. Local thumbnails and originals reach QML as `file://` URLs into
the app's persistent storage (`<dataDir>/thumbs`, the originals' own paths); the viewer's
`Image`/`MediaPlayer` read them directly, so no image bytes cross the socket.

The seam is JSON-value based (`LocalBridge.request` takes a parsed `JSONValue` and calls a
delegate); `CoreServer` adds framing, validation and session ownership around it, following
docs/ipc.md: requests dispatched in order per connection, responses may arrive out of order.

## What must NOT move as-is

- **Sharing.** `photo.share` today resolves the file and then calls `pw_share_image` → JNI →
  `MainActivity.shareImage()`, which uses the process-local Activity instance (null in
  `:core`) — and `LocalBridge` answers `shared:true` regardless. New split: the core
  resolves/downloads and answers `{path, mime}`; `CoreClient` (UI process, where the
  Activity and the JNI shim live) opens the share sheet from that answer. `Library` is
  unchanged. Never a broadcast "share now" event.
- **Permission prompting.** `LocalBridge.start()` opens `pwperm://request` via
  QDesktopServices when a scan finds no permission. The core keeps scanning/retrying and
  exposes a persisted `permissionNeeded` flag in its state (below); `CoreClient` opens
  `pwperm://request` in the UI process when it sees it set.
- **The editor** renders in Qt Quick and writes the edited JPEG next to the original, then
  asks for a rescan: an existing, accepted exception to "the UI never touches library
  files" (shared storage makes it work across processes). Documented, not changed in 5b.

## Transport

`QLocalServer` / `QLocalSocket` (QtNetwork, already linked; bound in the DSide cxx-quick
binding for host and Android), used asynchronously through their signals (`newConnection`,
`readyRead`, `bytesWritten`, `disconnected`, `errorOccurred`) — never `waitFor*`.

- **Endpoint:** a full path, `<dataDir>/core.sock`, in app-private internal storage (on the
  host the directory is created 0700 explicitly); `QLocalServer::UserAccessOption`.
  No token: the filesystem is the authentication; nothing is on the network.
- **Single writer:** the core takes an exclusive `flock` on `<dataDir>/core.lock` before
  listening; only the lock holder may remove a stale socket file. A client never unlinks
  the endpoint because one connect failed. `PW_CORE_INPROC=1` (development: old
  single-process wiring) takes the same lock, so it can never share writable state with a
  running service.
- **Framing:** newline-delimited JSON, parsed incrementally across partial reads and
  multiple frames per read. Limits: 32 MiB per frame (a remote `photo.get` preview is the
  largest today — and 5b moves it to a file, see below), 64 MiB of queued output per client
  (a client over it is disconnected, never silently dropped frames), 1024 outstanding
  requests per client, and a per-event-loop-turn budget for frames processed.
  `QLocalSocket::setReadBufferSize` bounds Qt's buffer; the line accumulator has the same
  cap. Envelopes are validated (object; integer `id`; string `method`; `params` object/null).
- **Big payloads stay off the socket:** uploads are already core-side (`photo.upload {id}`;
  the 15 MB preparation and `requestRaw("library.import")` happen inside `LocalBridge`).
  The remote `photo.get` base64 preview (`fileUrl` as a `data:` URL) is written by the core
  to `<dataDir>/previews/` and returned as a `file://` URL instead.
- **Files are published atomically** before their URL is exposed: thumbnails/previews are
  written to a temp name in the same directory and renamed.

## Sessions and state

One active UI session at a time. A new connection supersedes the old one: the core writes a
terminal `session_superseded` event to the old client and closes it with
`disconnectFromServer()` (which DRAINS pending output — `abort()` would discard the terminal
event and the old UI would take the close for a crash and reconnect), bounded: if it has
not drained within 1 s the core aborts. Its later replies are discarded. On the client side a
UI that saw `session_superseded` never auto-reconnects; one that merely lost the socket does,
but its first frame after connecting is `core.hello {uiInstance}` and the core refuses a
reconnect from an instance it has already superseded in favour of a live one — so two UIs
cannot evict each other in a loop even when the terminal event is lost. Background sync is not tied
to a UI session and continues regardless.

`LocalBridge`'s paging state is global, so it gains two generations:

- **session generation** — bumped on a new session; every asynchronous continuation that
  mutates session-owned paging state checks it before mutating (not merely before
  replying): `fillPage`'s computer reply (remoteDone, totals, offsets, dedup counts,
  buffers → `mergeAndAnswer`), `mergeAndAnswer`'s completion (captures the response
  offset instead of reading `served.length` later), and `fetchThumbs`' two callbacks
  (thumbnail-cache publication may outlive a session; patching `served` may not).
- **paging generation** — bumped on every offset-zero reset. Overlapping page operations
  within one session are serialized (load-more coalesced), and a superseded page request is
  completed with an error, never left pending.

(Multiple simultaneous clients would need per-session paging state; not in 5b.)

Three separate states, never conflated:

1. **socket connected** — `CoreClient` has a QLocalSocket;
2. **core ready** — the core sent its state snapshot;
3. **computer connected** — `computer.link`, as today.

On every connection the core first sends a `core.state` event — `{endpoint,
computer: {connected, endpoint}, sync: <the sync.status payload>, indexing: {active,
imported, skipped, total}, pairingCode, permissionNeeded}` — and only then answers requests.
The events `Library` consumes today, exactly (backend.d `onEvent`):

| event | payload |
|---|---|
| `computer.link` | `{connected, endpoint}` |
| `pairing.code` | `{code}`, cleared with `{done: true}` |
| `sync.status` | `{enabled, connected, active, pending, total, done, sent, skipped, failed, error}` |
| `index.progress` | `{imported, skipped, total}` — sets indexing on + progress text |
| `index.done` | `{imported}` — clears indexing, reloads dates/roots/page |

`CoreClient` applies the snapshot through an explicit `Library.applyCoreState(...)` (not by
manufacturing events: a fake `index.done` would trigger reloads): computer link, pairing,
sync status, and indexing — including RESETTING a stale "indexing" spinner when the core
comes back idle. Only then does it report `onConnected(true)`; `Library.onLink(true)`
re-reads collections and the first page as today. The open viewer keeps what it shows (its
file and data stay valid); re-opening it by id — so swiping works again — waits for the
paging session (stage 3), because `photo.neighbours` answers from the pages served in the
current session, which the reconnect's `refresh()` starts over.

After the snapshot the core keeps the UI current with the live events in the table above
(snapshot-backed: each is also a field of `core.state`), plus one dedicated event for the
state the table does not carry: `core.permission {needed}` — sent whenever the core's
permission check flips either way (a scan that finds it missing, a grant that clears it),
since the first snapshot can be sent before the first scan knows.

`endpoint()` is served from `CoreClient`'s cache. `setEndpoint(host, port)` updates the
cache **optimistically at once** (`Library.setEndpoint` reads `endpoint()` immediately
after) and sends `bridge.setEndpoint`; the core's `core.state` confirms or corrects it.

### Failure semantics

- Requests made before "core ready" (QML calls `loadDates()` during component completion)
  are queued, bounded by count (1024) AND bytes, with an absolute 15 s deadline that
  survives reconnect attempts, and sent on readiness.
- Output limits count application buffers plus `QLocalSocket.bytesToWrite()`. Responses
  and events are validated like requests; duplicate outstanding ids are rejected; partial
  writes resume on `bytesWritten`; when the per-turn read budget runs out the rest is
  scheduled (a zero-timer), not left for the next `readyRead`. Discarding a connection
  uses `abort()` (drops buffered output), never `disconnectFromServer()` (drains it).
- Reentrancy: a request issued from inside a failure callback goes to the (new) pending
  queue, never into the map being failed.
- On disconnect: mark unavailable, detach the pending map and the output buffer, **then**
  fail each pending callback once with `{code: "core_restarting"}` (`Bridge.failAll` gains a
  code parameter; `"disconnected"` stays the default). Unsent frames are dropped, never
  replayed. A lost reply to a mutation means "outcome unknown", not "did not happen" —
  callers already re-read state on reconnect.
- Callbacks are keyed by (connection generation, id).
- Reconnect: every 100 ms for the first 2 s (the core is starting), then backing off to 2 s
  — a missing socket may be a deliberately stopped service, not a crash. `MainActivity`
  (re)starts the service on every `onStart`.

## Core-side notes

- `QImageReader` (with `setScaledSize`), `read(QImage*)`, pixel reads and `QImage.save` need
  only a QCoreApplication (QAndroidService here): no `QPainter`, `QPixmap` or fonts are used.
  Keep the pointer/in-place image APIs (by-value `QImage` returns are a known binding gap).
- Face models are extracted with `QFile.copy("assets:/…")` and inference may try the LiteRT
  GPU path first (CPU fallback): both need a device test in the service process.
- The video-thumbnail shim (`MediaMetadataRetriever.setDataSource(String)`) needs an
  attached `JNIEnv` and readable paths — no Context.
- Nonblocking sockets do not make decodes/inference nonblocking: the core's Qt thread still
  runs them synchronously, so an RPC can wait behind one decode.

## Host builds

The UI starts the core as a child: `thisExePath() -service`, inheriting `PW_PHONE_ROOTS`,
`PW_ENDPOINT` and the XDG data dirs, and waits asynchronously for the socket. The UI owns
that child: it observes its exit (QProcess `finished`) and restarts it after an unexpected
death — not after an intentional shutdown, and not when the child exited because another
core holds the lock (then the UI just connects to that one). It only ever terminates/reaps
a child it started. `PW_CORE_INPROC=1` keeps the old single-process wiring for quick UI
work; it routes sharing and permission prompts through the same UI adapter as the split
mode, so removing them from `LocalBridge` does not break it.

## Lifecycle

- `CoreService`: foreground while auto-sync is on (the request carries the decision;
  `onStartCommand` promotes/demotes a live service; Android 15+'s dataSync budget ends
  through `onTimeout` → leave the foreground, stop); a plain started service otherwise,
  (re)started on every activity start.
- 5c (done): the sync-status notification (id 1), the partial wake lock (held only while a
  photo is going) and the status watcher live in `CoreService`, the core's process;
  `SyncService` is gone. MainActivity only asks for the notification permission.
- **Shutdown contract.** `PhoneIndex.saveNow()` today starts a daemon writer and returns
  (and skips when a save is already running) — not a flush. The core gets an owned save
  worker and ONE idempotent `shutdown(deadline)` shared by `onTimeout` and `onDestroy`
  (whichever comes first sets an absolute deadline ~2 s out; the second call just waits
  on the first). In order: stop admitting RPCs, stop sync/network callbacks and the index
  producers (scan/decode/face pumps — the face worker finishes or abandons its one photo),
  then join the running save and write the latest dirty snapshot, exit. The data
  directory's lock is held until the process exits (the kernel drops it after the last
  writer — a save cut short by the deadline, the p2p thread — is gone), never released
  early.
  The deadline bounds the NATIVE work, not only Java's wait: every step checks it, and on
  expiry the core skips straight to exit — the periodic atomic checkpoints (written
  temp-then-rename) are what a cut-short shutdown or a hard kill falls back to, so at most
  the last checkpoint interval is lost. The SIGTERM/SIGINT handler's immediate `_exit`
  stays the last resort.
- The core's `serviceMain()` must run the same Qt-thread TLS registration the UI's startup
  does on Android (`pinThreadTls`), and the permission prompt waits for the Activity
  window, is not repeated while one is showing, and `permissionNeeded` is re-checked
  against the actual permission (an empty scan alone is not a denial).
- Memory: both processes link the same `.so` (Qt Quick/QML/Gui included); measure PSS of
  both, not RSS sums.

## Implementation stages (each a runnable, reviewed commit)

1. **Extract core construction and the UI actions.** One function builds
   PhoneIndex/P2pBridge/LocalBridge; sharing and permission prompting move out of
   `LocalBridge` into a UI adapter. Still one process.
2. **Authoritative state and recovery.** The `core.state` schema, `Library.applyCoreState`,
   indexing reset, `core.permission`; reconnect tested in-process by dropping the bridge
   (`PW_TEST_RELINK=<s>[:<gap>]`, events lost while down). Done.
3. **Paging ownership.** Session and paging generations, overlap handling, viewer re-open
   with its neighbours; tested with deliberately delayed/reordered computer replies
   (`PW_TEST_PAGING=full|deadline|deadline2` + `PW_TEST_PAGE_DELAY`, `PW_TEST_VIEWER`). Done;
   thumbnail completions also moved onto the Qt thread (they ran on the libp2p thread).
4. **Process-safe persistence and files.** Single-writer lock, stale-socket rule, atomic
   thumbnail/preview publication, preview files, owned save worker + synchronous flush.
   Done (`corelock.d`, `atomicfile.d`, `IndexSaver`, `PhoneCore.shutdown`); the
   stale-socket rule lands with the socket (stage 5).
5. **Framing and transport.** `CoreServer`/`CoreClient` over QLocalServer/QLocalSocket with
   the limits above; tests for fragmented/coalesced frames, malformed envelopes, duplicate
   ids, limits, backpressure, reentrancy.
   Done (`coreipc.d`; `mobile/tests/core_socket_test.py`). The host core is
   `photo-wagon-mobile -service`; a UI with `PW_CORE_SOCKET=<dataDir>/core.sock` is its
   client. The socket path must fit sun_path (107 bytes).
6. **Host child mode.** Readiness barrier, queues/deadlines, restart supervision,
   supersession; kill either process and reconnect to a surviving core.
   Done (`corehost.d`): the default on the host; `PW_CORE_INPROC=1` keeps one process (the
   in-process test hooks need it), `PW_CORE_SOCKET` uses a core started elsewhere. The UI
   asks its child to `core.quit` on exit (orderly shutdown), restarts it after an unexpected
   death (backing off 0.5 s doubling to 10 s, reset after a minute alive), defers to a
   core that holds the lock (child exit 3) and starts its own when none is reachable.
7. **Android service ownership.** The core moves into `:core` for real; lifecycle →
   native shutdown, permission/share integration, TLS init; device tests: cold start, UI
   death, core death, permission grant, sharing, image/video decode, faces, foreground
   timeout. The notification/wake-lock move is a separate 5c commit.
   Done: `-service` builds and serves the core on Android too (TLS pinned on its Qt thread;
   aboutToQuit → shutdown when QtServiceBase quits); MainActivity's UI is a CoreClient to
   `files/core.sock`; CoreService extracts the face models with the AssetManager before Qt
   starts (the windowless service has no `assets:/` engine); the UI asks MainActivity to start
   the service (`pwcore://start`, backing off 2 s → 30 s) while the core stays gone — Android
   does not restart a service that crashes twice in quick succession. Waydroid-tested: cold
   start, core crash (restarted by Android; again → by the UI), UI crash (the core survives,
   the relaunched UI attaches), permission revoke → prompt → grant → rescan, share sheet,
   video frame via JNI in the service, a face detected in the service. Not reproducible on
   the rig: the Android 15 foreground-time budget (onTimeout).

