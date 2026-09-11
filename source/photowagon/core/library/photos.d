/// Photo rows: the one place that knows the `photos` table, and how a row
/// becomes the `Photo` JSON of docs/ipc.md.
module photowagon.core.library.photos;

import std.json;
import std.typecons : Nullable;

import photowagon.core.db.sqlite : Database, Statement;
import photowagon.core.ipc.protocol : ApiError, nullable;
import photowagon.core.store.store : ContentStore;

public import photowagon.core.library.calendar : dateRange, fileUrl;

struct Photo
{
	long id;
	string hash;
	string path; // null when remote
	long rootId; // 0 when remote
	long size;
	long mtimeMs;
	long takenTs;
	string takenAt;
	int width;
	int height;
	int orientation = 1;
	string camera;
	bool hasGps;
	double lat;
	double lon;
	string thumbHash;
	string originPeer;
	bool favorite;
	string kind; // photo | screenshot | meme; null until classified
	string kindBy; // auto | user
	string place; // the city; null until looked up (or none near)
	string country;
	string placeBy; // gps | user | none
	string scene; // zero-shot CLIP tags (core/library/scenes.d); null = none / not looked at
	string mood;
}

/// Restricts a page or a count. Zero means "no restriction" for every field.
struct Filter
{
	long rootId;
	long albumId;
	long personId;
	int year;
	int month;
	int day;
	bool favorites;
	string kind; // restrict to one kind; null = any
	string text; // a word of the path (file name, folder); null = any
	string place; // photos of one place (with `country` when given); null = any
	string country;
	string scene; // photos tagged with one scene / mood; null = any
	string mood;
}

struct Neighbours
{
	long prev; // 0 = none
	long next;
}

final class PhotoRepo
{
	private Database db;
	private ContentStore store;

	this(Database db, ContentStore store)
	{
		this.db = db;
		this.store = store;
	}

	// ---- writes ---------------------------------------------------------------

	Nullable!Photo byPath(string path)
	{
		auto s = db.prepare(selectColumns ~ " FROM photos p WHERE p.path = ?");
		s.bind(1, path);
		if (!s.step())
			return Nullable!Photo.init;
		return Nullable!Photo(readRow(s));
	}

	Nullable!Photo byHash(string hash)
	{
		auto s = db.prepare(selectColumns ~ " FROM photos p WHERE p.hash = ?");
		s.bind(1, hash);
		if (!s.step())
			return Nullable!Photo.init;
		return Nullable!Photo(readRow(s));
	}

	bool hasHash(string hash)
	{
		auto s = db.prepare("SELECT 1 FROM photos WHERE hash = ?");
		s.bind(1, hash);
		return s.step();
	}

	long insert(ref Photo p)
	{
		auto s = db.prepare(`INSERT INTO photos (hash, path, root_id, size, mtime_ms, taken_ts, taken_at,
			width, height, orientation, camera, lat, lon, thumb_hash, origin_peer, kind, kind_by)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
		bindPhoto(s, p);
		s.run();
		p.id = db.lastInsertId();
		return p.id;
	}

	/// Replaces every column of the row with `p.id`.
	void update(ref Photo p)
	{
		auto s = db.prepare(`UPDATE photos SET hash = ?, path = ?, root_id = ?, size = ?, mtime_ms = ?,
			taken_ts = ?, taken_at = ?, width = ?, height = ?, orientation = ?, camera = ?, lat = ?, lon = ?,
			thumb_hash = ?, origin_peer = ?, kind = ?, kind_by = ? WHERE id = ?`);
		bindPhoto(s, p);
		s.bind(18, p.id);
		s.run();
	}

	private static void bindPhoto(ref Statement s, ref Photo p)
	{
		s.bind(1, p.hash).bind(2, p.path);
		if (p.rootId)
			s.bind(3, p.rootId);
		else
			s.bindNull(3);
		s.bind(4, p.size).bind(5, p.mtimeMs).bind(6, p.takenTs).bind(7, p.takenAt)
			.bind(8, p.width).bind(9, p.height).bind(10, p.orientation).bind(11, p.camera);
		if (p.hasGps)
			s.bind(12, p.lat).bind(13, p.lon);
		else
			s.bindNull(12).bindNull(13);
		s.bind(14, p.thumbHash).bind(15, p.originPeer).bind(16, p.kind).bind(17, p.kindBy);
	}

	/// Where a stored thumbnail lives.
	string thumbPath(string hash) const
	{
		return store.pathFor(hash);
	}

	/// Sets the kind; `by` is "auto" or "user" (a user's choice is never overwritten automatically).
	void setKind(long id, string kind, string by)
	{
		auto s = db.prepare("UPDATE photos SET kind = ?, kind_by = ? WHERE id = ?");
		s.bind(1, kind).bind(2, by).bind(3, id);
		s.run();
		if (db.changes() == 0)
			throw new ApiError("not_found", "no photo " ~ idString(id));
	}

	/// Forgets every automatic classification (the rules changed); the user's choices stay.
	void resetAutoKinds()
	{
		db.exec("UPDATE photos SET kind = NULL, kind_by = NULL WHERE kind_by IS NULL OR kind_by = 'auto'");
	}

	/// Local photos with a thumbnail and no kind yet.
	long[] unclassified(long limit = 100_000)
	{
		auto s = db.prepare("SELECT id FROM photos WHERE kind IS NULL AND thumb_hash IS NOT NULL ORDER BY id LIMIT ?");
		s.bind(1, limit);
		long[] out_;
		while (s.step())
			out_ ~= s.getLong(0);
		return out_;
	}

	/// How many photos of each kind (NULL counted as "unknown").
	long[string] kindCounts()
	{
		auto s = db.prepare("SELECT coalesce(kind, 'unknown'), count(*) FROM photos GROUP BY 1");
		long[string] out_;
		while (s.step())
			out_[s.getString(0)] = s.getLong(1);
		return out_;
	}

	void setFavorite(long id, bool on)
	{
		auto s = db.prepare("UPDATE photos SET favorite = ? WHERE id = ?");
		s.bind(1, on ? 1L : 0L).bind(2, id);
		s.run();
		if (db.changes() == 0)
			throw new ApiError("not_found", "no photo " ~ idString(id));
	}

	/// The row goes (faces and album entries follow by cascade); the file is the caller's business.
	void remove(long id)
	{
		auto d = db.prepare("DELETE FROM photos WHERE id = ?");
		d.bind(1, id);
		d.run();
	}

	long deleteMissingUnder(long rootId, bool delegate(string path) stillExists)
	{
		long[] gone;
		{
			auto s = db.prepare("SELECT id, path FROM photos WHERE root_id = ?");
			s.bind(1, rootId);
			while (s.step())
				if (!stillExists(s.getString(1)))
					gone ~= s.getLong(0);
		}
		foreach (id; gone)
		{
			auto d = db.prepare("DELETE FROM photos WHERE id = ?");
			d.bind(1, id);
			d.run();
		}
		return gone.length;
	}

	// ---- reads ----------------------------------------------------------------

	Photo get(long id)
	{
		auto s = db.prepare(selectColumns ~ " FROM photos p WHERE p.id = ?");
		s.bind(1, id);
		if (!s.step())
			throw new ApiError("not_found", "no photo " ~ idString(id));
		return readRow(s);
	}

	long count(Filter f)
	{
		auto w = whereClause(f);
		auto s = db.prepare("SELECT count(*) FROM photos p" ~ w.joins ~ w.where);
		w.bind(s);
		s.step();
		return s.getLong(0);
	}

	/// Newest first, then by id so the order is total. Inside an album the
	/// album's own order wins.
	Photo[] page(Filter f, long offset, long limit)
	{
		auto w = whereClause(f);
		auto s = db.prepare(selectColumns ~ " FROM photos p" ~ w.joins ~ w.where
				~ (f.albumId ? " ORDER BY ap.position ASC" : " ORDER BY p.taken_ts DESC, p.id DESC")
				~ " LIMIT ? OFFSET ?");
		immutable n = w.bind(s);
		s.bind(n + 1, limit).bind(n + 2, offset);
		Photo[] out_;
		while (s.step())
			out_ ~= readRow(s);
		return out_;
	}

	Neighbours neighbours(long id, Filter f)
	{
		auto me = get(id);
		Neighbours nb;
		if (f.albumId)
			return albumNeighbours(me.id, f.albumId);
		{
			// previous = the next newer one in display order
			auto w = whereClause(f);
			auto s = db.prepare("SELECT p.id FROM photos p" ~ w.joins ~ w.where
					~ " AND (p.taken_ts > ? OR (p.taken_ts = ? AND p.id > ?)) ORDER BY p.taken_ts ASC, p.id ASC LIMIT 1");
			immutable n = w.bind(s);
			s.bind(n + 1, me.takenTs).bind(n + 2, me.takenTs).bind(n + 3, me.id);
			if (s.step())
				nb.prev = s.getLong(0);
		}
		{
			auto w = whereClause(f);
			auto s = db.prepare("SELECT p.id FROM photos p" ~ w.joins ~ w.where
					~ " AND (p.taken_ts < ? OR (p.taken_ts = ? AND p.id < ?)) ORDER BY p.taken_ts DESC, p.id DESC LIMIT 1");
			immutable n = w.bind(s);
			s.bind(n + 1, me.takenTs).bind(n + 2, me.takenTs).bind(n + 3, me.id);
			if (s.step())
				nb.next = s.getLong(0);
		}
		return nb;
	}

	private Neighbours albumNeighbours(long id, long albumId)
	{
		Neighbours nb;
		auto pos = db.prepare("SELECT position FROM album_photos WHERE album_id = ? AND photo_id = ?");
		pos.bind(1, albumId).bind(2, id);
		if (!pos.step())
			return nb;
		immutable at = pos.getLong(0);
		auto prev = db.prepare("SELECT photo_id FROM album_photos WHERE album_id = ? AND position < ? ORDER BY position DESC LIMIT 1");
		prev.bind(1, albumId).bind(2, at);
		if (prev.step())
			nb.prev = prev.getLong(0);
		auto next = db.prepare("SELECT photo_id FROM album_photos WHERE album_id = ? AND position > ? ORDER BY position ASC LIMIT 1");
		next.bind(1, albumId).bind(2, at);
		if (next.step())
			nb.next = next.getLong(0);
		return nb;
	}

	JSONValue toJson(ref const Photo p)
	{
		JSONValue j = [
			"id": JSONValue(p.id),
			"hash": JSONValue(p.hash),
			"path": p.path is null ? JSONValue(null) : JSONValue(p.path),
			"fileUrl": p.path is null ? JSONValue(null) : JSONValue(fileUrl(p.path)),
			"thumbUrl": p.thumbHash is null ? JSONValue(null) : JSONValue(fileUrl(store.pathFor(p.thumbHash))),
			"takenAt": JSONValue(p.takenAt),
			"takenTs": JSONValue(p.takenTs),
			"width": JSONValue(p.width),
			"height": JSONValue(p.height),
			"orientation": JSONValue(p.orientation),
			"camera": p.camera is null ? JSONValue(null) : JSONValue(p.camera),
			"lat": nullable(p.lat, p.hasGps),
			"lon": nullable(p.lon, p.hasGps),
			"size": JSONValue(p.size),
			"remote": JSONValue(p.originPeer !is null),
			"favorite": JSONValue(p.favorite),
			"kind": p.kind is null ? JSONValue(null) : JSONValue(p.kind),
			"kindBy": p.kindBy is null ? JSONValue(null) : JSONValue(p.kindBy),
			"place": p.place is null ? JSONValue(null) : JSONValue(p.place),
			"country": p.country is null ? JSONValue(null) : JSONValue(p.country),
			"scene": p.scene is null ? JSONValue(null) : JSONValue(p.scene),
			"mood": p.mood is null ? JSONValue(null) : JSONValue(p.mood),
		];
		return j;
	}

	JSONValue toJsonArray(Photo[] photos)
	{
		JSONValue[] items;
		items.reserve(photos.length);
		foreach (ref p; photos)
			items ~= toJson(p);
		return JSONValue(items);
	}

	// ---- internals --------------------------------------------------------------

	private enum selectColumns = `SELECT p.id, p.hash, p.path, p.root_id, p.size, p.mtime_ms, p.taken_ts, p.taken_at,
		p.width, p.height, p.orientation, p.camera, p.lat, p.lon, p.thumb_hash, p.origin_peer, p.favorite, p.kind, p.kind_by,
		p.place, p.country, p.place_by,
		(SELECT t.tag FROM photo_tags t WHERE t.photo_id = p.id AND t.grp = 'scene' AND t.tag <> ''),
		(SELECT t.tag FROM photo_tags t WHERE t.photo_id = p.id AND t.grp = 'mood' AND t.tag <> '')`;

	private static Photo readRow(ref Statement s)
	{
		Photo p;
		p.id = s.getLong(0);
		p.hash = s.getString(1);
		p.path = s.getString(2);
		p.rootId = s.isNull(3) ? 0 : s.getLong(3);
		p.size = s.getLong(4);
		p.mtimeMs = s.getLong(5);
		p.takenTs = s.getLong(6);
		p.takenAt = s.getString(7);
		p.width = s.getInt(8);
		p.height = s.getInt(9);
		p.orientation = s.getInt(10);
		p.camera = s.getString(11);
		p.hasGps = !s.isNull(12) && !s.isNull(13);
		if (p.hasGps)
		{
			p.lat = s.getDouble(12);
			p.lon = s.getDouble(13);
		}
		p.thumbHash = s.getString(14);
		p.originPeer = s.getString(15);
		p.favorite = s.getLong(16) != 0;
		p.kind = s.getString(17);
		p.kindBy = s.getString(18);
		p.place = s.getString(19);
		p.country = s.getString(20);
		p.placeBy = s.getString(21);
		p.scene = s.getString(22);
		p.mood = s.getString(23);
		return p;
	}

	package struct Where
	{
		string joins;
		string where = " WHERE 1=1";
		private Param[] params; // in the order their `?` appear

		private struct Param
		{
			bool isText;
			long number;
			string text;
		}

		void add(long v) { params ~= Param(false, v); }
		void add(string v) { params ~= Param(true, 0, v); }

		/// Binds the collected values starting at 1; returns how many were bound.
		int bind(ref Statement s)
		{
			int i = 0;
			foreach (v; params)
				if (v.isText)
					s.bind(++i, v.text);
				else
					s.bind(++i, v.number);
			return i;
		}
	}

	package static Where whereClause(Filter f)
	{
		Where w;
		if (f.albumId)
		{
			w.joins ~= " JOIN album_photos ap ON ap.photo_id = p.id AND ap.album_id = ?";
			w.add(f.albumId);
		}
		if (f.rootId)
		{
			w.where ~= " AND p.root_id = ?";
			w.add(f.rootId);
		}
		if (f.personId)
		{
			w.where ~= " AND EXISTS (SELECT 1 FROM faces fp WHERE fp.photo_id = p.id AND fp.person_id = ?)";
			w.add(f.personId);
		}
		if (f.favorites)
			w.where ~= " AND p.favorite = 1";
		if (f.kind == "photo")
			w.where ~= " AND (p.kind = 'photo' OR p.kind IS NULL)";   // not classified yet counts as a photograph
		else if (f.kind.length)
		{
			w.where ~= " AND p.kind = ?";
			w.add(f.kind);
		}
		if (f.text.length)
		{
			w.where ~= " AND p.path LIKE ? ESCAPE '\\'";
			import std.string : replace;
			w.add("%" ~ f.text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") ~ "%");
		}
		if (f.year)
		{
			auto r = dateRange(f.year, f.month, f.day);
			w.where ~= " AND p.taken_ts >= ? AND p.taken_ts < ?";
			w.add(r[0]);
			w.add(r[1]);
		}
		if (f.place.length)
		{
			w.where ~= " AND p.place = ?";
			w.add(f.place);
			if (f.country.length)
			{
				w.where ~= " AND p.country = ?";
				w.add(f.country);
			}
		}
		if (f.scene.length)
		{
			w.where ~= " AND EXISTS (SELECT 1 FROM photo_tags ts WHERE ts.photo_id = p.id AND ts.grp = 'scene' AND ts.tag = ?)";
			w.add(f.scene);
		}
		if (f.mood.length)
		{
			w.where ~= " AND EXISTS (SELECT 1 FROM photo_tags tm WHERE tm.photo_id = p.id AND tm.grp = 'mood' AND tm.tag = ?)";
			w.add(f.mood);
		}
		return w;
	}

	private static string idString(long id)
	{
		import std.conv : to;

		return id.to!string;
	}
}


unittest
{
	import photowagon.core.db.schema : migrate;
	import std.file : tempDir;
	import std.path : buildPath;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	auto repo = new PhotoRepo(db, new ContentStore(buildPath(tempDir, "pw-photos-ut-store")));
	Photo a = {hash: "a", path: "/a.jpg", takenTs: 200, takenAt: "x"};
	Photo b = {hash: "b", path: "/b.jpg", takenTs: 100, takenAt: "y"};
	repo.insert(a);
	repo.insert(b);
	assert(repo.count(Filter.init) == 2);
	auto pg = repo.page(Filter.init, 0, 10);
	assert(pg.length == 2 && pg[0].hash == "a");
	auto nb = repo.neighbours(a.id, Filter.init);
	assert(nb.prev == 0 && nb.next == b.id);
	assert(repo.byPath("/b.jpg").get.id == b.id);
	assert(repo.hasHash("a") && !repo.hasHash("zz"));
	auto j = repo.toJson(pg[0]);
	assert(j["fileUrl"].str == "file:///a.jpg");
	assert(j["lat"].type == JSONType.null_);
	repo.setFavorite(a.id, true);
	Filter fav;
	fav.favorites = true;
	assert(repo.count(fav) == 1 && repo.page(fav, 0, 10)[0].favorite);
	repo.setKind(a.id, "meme", "auto");
	Filter memes;
	memes.kind = "meme";
	assert(repo.count(memes) == 1 && repo.kindCounts()["meme"] == 1 && repo.kindCounts()["unknown"] == 1);
}
