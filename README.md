# Photo Wagon

Local-first photo manager. Qt Quick UI written in D, a D daemon that indexes
your photos, and libp2p for sharing albums directly between machines.

Everything runs on your computer. Nothing is uploaded anywhere unless you share
an album with a peer you chose.

## Requirements

- `ldc2` (1.42+) and `dub`
- Qt 6.11 with the DSide binding built at `~/lab/qt-dlang-gen`
  (`generated/qt-6.11/cxx-quick` + `.build/qt-6.11-cxx-quick/libbinding_ldc2.a`)
- `libp2p-dlang` checked out at `~/lab/libp2p-dlang` (and its sibling `d-webrtc-v3`)
- System libraries: `sqlite3`, `gexiv2`, `vips`, `libsodium`, `openssl`, `c-ares`

## Build

```sh
./build.sh            # builds daemon/ (dub) and ui/ (ldc2 against DSide)
./build.sh daemon     # just the daemon
./build.sh ui         # just the UI
```

## Run

```sh
./ui/photo-wagon      # spawns ./daemon/photowagond if none is running
```

Or run the daemon by hand and watch it:

```sh
./daemon/photowagond --data ~/.local/share/photowagon
```

When the UI spawns the daemon, the daemon's output goes to
`~/.local/state/photowagon/daemon.log`.

Headless smoke test of the IPC protocol (see `docs/ipc.md`):

```sh
printf '{"id":1,"method":"daemon.hello"}\n' | nc 127.0.0.1 "$(cat "$XDG_RUNTIME_DIR/photowagon/daemon.port")"
```

End-to-end test with two daemons (index, publish an album, fetch it over libp2p):

```sh
cd daemon && dub test && tests/e2e.py /some/folder/with/nine/images
```

Headless UI check with a screenshot:

```sh
QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software PW_SHOT=/tmp/shot.png ./ui/photo-wagon
```

## Layout

```
daemon/    photowagond — vibe-core, SQLite, gexiv2, vips, libp2p-dlang
ui/        photo-wagon — D + DSide (Qt Quick), QML under ui/qml
docs/      ipc.md — the wire protocol between the two
models/    face-detection models (used from milestone 3 on)
legacy/    the previous C++/Qt + D prototype, kept for reference only
```

See `ARCHITECTURE.md` for how the pieces fit and `ROADMAP.md` for what is done.
