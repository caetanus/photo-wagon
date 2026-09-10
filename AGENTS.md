# AGENTS.md — how to work in this repository

Photo Wagon is a local-first photo manager in one D program: Qt Quick UI (DSide
binding) on the main thread, a core on vibe-core (indexer, store, libp2p-dlang)
on a second thread. Read `ARCHITECTURE.md` and `docs/ipc.md` before changing
anything that crosses the UI/core boundary.

## Non-negotiables

1. **No cloud.** User data never requires a remote service. Sharing is
   peer-to-peer over libp2p, and only for albums the user explicitly published.
2. **Layers.** UI → link → core → (db, store, files). The UI never opens a
   file or the database. Nothing under `core/` imports Qt; nothing under `ui/`
   imports vibe or touches a core object directly.
3. **Open metadata.** Read EXIF/XMP/IPTC through gexiv2; never write to originals.
4. **Small files, one responsibility each.** When a module grows a second
   concern, split it. No "utils" dumping grounds, no megazord files.
5. **D everywhere.** No C++ shims unless a library has no C API. If one is
   unavoidable it lives in `csrc/` with a one-paragraph justification (today:
   `face_opencv.cpp`, because OpenCV 5's face classes have no C API).

## Core rules (vibe-core)

- Blocking calls end with a result or a throw. No sentinel returns.
- Every `runTask` has an owner whose `close()` interrupts and joins it.
- CPU-bound work (hashing, vips) goes through `vibe.core.concurrency.async`;
  SQLite is used only from the core thread.
- Emit events through `ipc.Events`, never write to a socket or the link from a service.
- The core never touches a QObject; it only ever hands strings to `InProcessLink`.
- Read `~/.claude/skills/dlang` before touching GC-sensitive or `nothrow` code.

## UI rules (DSide)

- Read `~/.claude/skills/dside` first. Its three compile traps
  (`cast(QWindow) null`, `QUrl(…, ParsingMode)`, no rvalue to `ref const`) bite
  every session.
- One `@QObject` facade (`Library`). Lists cross to QML as JSON strings, one page
  at a time. `@Slot` returns `void`, always.
- Never create a `QObject` off the main thread. The binding aborts. Everything
  from the core arrives through `CoreBridge` on the Qt thread; keep it that way.
- Run with `QT_FORCE_STDERR_LOGGING=1`; check `engine` load status after `load`.
- Keep QML declarative and thin: no fetching, no parsing beyond `JSON.parse` of a
  property the backend already prepared.
- Desktop QML lives in `qml/` (Photos-style: `Main`, `Sidebar`, `PhotoGrid`,
  `TileGrid`, `PhotoViewer`, `PeopleView`, `Icons`); the phone keeps its own
  copies under `qml/mobile/`. Icons are inline SVG data URLs (`Icons.qml`);
  round portraits use `Icons.ringMask` (a fat-border Rectangle does not clip).
- Headless captures: `PW_SHOT=/path.png` plus `PW_SHOT_VIEW=people|days|months|years`,
  `PW_SHOT_VIEW=date:YYYY[-M[-D]]` (a node of the tree), `PW_SHOT_VIEW=person:<id>`,
  `PW_SHOT_VIEW=name:<text>` with `PW_SHOT_OPEN` (the naming popup, `<text>` typed),
  `PW_SHOT_OPEN=<id>` (viewer with Info), `PW_SHOT_SEND=1` (pairing panel).
- `Sidebar.qml` is a Column in a Flickable, not a ListView over an ObjectModel:
  a Repeater inside an ObjectModel piles its delegates at (0, 0).
- The date tree and the Years / Months tiles come from `library.dates`, which
  takes the same filter as `library.page`: a person's tree is that person's years.

## Verifying a change

```sh
dub build --compiler=ldc2 && dub test --compiler=ldc2
tests/e2e.py <folder with nine images>                 # two headless nodes over libp2p
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software PW_SHOT=/tmp/s.png ./photo-wagon
```

`dub test` must stay green. There is no test that needs a display.
