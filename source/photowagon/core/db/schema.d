/// The library schema and its migrations. `user_version` is the schema number.
module photowagon.core.db.schema;

import photowagon.core.db.sqlite : Database;

enum currentVersion = 21;

void migrate(Database db)
{
	// Read the version and FINALISE the statement before the migration transaction.
	// A stepped-but-unfinalised statement keeps a cursor live on the connection, and a
	// vec0 DROP runs nested SQL (dropping its shadow tables) that fails with a generic
	// "SQL logic error" while any statement is active — which is exactly what broke the
	// float[128]→float[512] face_vec migration (V18). Plain CREATE/DROP of ordinary
	// tables has no nested statement, so earlier migrations never hit this.
	int have;
	{
		auto v = db.prepare("PRAGMA user_version");
		v.step();
		have = v.getInt(0);
	}
	if (have >= currentVersion)
		return;
	db.transaction!void({
		if (have < 1)
			db.exec(schemaV1);
		if (have < 2)
			db.exec(schemaV2);
		if (have < 3)
			db.exec(schemaV3);
		if (have < 4)
			db.exec(schemaV4);
		if (have < 5)
			db.exec(schemaV5);
		if (have < 6)
			db.exec(schemaV6);
		if (have < 7)
			db.exec(schemaV7);
		if (have < 8)
			db.exec(schemaV8);
		if (have < 9)
			db.exec(schemaV9);
		if (have < 10)
			db.exec(schemaV10);
		if (have < 11)
			migrateV11(db);
		if (have < 12)
			db.exec(schemaV12);
		if (have < 13)
			db.exec(schemaV13);
		if (have < 14)
			migrateV14(db);
		if (have < 15)
			db.exec(schemaV15);
		if (have < 16)
			db.exec(schemaV16);
		if (have < 17)
			db.exec(schemaV17);
		if (have < 18)
			migrateV18(db);
		if (have < 19)
			db.exec(schemaV19);
		if (have < 20)
			db.exec(schemaV20);
		if (have < 21)
			db.exec(schemaV21);
		db.exec("PRAGMA user_version = " ~ currentVersion.stringof);
	});
}

private enum schemaV1 = `
CREATE TABLE roots (
    id        INTEGER PRIMARY KEY,
    path      TEXT NOT NULL UNIQUE,
    added_at  INTEGER NOT NULL
);

CREATE TABLE photos (
    id          INTEGER PRIMARY KEY,
    hash        TEXT NOT NULL UNIQUE,      -- sha256 of the original, hex
    path        TEXT UNIQUE,               -- NULL for photos known only through a peer
    root_id     INTEGER REFERENCES roots(id) ON DELETE CASCADE,
    size        INTEGER NOT NULL DEFAULT 0,
    mtime_ms    INTEGER NOT NULL DEFAULT 0,
    taken_ts    INTEGER NOT NULL,          -- unix seconds; EXIF when present, else mtime
    taken_at    TEXT NOT NULL,             -- ISO-8601 of the above
    width       INTEGER NOT NULL DEFAULT 0,
    height      INTEGER NOT NULL DEFAULT 0,
    orientation INTEGER NOT NULL DEFAULT 1,
    camera      TEXT,
    lat         REAL,
    lon         REAL,
    thumb_hash  TEXT,                      -- sha256 of the thumbnail blob in the store
    origin_peer TEXT                       -- peer id this photo was fetched from, if remote
);
CREATE INDEX photos_taken   ON photos(taken_ts DESC, id DESC);
CREATE INDEX photos_root    ON photos(root_id);

CREATE TABLE albums (
    id          INTEGER PRIMARY KEY,
    name        TEXT NOT NULL,
    created_at  INTEGER NOT NULL,
    manifest    TEXT,                      -- hash of the published manifest blob
    origin_peer TEXT
);

CREATE TABLE album_photos (
    album_id   INTEGER NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
    photo_id   INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
    position   INTEGER NOT NULL,
    PRIMARY KEY (album_id, photo_id)
);

CREATE TABLE peers (
    peer_id    TEXT PRIMARY KEY,
    addrs      TEXT NOT NULL,              -- JSON array of multiaddrs
    agent      TEXT,
    last_seen  INTEGER NOT NULL
);
`;

private enum schemaV2 = `
ALTER TABLE photos ADD COLUMN faces_scanned INTEGER NOT NULL DEFAULT 0;

CREATE TABLE persons (
    id          INTEGER PRIMARY KEY,
    name        TEXT,                      -- NULL until the user names the cluster
    created_at  INTEGER NOT NULL
);

CREATE TABLE faces (
    id          INTEGER PRIMARY KEY,
    photo_id    INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
    x           REAL NOT NULL,             -- box as fractions of the rotated image
    y           REAL NOT NULL,
    w           REAL NOT NULL,
    h           REAL NOT NULL,
    score       REAL NOT NULL,
    embedding   BLOB NOT NULL,             -- 128 float32 (SFace)
    thumb_hash  TEXT,                      -- face crop in the store
    person_id   INTEGER REFERENCES persons(id) ON DELETE SET NULL
);
CREATE INDEX faces_photo  ON faces(photo_id);
CREATE INDEX faces_person ON faces(person_id);
`;

private enum schemaV3 = `
CREATE TABLE settings (
    key    TEXT PRIMARY KEY,
    value  TEXT
);
`;

private enum schemaV4 = `
ALTER TABLE photos ADD COLUMN favorite INTEGER NOT NULL DEFAULT 0;
CREATE INDEX photos_favorite ON photos(favorite) WHERE favorite = 1;
`;

private enum schemaV5 = `
ALTER TABLE photos ADD COLUMN kind TEXT;          -- photo | screenshot | meme; NULL = not classified yet
ALTER TABLE photos ADD COLUMN kind_by TEXT;       -- 'auto' or 'user'
CREATE INDEX photos_kind ON photos(kind);
`;

private enum schemaV6 = `
ALTER TABLE persons ADD COLUMN cover_face INTEGER;   -- the face the user picked as the portrait, or NULL
`;

private enum schemaV7 = `
ALTER TABLE photos ADD COLUMN place TEXT;         -- the city, from the GPS or the user
ALTER TABLE photos ADD COLUMN country TEXT;
ALTER TABLE photos ADD COLUMN place_by TEXT;      -- 'gps' | 'user' | 'none' (GPS, but no city near) | NULL = not looked up yet
CREATE INDEX photos_place ON photos(place, country);
`;

private enum schemaV8 = `
CREATE TABLE photo_clip (                          -- CLIP ViT-B/32 image embedding, unit length
    photo_id   INTEGER PRIMARY KEY REFERENCES photos(id) ON DELETE CASCADE,
    embedding  BLOB NOT NULL,                      -- 512 float32
    version    INTEGER NOT NULL
);
CREATE TABLE photo_tags (                          -- one tag per group (scene, mood) per photo
    photo_id   INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
    grp        TEXT NOT NULL,
    tag        TEXT NOT NULL,                      -- '' = looked at, nothing in particular
    score      REAL NOT NULL DEFAULT 0,
    tag_by     TEXT NOT NULL,                      -- 'auto' | 'user'
    PRIMARY KEY (photo_id, grp)
);
CREATE INDEX photo_tags_tag ON photo_tags(grp, tag);
`;

private enum schemaV9 = `
CREATE TABLE photo_keywords (                      -- the user's own tags, any number per photo
    photo_id   INTEGER NOT NULL REFERENCES photos(id) ON DELETE CASCADE,
    keyword    TEXT NOT NULL,
    PRIMARY KEY (photo_id, keyword)
);
CREATE INDEX photo_keywords_keyword ON photo_keywords(keyword);
`;

private enum schemaV10 = `
ALTER TABLE photos ADD COLUMN edits TEXT;          -- edit/edits.d JSON; NULL = untouched
ALTER TABLE photos ADD COLUMN edited_hash TEXT;    -- the rendered result in the store (full size JPEG)
`;

// v11: the vectors move into sqlite-vec tables — nothing keeps them in memory.
// photo_vec holds the CLIP embeddings (photo_clip keeps the bookkeeping), person_vec the
// unit centroids of the face clusters (person_centroid the running sums behind them).
private enum schemaV11 = `
CREATE VIRTUAL TABLE photo_vec USING vec0(photo_id INTEGER PRIMARY KEY, embedding float[512] distance_metric=cosine);
CREATE VIRTUAL TABLE person_vec USING vec0(person_id INTEGER PRIMARY KEY, centroid float[512] distance_metric=cosine);
CREATE TABLE person_centroid (
    person_id  INTEGER PRIMARY KEY REFERENCES persons(id) ON DELETE CASCADE,
    sum        BLOB NOT NULL,                      -- 128 float32: the sum of the unit embeddings
    count      INTEGER NOT NULL DEFAULT 0,
    named      INTEGER NOT NULL DEFAULT 0
);
ALTER TABLE photo_clip ADD COLUMN ok INTEGER NOT NULL DEFAULT 1;   -- 0: the image could not be encoded
`;

// v12: photos the desktop has turned away. A hash lands here when the user deletes an
// imported photo, so a phone offering it again during sync negotiation is told "refuse"
// and does not push it back. The negotiation (library.offer) reads it.
private enum schemaV12 = `
CREATE TABLE declined_hashes (
    hash TEXT PRIMARY KEY,                          -- sha256 of a file the desktop will not take
    at   TEXT NOT NULL DEFAULT (datetime('now'))
);
`;

// v13: the phones paired with this desktop, each keyed by its libp2p peer id (a stable,
// cryptographic per-device fingerprint). A new phone is admitted only after the person at
// the desktop types the 4-digit code the phone shows; the row remembers the name and lets
// the desktop pause or revoke it. Auth refuses a paused or revoked peer.
private enum schemaV13 = `
CREATE TABLE devices (
    peer_id   TEXT PRIMARY KEY,                    -- the phone's libp2p peer id
    name      TEXT,
    state     TEXT NOT NULL DEFAULT 'active',      -- active | paused | revoked
    paired_at TEXT NOT NULL DEFAULT (datetime('now')),
    last_seen TEXT
);
`;

// v14: a per-face vector index. person_vec keeps one averaged centroid per person; a face
// at an unusual angle can sit far from that average even when it is plainly the same person.
// face_vec holds every face's own embedding, so recognition can ask "whose faces are nearest
// to this one?" and vote — which is how a new face of a known person gets recognized, and it
// gets better as more faces accumulate. A trigger keeps it in step when a face is deleted.
private enum schemaV14 = `
CREATE VIRTUAL TABLE face_vec USING vec0(face_id INTEGER PRIMARY KEY, embedding float[512] distance_metric=cosine);
CREATE TRIGGER faces_del_vec AFTER DELETE ON faces BEGIN
    DELETE FROM face_vec WHERE face_id = old.id;
END;
`;

// v15: videos join the library. A video row is a photo row with kind = 'video'; its
// thumbnail is a frame, and duration_ms is how long it runs (0 for a still).
private enum schemaV15 = `
ALTER TABLE photos ADD COLUMN duration_ms INTEGER NOT NULL DEFAULT 0;
`;

// v16: OCR. The text read from screenshots, memes and text-bearing photos (scene = 'Text'),
// so search finds words that live in the picture. ocr_scanned marks a photo as looked at
// (0 = pending, 1 = done) so the pass never re-reads it.
private enum schemaV16 = `
ALTER TABLE photos ADD COLUMN ocr_text TEXT;
ALTER TABLE photos ADD COLUMN ocr_scanned INTEGER NOT NULL DEFAULT 0;
`;

// v17: a nickname the user gives a peer, keyed by its libp2p peer id, so the Peers panel
// shows "Marcelo's phone" instead of 12D3Koo…. App-side only (never touches the p2p node).
private enum schemaV17 = `
CREATE TABLE peer_names (
    peer_id  TEXT PRIMARY KEY,
    name     TEXT NOT NULL
);
`;

// v19: what is known of a file's content, computed once in the same pass as its sha256
// (core/sync/digest.d) and kept by that hash: the fingerprint (size + eight sampled 4 KiB
// blocks) that tells a rescan the file is still the same one when only its mtime moved,
// and the piece hashes (the piece protocol's manifest), so serving a file never re-reads
// it to announce it. Filled in as files are (re)indexed; a missing row is computed on use.
private enum schemaV19 = `
CREATE TABLE photo_digest (
    hash         TEXT PRIMARY KEY,
    fingerprint  TEXT NOT NULL,
    pieces       BLOB NOT NULL,
    size         INTEGER NOT NULL
);
`;

// Stacks (core/library/stacks.d): near-identical photos taken together show as one tile.
// NULL = not in a stack; else the stack's smallest photo id.
private enum schemaV20 = `
ALTER TABLE photos ADD COLUMN stack_id INTEGER;
CREATE INDEX photos_stack ON photos(stack_id) WHERE stack_id IS NOT NULL;
`;

// v21: photos "removed from Wagon" — a quarantine: the file stays on disk untouched, the
// photo leaves the library and does not come back (the indexer skips its content, a phone
// offering it is turned away) until restored. Keyed by content hash, so a moved or renamed
// file stays out; path/size/mtime let a folder scan skip it without hashing it again. The
// timestamp is the hook for replicating removals to other computers.
private enum schemaV21 = `
CREATE TABLE removed_hashes (
    hash       TEXT PRIMARY KEY,
    file_hash  TEXT,               -- the file's bytes when removed, if they differ (tags written in)
    path       TEXT,
    size       INTEGER,
    mtime_ms   INTEGER,
    taken_at   TEXT,
    thumb_hash TEXT,
    kind       TEXT,
    removed_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX removed_hashes_path ON removed_hashes(path);
CREATE INDEX removed_hashes_file ON removed_hashes(file_hash) WHERE file_hash IS NOT NULL;
`;

private void migrateV18(Database db)
{
	// ArcFace r100 (512-d) replaces SFace (128-d) for the face embedding: far better
	// separation of different people (babies/siblings stop being merged). The vec0
	// tables and every stored face must be rebuilt at the new size. Pre-launch — no
	// data to keep — so wipe faces/persons and re-detect on the next face pass.
	db.exec("DROP TABLE IF EXISTS face_vec");
	db.exec("DROP TABLE IF EXISTS person_vec");
	db.exec("CREATE VIRTUAL TABLE face_vec USING vec0(face_id INTEGER PRIMARY KEY, embedding float[512] distance_metric=cosine)");
	db.exec("CREATE VIRTUAL TABLE person_vec USING vec0(person_id INTEGER PRIMARY KEY, centroid float[512] distance_metric=cosine)");
	db.exec("DELETE FROM faces");
	db.exec("DELETE FROM persons");
	db.exec("UPDATE photos SET faces_scanned = 0");
	db.exec("DELETE FROM settings WHERE key IN ('cluster_version', 'face_vec_build')");
}

private void migrateV14(Database db)
{
	db.exec(schemaV14);
	// seed it with the faces good enough to be identity anchors (the clustering gate:
	// score >= 0.8, at least 48 px wide in the original). Raw embeddings — the cosine
	// metric normalises internally, so no need to unit them here.
	auto q = db.prepare(`SELECT f.id, f.embedding FROM faces f JOIN photos p ON p.id = f.photo_id
		WHERE length(f.embedding) = 512 AND f.score >= 0.8 AND f.w * p.width >= 48`);
	auto ins = db.prepare("INSERT INTO face_vec (face_id, embedding) VALUES (?, ?)");
	while (q.step())
	{
		ins.reset();
		ins.bind(1, q.getLong(0)).bind(2, q.getBlob(1));
		ins.run();
	}
}

private void migrateV11(Database db)
{
	db.exec(schemaV11);
	// the embeddings stored as blobs so far go into the vec table; all-zero ones were failures
	auto q = db.prepare("SELECT photo_id, embedding FROM photo_clip");
	auto ins = db.prepare("INSERT INTO photo_vec (photo_id, embedding) VALUES (?, ?)");
	auto bad = db.prepare("UPDATE photo_clip SET ok = 0 WHERE photo_id = ?");
	while (q.step())
	{
		auto blob = q.getBlob(1);
		bool zero = true;
		foreach (b; blob)
			if (b != 0)
			{
				zero = false;
				break;
			}
		if (zero || blob.length != 512 * 4)
		{
			bad.reset();
			bad.bind(1, q.getLong(0));
			bad.run();
			continue;
		}
		ins.reset();
		ins.bind(1, q.getLong(0)).bind(2, blob);
		ins.run();
	}
	db.exec("ALTER TABLE photo_clip DROP COLUMN embedding");
}

/// Small persisted flags (e.g. which clustering rule the faces were grouped by).
string getSetting(Database db, string key)
{
	auto s = db.prepare("SELECT value FROM settings WHERE key = ?");
	s.bind(1, key);
	return s.step() ? s.getString(0) : null;
}

void setSetting(Database db, string key, string value)
{
	auto s = db.prepare("INSERT INTO settings (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value");
	s.bind(1, key).bind(2, value);
	s.run();
}

unittest
{
	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	migrate(db); // idempotent
	auto v = db.prepare("PRAGMA user_version");
	v.step();
	assert(v.getInt(0) == currentVersion);
	db.exec("INSERT INTO roots (path, added_at) VALUES ('/x', 0)");
	assert(getSetting(db, "k") is null);
	setSetting(db, "k", "1");
	setSetting(db, "k", "2");
	assert(getSetting(db, "k") == "2");
}
