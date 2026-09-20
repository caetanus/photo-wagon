# Photo Wagon — Your everyday photo library · round 2

Open **[index.html](index.html)** directly. **43 phone studies** at 390 × 844 preserve the warm light/dark contact-sheet palette, typography, inline illustrations, gestures and feature coverage from round 1. The original 24 studies remain, revised in place; 19 added studies cover Search, Library, people, places, scenes/moods, memories and the larger-library interactions. All imagery is original inline SVG, including the receipt, document and schematic map. Links navigate examples; CSS editor tabs, native inputs and disclosure panels are inspectable. Search, gestures, transfers and deletion are **mockups**, not executable app operations.

## Direction: the app you open instead of Google or Apple Photos

The phone is a primary photo app: browse, find, edit, organize and revisit a life in photos. The paired desktop holds the full library and heavy compute. Phone originals remain useful with no link. The hero now reads **“All your photos. More ways to find them.”** The computer is a clearly visible device and storage destination inside that experience.

Keep paper `#f8f7f1`, moss `#335b42`, charcoal `#19211d`, amber interruptions, system sans in the app, serif in the presentation, square narrow-gutter thumbnails and rounded grouped controls. This is an IA and capability expansion, not a new visual identity.

**Two implementation truths must coexist:** desktop search/discovery already exists, while phone-local CLIP, OCR, face indexing and memories are a required target, not a shipped mobile feature. The offline studies intentionally show a complete, ready phone index, plus a separate partial/unavailable-index state. Do not implement the ready-state copy before that local capability exists. No cloud service or account is introduced.

## Competitor research and decisions

Reviewed on 19 September 2026. Documentation establishes behavior; the decisions below are design judgments, not usability test findings. Interface versions and rollouts vary, so copy navigation principles rather than a particular competitor's exact tab labels.

| Reference | Grounded example | Decision in these mockups |
| --- | --- | --- |
| **Google Photos** | Search finds people, places, things and documents, including descriptive phrases; its Android backup guide explains aggregate and individual backup states. [Search guide](https://support.google.com/photos/answer/15235862?co=GENIE.Platform%3DAndroid&hl=en), [backup and per-item status](https://support.google.com/photos/answer/6193313?co=GENIE.Platform%3DAndroid&hl=en). | Borrow a prominent Search destination with People first, Places preview, categories and recent searches (26). Connect aggregate sync status to each asset, replacing account/cloud semantics with a specific paired desktop. Memories are one tap away. |
| **Apple Photos** | iOS 18's single-scroll redesign drew complaints; iOS 26 restored tab navigation. [Contemporary reversal report](https://9to5mac.com/2025/06/09/ios-26s-photos-app-re-adds-the-tab-bar-a-major-design-reversal/). Apple's current guide documents temporal views, reachable Search and pinch density. [Library browsing](https://support.apple.com/guide/iphone/browse-your-photo-library-iph7d24753a5/ios), [viewer](https://support.apple.com/guide/iphone/view-photos-and-videos-iph3d267610/ios). | Keep three explicit tabs and stable ordering. Put auto-collections in Library/Search; don't extend Photos into an endless personalized dashboard. Preserve day/month/year navigation and add pinch, a date rail, filmstrip and details (01, 38, 41). A one-time migration note explains re-homing (25). |
| **Immich** | The closest server-library/mobile-client analog. CLIP, OCR, people and location filters coexist; reverse-geocoded locations support discovery. Its optional asset storage indicator distinguishes local-only from synced assets, and selection exposes Upload. [Search](https://docs.immich.app/features/searching/), [mobile asset indicators and selection](https://docs.immich.app/features/mobile-app/), [mobile backup](https://docs.immich.app/features/mobile-backup/), [locations](https://docs.immich.app/features/reverse-geocoding/). | Borrow the separation of Search/Explore/People/Map and an inspectable backup queue. Always expose all three original-location states. “214 left” is the unique set of unverified revisions, including failed items, not a sum of overlapping device albums (42). No silent full-queue blockage from one bad asset. |
| **Ente** | Its search documentation covers dates, filenames, descriptions and albums, plus on-device face recognition, CLIP natural-language search, location labels and memory discovery. [Search and discovery](https://ente.com/help/photos/features/search-and-discovery/). | Keep a clean field and explicit named collections. On-device indexing demonstrates that privacy and useful local search can coexist; Photo Wagon still needs that phone implementation. Manual albums retain their calm jackets beside automatic collections (08, 25–37). Ente uses encrypted servers; it is not a no-server product. |

The user-supplied “Immich over-count” example is treated as a failure mode to prevent, not an independently reproduced bug or a claim about every current Immich release. Likewise, do not claim that competing photo apps universally fail offline. Our particular advantage is a complete phone index plus an explicitly modeled intermittent peer, without requiring a cloud account.

## Information architecture

Commit to **Photos · Search · Library**. This separates three stable intents: browse by time, find something, and revisit collections/manage devices. Search never depends on opening Library. Sync remains first-class through the timeline strip, asset badges, Library's permanent device row and its pending/offline nav marker.

| Destination | Contains | Navigation contract |
| --- | --- | --- |
| **Photos** | All-photo timeline, phone-only scope when desired, date tree, sticky date headings, density, date scrubber, select, viewer/editor | Preserve scroll and visible asset identity. One merged original per content/revision identity, not duplicate phone/desktop tiles. Desktop-only previews are visibly distinct. |
| **Search** | Persistent field; People; Places map peek; scenes, things, moods, weather, holidays; memories/moments shortcuts; recent searches; combined results | Source scope and index readiness sit next to the query. Person/place/category results keep a back route to the originating search view. |
| **Library** | Fixed-order Albums, People, Places, Memories, Moments & trips, Scenes & moods, Computer & sync | Manual albums and automatic collections coexist. Computer contains pairing, challenge, endpoint/change, Send all, Auto-sync, queue, foreground catch-up and Rescan. |
| **Viewer / overlays** | Swipe pager, filmstrip, zoom, face naming, Edit, Send/fetch, swipe-up details | Immersive viewer temporarily hides tabs, as in round 1; closing restores the originating Photos/Search/Library tab, filter and scroll. Sheet → overlay → viewer → route → Photos → exit is Back precedence. |

Library study 25 includes the one-time explanation **“Albums and Computer are now in Library. Search has its own tab.”** Do not reorder Library by engagement. Albums now open within Library; this intentionally supersedes round 1's “open albums in Photos” routing while retaining the grid, filtering, pagination and viewer affordances. Photos remains the reliable all-photo destination. Date-tree scope follows the active person/place/album filter.

Manual albums remain desktop-created, with honest connected-empty, unpaired and offline states. No mobile create/rename/publish/delete album feature is fabricated. That is a remaining capability gap for replacement parity, not a reason to turn the entire phone UX back into a companion.

## Screen map

| Studies | Surface |
| --- | --- |
| 01–06 | Timeline, date tree, filtered/offline day, viewer, face naming, video |
| 07–10 | Five-tool editor, Library albums, album grid, desktop-only original unavailable |
| 11–14 | Pairing, scanner handoff, four-digit confirmation, manual endpoint |
| 15–19 | Live queue, offline interruption, waiting queue, verified completion, retry-needed |
| 20–24 | Access, scanning, no photos, unpaired albums, connected-empty albums |
| 25 | Library and one-time IA migration explanation |
| 26–29 | Search zero-state light, offline zero-state dark, mixed semantic/OCR “praia”, document “boleto” |
| 30–35 | Lia's photos, Places map/list, Paraty photos, For You, scenes/moods, Beach category |
| 36–37 | Offline local search, partial index / no matches / unavailable visual search |
| 38–41 | Swipe-up details, multi-select, scoped deletion review, density/date scrubber |
| 42–43 | Catch up with desktop, explicit connection/pause reasons |

## Feature preservation audit

Re-read both round-1 documents and all eight requested mobile files before editing: `Main`, `PhotoGrid`, `PhotoFocusView`, `EditView`, `AlbumsPage`, `ComputerPage`, `DateTreeSidebar`, `EndpointDialog`. Also read the `Icons.qml` now present in that directory. No application files were edited. Original study IDs 01–24 remain; new studies are 25–43. Numbers are stable cross-references, not a required reading order.

| Current source and capability | Mockup location / treatment |
| --- | --- |
| `Main.qml`: original three tabs, contextual title, filter back, date button, platform light/dark, activity and Computer alert | 01–03, 08–10, 15–24. Activity becomes readable scan/transfer text. Tabs become Photos · Search · Library everywhere; amber marker moves to Library for pending/offline. No marker when verified and connected. Study 25 explains the move. |
| `PhotoGrid.qml`: three-column squares, open photo, sent tick, video glyph and duration | 01, 03, 09. Every known asset gets ↑ phone-only, ✓ verified-both or ↓ desktop-only. Tick requires exact-original revision verification; selection checks are separate at top left (39). Video badge retains `0:24`. |
| Stable accumulated pages, automatic paging and manual Load more with remaining count | 01, 09, 41. Preserve delegate identity and scroll position. Button changes to disabled **Loading more…** while requesting; append without rebuilding earlier rows. Shown rows are a viewport excerpt, not all loaded items. |
| Empty grid / loading | 20–22. Separate initial access explanation, active scan and completed empty scan. A filtered empty grid says **No photos on this date** and offers **All photos**; dates remain available. |
| `DateTreeSidebar.qml`: All photos, year/month totals, day selection, selected-node tap clears filter | 02–03. Every level remains selectable. Close/scrim/Back dismiss; selection filters and closes. Date scope must match the active collection. |
| `PhotoFocusView.qml`: close, previous/next buttons, horizontal swipe | 04–06, 10. Disable unavailable neighbours. Preserve Escape, Left, Right/Space and wheel zoom for hardware keyboard/pointer use. |
| Pinch 1–6×, double-tap 2.5×/reset, pan while zoomed, reset on photo change | 04 annotation. Zoom suppresses face boxes and Edit; swipe navigation resumes when unzoomed. No invented face-toggle control. |
| Detected face boxes, existing name or Who is this?, assign by typed name or known person with face count | 04–05. Naming also opens for already named faces; select the current name for replacement. |
| Nobody, Cancel, Save and keyboard submit | 05. Nobody clears the assignment; Cancel changes nothing; Save/submit needs a nonblank name. Known-person selection assigns immediately. |
| Viewer date/time, camera, dimensions, file size; unknown-date fallback | 04, 06, 10, 38. EXIF, place, people and related memories move into a swipe-up sheet. Use **Date unknown** if missing. Retain original aspect ratio and EXIF orientation. |
| Send individual photo; disabled when disconnected or already sent | 04 enabled; 06 **On the computer**; 10 becomes **Fetch original**, disabled while desktop is offline. Offline unsent variant keeps a disabled Send and the explanation **Connect your computer to send**. No implied offline one-photo queue action. |
| Local Edit only; remote image loading | 04, 06, 07 versus 10. Desktop-only content has no Edit; the target enables it after a verified original is fetched locally. Keep a thumbnail while a full data URL is loading; distinguish wait/error when supported. |
| Video poster, play/pause, scrub, elapsed/total time, 0.5×/1×/2×/3× | 06. Tap video toggles playback; explicit play control remains. The current local-video Edit affordance is retained, with its implementation issue below. |
| `EditView.qml`: Filters, Adjust, Effects, Draw, Crop | 07 has CSS-only selectable tabs. All **27 named presets** remain in the horizontal strip, from Original through Sepia. |
| Brightness, contrast, saturation, warmth | Adjust panel; −100…100 displayed units correspond to −1…1. |
| Fade, vignette | Effects panel, 0…100. Sepia is a preset, not a newly invented adjustment slider. |
| Pen in red/yellow/green/blue/white/black, three brush widths, freehand strokes | Draw panel; retain widths 0.006 / 0.012 / 0.024 of the image frame. |
| Rotate left/right 90°, horizontal/vertical flip, straighten −15°…15° | Rotate panel, renamed from Crop. No aspect-ratio crop or reset button is added. |
| Cancel, undo stack, save new JPEG and rescan | 07. Save copy preserves original, then returns to viewer and refreshes library. Undo remains per adjustment/stroke, disabled with empty history. |
| `AlbumsPage.qml`: album name/initial/count, open in Photos; unpaired and connected-empty messages | 08–09, 23–25. Re-homed under Library, with a back route to Albums. No mobile album creation/deletion or invented covers. Paired-offline messaging must not say unpaired. |
| `ComputerPage.qml`: not paired/offline/connected, endpoint, Pair/Change | 11–19, 25, 42–43 under Library → Computer & sync. Pair opens the existing QR/manual route. Change still exposes the endpoint. |
| Send all, Auto-sync, Rescan, active/batch/pending/completed feedback | 15–19, 11. All controls remain; sending/empty/offline correctly disables Send all. No unsupported manual Pause/Cancel transfer button. |
| `EndpointDialog.qml`: QR scanner launch, host, port 1–65535, Auto-sync, progress summary, OK/Cancel | 13–14. Connect renames OK; requires nonblank host and valid port. Same Auto-sync setting as Computer. |
| `Main.qml`: four-digit challenge, confirm on computer, Later while browsing | 13. QR scans **computer → phone**; digits are typed **on the computer**. Waiting remains findable in Library → Computer after Later. No fabricated expiry. |


### Newly surfaced backend capabilities and interaction work

The desktop modules below were inspected read-only. Existing services are **real**; new mobile routes, source federation, local indexing, coverage metadata and some presentation fields are not implied to exist already.

| Capability / source | Where it appears | Existing versus required |
| --- | --- | --- |
| `core/api/search_api.d`: `search.combined`; `library/clipsearch.d`, `cliptext.d` | 26–29, 36–37. Natural-language examples “praia”, “cachorro na neve”, “aniversário”. | Existing: exact filename/folder/OCR matches first, CLIP semantic neighbours next, deduped by photo ID. Current return `total` is the result count **within the request cap**, not a global exhaustiveness claim; default 200, max 500. Missing text model/worker silently falls back to exact matches. Need phone exposure, explicit semantic availability/coverage, match provenance and local model/index support. Portuguese relevance is illustrative, not a measured multilingual quality claim. |
| `library/ocr.d`: Tesseract; exact-text branch of combined search | 28 photographed “QUIOSQUE DA PRAIA” receipt alongside beaches; 29 “BOLETO” document and related visual receipt | Existing OCR reads selected image candidates, not every original unconditionally. Need query-match snippets/provenance; don't label filename hits as OCR. Local OCR requires a phone port and index coverage. |
| `api/face_api.d`: `people.list`, `photo.faces`, `face.setPerson`; `api/library_api.d` person filter | Prominent portraits in 26–27; Lia timeline 30; faces/details 04–05, 38; familiar-person memory 33 | Existing YuNet + SFace detection/recognition and naming. Preserve the naming sheet's Nobody/Cancel/Save semantics. Need local face processing and names reconciliation for full offline phone operation. Face counts and photo counts are distinct. |
| `api/places_api.d`: `places.list`, `places.suggest`, `photo.setPlace`; `library/places.d`; photo place filter | Map peek 26–27; map + accessible place list 31; Paraty results 32; details 38; place memories 33 | Existing desktop places. New phone map, bounding/grouping handling and offline cartography are implementation work. GPS **pair** `(0,0)` becomes missing location before pinning/geocoding; legitimate points with only one zero coordinate remain valid. Explicit user place labels can remain text without fabricating a pin. |
| `api/tags_api.d`: `tags.list`, `photo.tags`; `library/scenes.d` zero-shot CLIP `scene`, `mood`, `weather`, `holiday` | 26–27 quick categories; four groups in 34; filtered Beach grid 35 | Existing tag groups, counts/covers and tag filters. Need phone routes. Use actual backend vocabulary/localizations, omit unavailable groups or show indexing; do not present suggested moods as inferred human emotions. |
| `api/memories_api.d`: `memories.list/page`; `library/memories.d` | For You 33; Search shortcuts; Library row; related memory in 38 | Existing On This Day, throwbacks, recurring places/people/scenes. Need local generation and federated/cached coverage. Empty state: “More memories will appear as your photo history grows” plus Browse photos; no invented memories. |
| `api/moments_api.d`: `moments.list/page`; `library/moments.d` | Moments & trips in 25, 26, 33 | Existing events split at gaps **longer than six hours**. “Trips” groups/navigation use event place + time; there is no claim of an existing separate multi-day trip classifier. True trip aggregation would need additional work. |
| Pinch density, sticky headings, scrubber | 01, 41; alternative date tree 02 | New interaction target. Pinch 2–5 columns keeps the same visible asset, stops at stable densities, then offers day/month/year buckets. Header sticks within the grid viewport. Drag date rail previews month/year, release jumps; expose keyboard/date-tree alternative and 48 dp touch zone. HTML shows snapshots plus a native illustrative range, not a gesture implementation. |
| Multi-select, whole-day select, scoped removal | 39–40 | New workflow, not an existing delete API claim. Long-press → select checks → contextual bottom actions. Keep state badges bottom right; selection top left. Select-day covers all items in the scoped date, including unloaded ones using stable IDs, never just rendered delegates. Review phone-only originals before destructive confirmation; recheck receipts. |
| Viewer filmstrip and swipe-up detail sheet | 04, 10, 38 | New layout over preserved swipe/pinch controls. Sheet contains EXIF, original state, map/no-location, people, related day/memory. Down/Back collapses sheet; while zoomed, drag pans instead. Unknown EXIF omitted or “Date unknown”. Hardware keys and video controls retained. |
| Original-location states and foreground catch-up | All asset grids/covers, queue rows, filmstrip, 38, 42–43 | Need durable per-original revision identities/receipts, local download cache, queue item events, lifecycle reason signals, fair retries and keep-awake. None can be inferred solely from the current `sent` boolean. |

## Search and offline contract

**Connected:** offer Phone + desktop and This phone scopes. Search the ready local index immediately, then merge desktop results by canonical asset/revision identity without jumping or duplicating the visible item. Label remote originals explicitly. Never count a preview as a locally available original. In this mockup the “praia” result set deliberately contains an OCR receipt and semantic beaches; explanatory match labels are a target extension to today's bare photo result payload.

**Disconnected with ready phone index:** CLIP, OCR, faces and local memories continue; **“Desktop offline · searching this phone”** remains beside the query. Desktop-only originals are excluded from fresh search unless a future deliberately cached search index can prove its scope. Existing preview pixels may remain browsable with an availability label. Search doesn't silently wait for the peer. Reconnection adds desktop coverage and updates the link chip without interrupting the phone task.

**Partial index / missing model:** show searchable modalities and indexed/total counts only when actually reported. Study 37 separates “no matches in indexed phone photos yet” from “the whole library has no matches”. A missing CLIP model falls back to indexed text/filename/date search with an explanation. A paired-but-offline peer is not “unpaired”. Show an indexing progress sentence rather than an endless spinner.

Phone-local CLIP/faces/memories are a **required implementation milestone** for this design. Read-only inspection of `mobile/source/photowagon/mobile/phoneindex.d` and `localbridge.d` does not establish a ready local search engine; merely exposing the desktop RPCs cannot fulfill the offline promise. Persist local indexes and model readiness; don't download a model or send queries to a cloud service as a hidden dependency. A first install can browse originals while indexing; it cannot claim semantic completion immediately.

Recent searches stay local to the device and should be individually removable/clearable when implemented. This storyboard illustrates query shortcuts, not persistent history logic.

### Places: the 0,0 bug

The known Null Island/Tuvalu mis-pin is explicitly a **bug still requiring a code fix**, not fixed by this HTML. Treat `(lat == 0 && lon == 0)`, missing coordinates and invalid/out-of-range coordinates as unavailable for map placement. Apply that before reverse geocoding, map bounds, clustering and place-based auto-collections. Do not reject all equator or prime-meridian locations. Exclude bogus derived place labels from regrouping; keep any legitimate explicit user label as text. Study 31's **No location · 12 photos** disclosure keeps those assets accessible. Details say **No location** instead of presenting a false map. Use bundled or locally cached cartography for phone places offline; no third-party tile service is assumed by these mockups.

## Transfer truth: originals, revisions and directions

| Badge | Exact meaning | Tap / detail behavior |
| --- | --- | --- |
| **↑ Phone only** | Original/revision exists on phone and has no verified desktop receipt. Eligible to push; “queued” only if policy/queue actually includes it. | Show reason: waiting, sending, paused, failed, or Auto-sync off. Connected individual Send retains existing behavior. Offline Send remains disabled; batch eligibility isn't a fabricated offline single-item RPC. |
| **✓ Verified on both** | The **exact current original revision** is locally available and the desktop has acknowledged durable storage with matching identity/content checksum (and revision metadata where applicable). | Show last verification time/peer. A matching filename, old revision, thumbnail, resized JPEG or bytes-at-100% is insufficient. Offline this is the last verified receipt, never a live guarantee. |
| **↓ Original at home** | Desktop original exists; phone has a proxy/thumbnail, not that original. | **Fetch original · 7.8 MB** when reachable. Disabled fetch with **Desktop offline** otherwise. Only verified full download changes this to both; expose Edit only once local original is usable. |
| **Unknown / !** | Missing identity, incomplete loading or failed verification. | Explain the uncertainty; no green check. Placeholder slots aren't evidence of either copy. |

Ownership badges are present on actual asset thumbnails, including result cards, memory covers, transfer previews and filmstrip items. Portraits representing a person, editor preset previews and decorative onboarding prints aren't original asset thumbnails and do not imply backup status. Badges use distinct icons and accessible labels, not color alone. Selection checkmarks are spatially separate from verification checks.

A changed original/revision invalidates the matching green state until reverified. **Save copy** creates a new JPEG identity and a fresh pending state; the previous original keeps its own receipt. Phone-only deletion must name the affected device and warn about an only-known copy. Desktop-copy removal is a separate explicitly authorized action, unavailable offline; there is no inferred cascade or ambiguous “delete everywhere”. This deliverable implements none of these file operations.

### Current telemetry and count rules

Round-1 read-only inspection established that `sendAll` enables Auto-sync and resets attempts; turning Auto-sync off clears queued work, while an in-flight file may finish. Status has `active`, `pending`, `total`, `done`, `sent`, `skipped`, `failed`, `error`, `enabled` and connection state. **`done = sent + failed`**; never call `done` successfully stored. Automatic retry eligibility stops after three failed tries. Current `sent`/acknowledgement is not enough evidence for the stronger revision-verification target.

The existing payload lacks the target file list, bytes, last progress, robust route/reason labels and exact-revision receipt contract. Until those exist, use honest aggregate copy such as **“8 transfers acknowledged · 16 still to send”**, clearly distinguish transfer acknowledgement from verified-current-original storage, and omit green revision claims/file bars. If only legacy `done` is available, say **attempts finished**. Count skipped/already-present only after receiver identity verification. Never fabricate a NAT state, filename or byte bar from elapsed time.

**Remaining** is the count of unique eligible unverified original revisions in a defined batch, not album memberships or finished attempts. Failed items remain in that number. The 42 example reconciles: **248 = 34 verified + 1 active + 212 waiting + 1 issue**, so **214 left**. Verified completion requires zero waiting, zero active and zero unresolved issues. Keep completed history across reconnection and retries; do not blend batch totals. Stale receipts are labeled last-known when offline.

### Link-state chip and foreground catch-up

Photos always links to the queue with actual state: **Desktop reachable · 16 left**, **Desktop offline · 16 left · will resume**, or **Punching through NAT…**. “Will resume” assumes enabled Auto-sync, remaining retry eligibility, a reachable peer and permitted foreground/background execution. Otherwise use the actual stopped reason. Library retains the alert and a device row even when browsing elsewhere.

Study 43 illustrates mutually exclusive states together for review: unreachable desktop; paired but no peer found; active NAT punching; Wi-Fi-only policy; OS background suspension; retries exhausted. Production displays the actual reason. Wi-Fi-only is a **new optional preference**, not a requirement of p2p. NAT punching needs real transport events and a timeout; no fake infinite reconnect. Do not infer OS termination retrospectively without persisted lifecycle evidence.

**Catch up with desktop** is an explicit foreground mode (42), accessible from the status strip/queue. It offers keep-awake scoped to this view, live item progress and **214 left · ~12 min** only once recent throughput and known remaining bytes justify an estimate. Before then: **Estimating…**. Drop the ETA immediately on interruption, route change or unstable throughput. It is an estimate, never guaranteed completion time. Exit releases keep-awake and says Android may pause background work. Both devices must stay available. This overrides round 1's blanket “no ETA” rule only in this measured foreground mode.

The brief's flaky public-relay behavior motivates file-level resilience, not a claim that this transport is reliable or that byte resume exists. At 100% bytes show **Waiting for verification** until durable exact-revision acknowledgement. A bad/large file gets a visible issue row and bounded retries while independent work continues; fair scheduling/timeouts need implementation. Completed originals remain completed. Retry uses existing Send all where possible. **Leaving catch-up is not a fabricated transfer-cancel endpoint.**

## Competitor rubric: design coverage, 0–2 each

Scoring: **0** absent; **1** partial or significant unresolved parity; **2** explicitly designed with relevant states. Scores evaluate this storyboard, not shipped implementation or tested usability.

| # | Criterion | Score | Evidence / limitation |
| --- | --- | --- | --- |
| 1 | Explicit predictable tabs | **2** | Photos · Search · Library on all tabbed studies; fixed Library order, migration explanation (25). Immersive overlays deliberately hide tabs. |
| 2 | Persistent primary search | **2** | Dedicated center tab plus prominent zero-state/results field (26–29, 36–37). |
| 3 | Density, sticky dates, draggable scrubber | **2** | 01/41 specify 2–5 columns, stable anchors, sticky headings, date preview/rail; 02 retains date-tree alternative. Gesture implementation is outside the HTML. |
| 4 | Multi-select and deletion scope | **2** | 39 long-press/checks/day selection/contextual bar; 40 explicit device scope and only-copy review. Backend operations remain new work. |
| 5 | Pager, details and filmstrip | **2** | 04/10 filmstrip, existing swipe/pinch; 38 scrollable EXIF, location, people, related memories and original state. |
| 6 | Semantic + faces + places + things/OCR | **2** | People-first zero-state; OCR and semantic hits in the same set; person/place/category grids; partial index and offline limits (26–37). |
| 7 | Automatic collections beside albums | **1** | Memories, On This Day, People, Places and Moments coexist with manual albums. Multi-day trip inference and mobile manual-album creation remain gaps; Trips currently means existing place/time moments. |
| 8 | Always-visible sync, why paused, queue | **2** | Timeline chip, Library dot/device row, 15–19 queue states, 42 foreground mode, 43 named reasons. Telemetry is not fabricated as shipped. |
| 9 | Two-directional per-item/revision state | **2** | ↑ / ✓ / ↓ on actual asset thumbnails, filmstrip and covers; exact-original revision semantics + detail evidence; no derivative-only success. Needs receipt contract. |
| 10 | Fast pairing and designed empty/paused states | **2** | Existing QR/manual/challenge/Later preserved; 20–24 and 37 separate access, empty, indexing, unavailable and offline; no background guarantee. |
| | **Total** | **19 / 20** | Ambitious replacement experience, with explicit implementation and album/trip parity gaps. |

## Before translating into app code

1. Expose real desktop search/discovery through the mobile boundary, plus explicit capabilities, result provenance and coverage. Port phone CLIP/OCR/faces/memories with persisted readiness before presenting offline-ready claims. Measure language relevance rather than assuming all natural-language examples perform equally.
2. Add canonical content/revision identity and original verification receipts, durable local originals/cache policy, missing-original/fetch errors, and deduplicated source federation. Keep preview availability independent from original ownership.
3. Supply per-item queue/progress/reason events, fair scheduling, interruption recovery, bounded retries, measured ETA and lifecycle-aware keep-awake. Keep QML thin; no second queue, fake timers or direct core/database access.
4. Fix 0,0 before place grouping/geocoding and determine offline map data. Define date/person/place/album scope and Back restoration consistently.
5. Retain round-1 permission distinctions and keyboard-aware face/endpoint sheets. Resolve the existing local-video Edit issue: current editor reads an Image and saves a JPEG. Retaining its affordance is not a claim of a functioning video editor.
6. Define scoped deletion and current-revision checks before enabling those mock buttons. Manual mobile album authoring and true trip aggregation remain future parity decisions; all currently available album controls are preserved.

## Delivery checks

Only **`design/phone-ux/index.html`** and **`design/phone-ux/NOTES.md`** were written in the repository. Existing unrelated work was left intact. No D/QML builds or app tests are applicable to this static document-only revision.

The HTML has no scripts, inline handlers, external assets/styles/fonts, network fetches or map tiles. CSP keeps `default-src 'none'`, `script-src 'none'`, `connect-src 'none'`, and an exact **SHA-256 stylesheet allowlist**, without `unsafe-inline`. Inline SVG/same-document references provide all visual assets. The stylesheet hash was regenerated after edits. A stricter hosting-header CSP would also have to permit that hash.

Structural checks cover all 43 unique study IDs, original 24 preserved, valid fragment/SVG references, 27 editor filters and five panels, only Photos/Search/Library tab labels, asset-state coverage, original editor controls, no external assets and the exact stylesheet hash. Browser screenshot validation was attempted with both Playwright's Chromium and the system Chromium; the environment rejected a required socket operation (`setsockopt: Operation not permitted`) before rendering. **Browser layout, touch gestures and interactions are not visually verified here.** No claim of a rendered screenshot or working offline index is made.
