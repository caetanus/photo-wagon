# Photo Wagon

Local-first photo manager with Qt/QML UI and an integrated D indexer service.

## Build (Meson)

### Requirements

- Meson and Ninja
- Qt 6 (Core, Gui, Qml, Quick, Concurrent, Sql)
- D compiler (`ldc2`, `dmd`, or compatible)
- Runtime tools available in `PATH`:
  - `exiv2`
  - `vipsthumbnail`
  - `vipsheader`

### Standard build

```bash
meson setup build-meson
meson compile -C build-meson
```

### Build with subproject source auto-download

```bash
meson setup build-meson -Dauto_download_subprojects=true
meson compile -C build-meson
```

### Force Meson fallback wraps (when dependencies are wrapped)

```bash
meson setup build-meson --wrap-mode=forcefallback -Dauto_download_subprojects=true
meson compile -C build-meson
```

### Manual subproject download

```bash
meson subprojects download --sourcedir .
```

or after setup:

```bash
meson compile -C build-meson deps-download
```

### Run

```bash
./build-meson/photo-wagon
```

## Notes

- The app builds as a single `photo-wagon` binary with C++ + D linked together.
- Wrap files are present in `subprojects/` for source download convenience.
- Current indexer integration uses `exiv2`, `vipsthumbnail`, and `vipsheader` as runtime tools from `PATH`.
