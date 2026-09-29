# Using Photo Wagon

[Back to the README](../README.md)

## Dates

Taken-time comes from EXIF first; then the file name or folder (WhatsApp,
screenshots, camera and Pixel names, `2020/02/13/` folders); and only then the
file's modification time.

## Browsing

- **Sidebar** — Library, Favorites, People, Places, Imports; the **years → months → days**
  tree with counts (one click jumps to a day, the same node again clears it); Media
  Types (Photos, Screenshots, Memes); your albums; the phone and peers; a
  connection / indexing status line in the footer.
- **Toolbar** — Years / Months / Days / All Photos, a zoom slider, and search.
- **Grid** — click selects, ⌘/Ctrl-click extends, double-click opens, hover shows the
  heart (and the scene / holiday / weather).
- The Library timeline shows photographs; screenshots and memes live under Media
  Types (an album or a search shows everything).

## The viewer

Opens in place of the grid, with a caption line (date, camera, size, file), a
filmstrip, and an **ⓘ Info** panel.

- **Zoom** — wheel, double-click, `+` / `−` / `0`, or drag. **Full screen** — `F`.
- **Right-click a photo or selection** — copy files, copy paths, show in folder,
  favorite, add to an album, set the place, mark as photo / screenshot / meme,
  move to trash, delete permanently (`Delete` and `Shift+Delete` from the keyboard).

## People & faces

On-device face detection and clustering (YuNet + SFace, via one C++ shim).

- The **ⓘ Info** panel lists the people in a photo with round portraits, and "Name"
  for the unnamed ones.
- Naming a face lists the likely people first, then everyone alphabetically with
  portraits, narrowed as you type (↑/↓ and Return pick one).
- "Use as portrait" makes that face the person's picture; right-clicking a face
  can change or rename the person, use it as the portrait, remove the tag, or mark
  it as not a face.
- A **People** page shows everyone with round portraits.

## Places

- A **Places** page: one card per city with its newest photo and count; the cities
  appear in the sidebar too.
- A photo with GPS lands in the nearest city — a compiled-in **GeoNames** table,
  fully offline (a `0,0` position from a phone with location off counts as none).
- Set the rest by hand: select → right-click → **Set Place…**, which suggests your
  own places first, then the world's cities as you type, or keeps any name you enter.

## Scenes, moods, weather & holidays

Every photograph is tagged offline by **CLIP** (ViT-B/32, zero-shot):

| Axis | Examples |
|---|---|
| **Scene** | Beach, Pool, Snow, Mountains, Party, Birthday, Food, Pets, Baby, Selfie, Night… |
| **Mood** | Joyful, Calm, Romantic, Energetic, Nostalgic, Cozy, Festive, Melancholic… |
| **Weather** | Sunny, Cloudy, Rainy, Stormy, Foggy, Snowy, Hot, Cold |
| **Holiday** | Christmas, New Year, Carnival, Easter, Halloween, Festa Junina, Mother's / Father's / Children's / Valentine's Day (from the calendar, Brazilian dates); Birthday, Wedding, Graduation (from the picture) |

Each is a sidebar section with counts, a row in the ⓘ Info panel (with the model's
top guesses), and a right-click submenu to correct it. The vocabulary lives in
`data/scenes/labels.tsv`.

## Tags

- A **tag strip** under every open photo shows its chips — scene, mood, weather,
  holiday, place, and your own tags (**+ Tag**, any words, comma-separated; × removes
  one). Clicking a chip shows every photo that shares it.
- Your tags are a sidebar section too, and **Add Tags…** (menu or toolbar) applies
  them to a whole selection.
- **Tags live in the files.** Your keywords, the scene / mood / weather / holiday,
  and the place are written into the XMP and IPTC keyword fields (`praia 2020`,
  `Scene: Beach`, `Place: Peruíbe, Brazil`) — automatically after you change a photo,
  and on request for the rest (**Write Tags to Files**). Pixels and modification
  times are left untouched, and a file that arrives with keywords brings them into
  the library.

## Editing

The sliders icon, or `E`:

- Twelve Instagram-style **filters**, previewed on the photo itself.
- **Adjustments** — brightness, contrast, saturation, warmth, fade, vignette,
  sharpen, sepia — plus rotate, flip, and a crop frame with draggable corners and
  aspect presets.
- Rendered by the core (**libvips**); the original file is never written to.
  **Save** keeps the result in the library (thumbnail and viewer follow; **Revert**
  undoes it); **Save as Copy** writes a JPEG next to the original.

## Similar photos

A chip under every photo lists the ones that look like it — a nearest-neighbour
query over the CLIP embeddings. Those, like the face clusters' centroids, live in
[sqlite-vec](https://github.com/asg017/sqlite-vec) tables inside the library
database (compiled in, `csrc/sqlite-vec.c`), never in memory.

Light or dark follows the system theme.

## Background work and memory

Background work runs on a leash (`core/jobs/scheduler.d`):

- Indexing, the media-kinds pass, faces, scenes, and the tag writer are **passes**
  that queue on one lane and run one at a time — new photos first.
- Every native operation (a decode, a model, a render) takes one of `--jobs N`
  permits (default 2) and steps aside while a request from the window or the phone
  is being answered.
- The **CLIP model** (about a gigabyte inside OpenCV) never lives in the app: a
  child process (`photo-wagon --clip-worker`) encodes for one pass and is then
  killed. Faces are detected on a reduced decode of big JPEGs; libvips keeps a 64 MB
  operation cache; each pass ends with a garbage collection that returns memory to
  the system. The viewer doesn't cache the 4096 px decodes of photos you open.
- A core started by a script should get `--exit-with-parent` — it dies with its
  parent. A **memory guard** watches resident size: above `--memory-limit` MB
  (default 1536) the process aborts itself with `SIGSEGV` on purpose, so the core
  dump shows what grew.
