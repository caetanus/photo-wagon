/// The library schema and its migrations. `user_version` is the schema number.
module photowagon.core.db.schema;

import photowagon.core.db.sqlite : Database;

enum currentVersion = 10;

void migrate(Database db)
{
	auto v = db.prepare("PRAGMA user_version");
	v.step();
	immutable have = v.getInt(0);
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
