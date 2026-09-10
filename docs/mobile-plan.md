# Mobile plan — from "works" to "feels like Photos"

State on 2026-09-10. The phone app (`mobile/`) proves the stack: D + DSide on
Android, the phone's own photos, pairing by QR, a merged timeline with the
computer. As a product it is rough. This is the plan to make it good, in the
order the pieces unblock each other.

## What is bad today, honestly

| symptom | cause in the code |
|---|---|
| First launch freezes/janks for minutes on a big camera roll | `PhoneIndex` decodes every thumbnail with `QImageReader` **on the UI thread**, one per event-loop tick (`phoneindex.d`) |
| Thumbnails take long even on the second launch after a reinstall | the JSON index lives in app data but the JPEG cache is in the cache dir; either missing → full decode again |
| The grid looks like a shrunken desktop | 2 columns of 184 px cells, a "Load more" button, a dates drawer, English strings, dark theme only (`qml/mobile/*`) |
| The viewer is unusable with fingers | no swipe between photos, no pinch/double-tap zoom, arrows meant for a mouse, Android back button closes the app instead of the viewer |
| Scrolling the merged timeline stutters | every remote page carries thumbnails as base64 inside one JSON string that crosses the meta-object; nothing is cached on disk |
| Numbers are off with a computer paired | dates are the sum of both sides without dedupe; remote/local dedupe is by name + size only |
| The photo you took a minute ago is not on the computer | nothing is automatic: "Send all" is a button, sending is one file at a time, no retry, no progress beyond a status line |
| Pairing needs the desktop's "Phone" button and the same Wi‑Fi | no discovery; the token is fine, the address is typed by the QR only |
| Memes and screenshots flood the phone timeline and get backed up | the kind classifier runs only on the computer |
| 34 MB debug APK, generic icon, no splash, `photo-wagon-mobile` as the display name | never packaged for release; every QtQuick.Controls style bundled |

## Principles

- **Same core ideas as the desktop, phone-first shapes.** Library / Albums /
  Search tabs at the bottom, Years / Months / Days / All at the bottom of the
  library, 4–5 columns, gestures everywhere. The phone is not a small desktop.
- **Never block the UI thread.** Decoding, hashing, uploading and classifying
  run on D worker threads; the UI thread only touches QObjects and strings.
- **The computer is the library; the phone is a camera roll with a view of it.**
  New photos flow to the computer automatically. Nothing on the phone should
  need the computer to be usable offline.
- **Measure on the device.** Every phase ends with a number taken on the
  Samsung: cold start, scan time for N photos, frames dropped while scrolling,
  APK size.

## Phase 0 — foundations (performance, one week) — items 1 and 5 done 2026-09-10 (worker threads, sha256 in the index); 2–4 open

1. **Thumbnails off the UI thread.** A D worker thread (`core.thread`) takes
   paths from a queue and produces 256 px JPEGs with `QImageReader` (safe off the
   GUI thread: it is a value type, not a QObject). Results come back through the
   same pipe/`QSocketNotifier` pattern the desktop `CoreBridge` uses. Three
   workers on a phone; the UI shows placeholders and fills in.
   *Target: 3,000 photos indexed in under 60 s without a dropped frame.*
2. **EXIF thumbnails first.** Camera JPEGs carry a 160×120 thumbnail in IFD1;
   `exifparse.d` learns to return its bytes. Use it as the placeholder until the
   real 256 px one exists. *Target: the grid is full within 5 s of the permission.*
3. **One durable cache.** Index and JPEGs both under app data (not the cache
   dir), keyed by `path + size + mtime`, with a size cap and LRU trim.
4. **Pages without base64.** Remote thumbnails are written to that same cache
   as files once (`library.thumbs` → disk) and served to QML as `file://`; the
   page JSON stays small. The desktop core gains `library.thumbsSince` to fetch
   only what the phone lacks.
5. **Content hashes for dedupe.** SHA-256 on the worker thread, stored in the
   phone index; the merge dedupes by hash first, name+size as fallback; date
   counts are computed from the merged set, not summed.

## Phase 1 — a phone UI (two weeks)

1. **Shell**: bottom tab bar Library · Albums · Search; light/dark from the
   system (`Application.styleHints.colorScheme`), Material style pinned,
   Portuguese and English strings (`qsTr` + a `.ts` file; the D side already
   builds with lupdate support in DSide).
2. **Library**: segmented Years / Months / Days / All Photos pinned at the
   bottom; 4 columns (pinch changes 3–5); square cells with 1 px gaps; sticky
   day/month headers; a right-edge scrubber with the month name while dragging;
   long-press enters selection (checkmarks, count in the title, Share / Send /
   Favorite / Delete-from-phone actions).
3. **Viewer**: horizontal `ListView` with `snapMode`, swipe left/right,
   `PinchHandler` + double-tap zoom, drag-down to close, tap toggles chrome,
   bottom bar (share via Android intent, favorite, info sheet, send), the
   Android back button closes the viewer (`onClosing` on the window).
4. **Info sheet**: bottom sheet with date, size, camera, location, kind, and the
   people in the photo when the computer knows them.
5. **Albums tab**: the computer's albums as cards with covers; on the phone,
   Favorites and Screenshots as smart albums. Search tab: person names, years,
   months, "screenshots", "memes" (client-side over what is loaded, then the
   computer's `library.page` filters).
   *Target: every screen usable one-handed; no mouse-only affordance left.*

## Phase 2 — automatic backup (one week) — done 2026-09-10 (queue in the index, hash probe, notification via SyncService; binary frames and "free up space" still open)

1. **Backup service on the phone**: when connected to the computer (and on
   Wi‑Fi unless the user allows mobile data), every new *photograph* (not
   screenshots/memes, see phase 3) is uploaded in the background, oldest first,
   with retries and a resumable queue persisted in the index. A "Backup" card
   at the top of Library shows "1,234 of 1,240 backed up · 6 waiting".
2. **Uploads in chunks**: `library.import` accepts `{name, size, sha256}` first;
   the computer answers "have it" or "send"; bytes go as raw frames after the
   JSON line (`docs/ipc.md` gets a binary-frame rule) instead of base64. This
   halves the traffic and removes the 16 MB line cap risk on large photos.
3. **Free up space**: after a photo is confirmed on the computer, the phone can
   offer "Keep only the thumbnail on the phone" for photos older than N months
   (explicit, per album/date range, never automatic).

## Phase 3 — smarter phone (one week)

1. **Kinds on the phone**: `imageStats` reimplemented on the decoded pixels the
   worker already has (the vips version stays on the desktop), same `kind.d`
   rules and model. Screenshots and memes get their own smart albums and are
   excluded from backup by default (toggle in settings).
2. **Discovery** (the phone is a libp2p peer since 2026-09-10; still to do: finding the computer without the QR): the computer broadcasts a small UDP beacon on the LAN
   (`photowagon` magic + port + a hash of the token); the phone listens with
   `QUdpSocket`, so a paired phone reconnects on any network where the computer
   is, without the QR again. The QR stays for the first pairing and for the
   token.
3. **Faces on the phone** — done 2026-09-10, both ways: the computer's faces for the
   phone's photos (matched by hash), naming from the phone through `face.setPerson`.

## Phase 4 — shipping (three days)

1. Release build: signed APK/AAB, `--release` in `build-android.sh`, only the
   Material style bundled (`QT_QUICK_CONTROLS_STYLE` + `qml-import-paths`
   pruning), stripped `.so`. *Target: under 20 MB.*
2. Icon, splash, display name "Photo Wagon", version from git.
3. Crash reporting to a local log the user can share from the settings page.
4. Android 15+ permission flows (partial photo access) handled.

## What not to do

- No core (SQLite, vips, libp2p) on the phone in this cycle: its native
  dependencies have no Android builds here; the phone stays a client of the
  computer's library plus its own camera roll.
- No Kotlin UI. The UI stays D + QML; Java only where Android forces it
  (permissions, intents, scanner), as today.

## How each phase is verified

- Phase 0: `adb logcat` timings from the D side (`phone: indexed N in S s`),
  `dumpsys gfxinfo org.photowagon.mobile` for dropped frames while scrolling.
- Phase 1: screenshots of each screen from the device (`adb exec-out screencap`)
  and the offscreen desktop build of the phone client for regression.
- Phase 2: `tests/e2e.py` gains a phone-backup scenario against a headless core.
- Phase 4: APK size in CI.
