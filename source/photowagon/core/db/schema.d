/// The library schema and its migrations. `user_version` is the schema number.
module photowagon.core.db.schema;

import photowagon.core.db.sqlite : Database;

enum currentVersion = 2;

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
}
