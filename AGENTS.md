# AGENTS.md — how to work in this repository

Photo Wagon is a local-first photo manager: Qt Quick UI in D (DSide binding),
a D daemon on vibe-core, libp2p-dlang for sharing. Read `ARCHITECTURE.md` and
`docs/ipc.md` before changing anything that crosses the UI/daemon boundary.

## Non-negotiables

1. **No cloud.** User data never requires a remote service. Sharing is
   peer-to-peer over libp2p, and only for albums the user explicitly published.
2. **Layers.** UI → IPC → daemon → (db, store, files). The UI never opens a
   file or the database. The daemon never imports Qt.
3. **Open metadata.** Read EXIF/XMP/IPTC through gexiv2; never write to originals.
4. **Small files, one responsibility each.** When a module grows a second
   concern, split it. No "utils" dumping grounds, no megazord files.
5. **D everywhere.** No C++ shims unless a library has no C API. If one is
   unavoidable it lives in `daemon/csrc/` with a one-paragraph justification.

## Daemon rules (vibe-core)

- Blocking calls end with a result or a throw. No sentinel returns.
- Every `runTask` has an owner whose `close()` interrupts and joins it.
- CPU-bound work (hashing, vips) goes through `vibe.core.concurrency.async`;
  SQLite is used only from the main fiber thread.
- Emit events through `ipc.Events`, never write to sockets from a service.
- Read `~/.claude/skills/dlang` before touching GC-sensitive or `nothrow` code.

## UI rules (DSide)

- Read `~/.claude/skills/dside` first. Its three compile traps
  (`cast(QWindow) null`, `QUrl(…, ParsingMode)`, no rvalue to `ref const`) bite
  every session.
- One `@QObject` facade (`Library`). Lists cross to QML as JSON strings, one page
  at a time. `@Slot` returns `void`, always.
- Never create a `QObject` off the main thread. The binding aborts.
- Run with `QT_FORCE_STDERR_LOGGING=1`; check `engine` load status after `load`.
- Keep QML declarative and thin: no fetching, no parsing beyond `JSON.parse` of a
  property the backend already prepared.

## Verifying a change

```sh
./build.sh                                  # both halves compile
./daemon/photowagond --data /tmp/pw-test &  # then drive it with nc, see README
QT_QPA_PLATFORM=offscreen QT_FORCE_STDERR_LOGGING=1 ./ui/photo-wagon
```

The daemon's `dub test` must stay green. There is no test that needs a display.
