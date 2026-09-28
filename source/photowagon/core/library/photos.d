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
	string weather;
	string holiday;
	string[] keywords; // the user's own tags (core/library/keywords.d)
	string edits;      // edit/edits.d JSON; null = untouched
	string editedHash; // the rendered result in the store
	long durationMs;   // > 0 for a video (kind = 'video'); its running time
	string ocrText;    // text read from the picture (OCR); null = not scanned or nothing found
	long stackId;      // its stack of near-identical photos (core/library/stacks.d); 0 = none
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
	string tagGroup; // photos carrying one tag: scene | mood | weather | holiday …
	string tag;      // … with this value; null = any
	string keyword;  // photos carrying one of the user's own tags; null = any
	string monthDay; // "MM-DD": photos taken on this calendar day in any year (for "On This Day")
	long tsFrom;     // taken_ts >= tsFrom (a moment / event time window); 0 = no lower bound
	long tsTo;       // taken_ts <  tsTo; 0 = no upper bound
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

	/// The content digest kept for `hash` (schema v19): fingerprint, raw piece hashes
	/// (32 bytes each) and the size they describe.
	struct Digest
	{
		string fingerprint;
		ubyte[] pieces;
		long size;
	}

	Nullable!Digest digest(string hash)
	{
		auto s = db.prepare("SELECT fingerprint, pieces, size FROM photo_digest WHERE hash = ?");
		s.bind(1, hash);
		if (!s.step())
			return Nullable!Digest.init;
		return Nullable!Digest(Digest(s.getString(0), s.getBlob(1), s.getLong(2)));
	}

	void setDigest(string hash, string fingerprint, const(ubyte)[] pieces, long size)
	{
		auto s = db.prepare("INSERT OR REPLACE INTO photo_digest (hash, fingerprint, pieces, size) VALUES (?, ?, ?, ?)");
		s.bind(1, hash).bind(2, fingerprint).bind(3, pieces).bind(4, size);
		s.step();
	}

	/// A kept digest that turned out wrong (the file changed where the fingerprint does not
	/// look, or a metadata rewrite kept the size): it goes, and is computed again on use.
	void clearDigest(string hash)
	{
		auto s = db.prepare("DELETE FROM photo_digest WHERE hash = ?");
		s.bind(1, hash);
		s.step();
	}

	/// Only the file's mtime moved (its fingerprint still matches): keep the row, note the time.
	void setMtime(long id, long mtimeMs)
	{
		auto s = db.prepare("UPDATE photos SET mtime_ms = ? WHERE id = ?");
		s.bind(1, mtimeMs).bind(2, id);
		s.step();
	}

	Nullable!Photo byHash(string hash)
	{
		auto s = db.prepare(selectColumns ~ " FROM photos p WHERE p.hash = ?");
		s.bind(1, hash);
		if (!s.step())
			return Nullable!Photo.init;
		return Nullable!Photo(readRow(s));
	}

	/// Whether a file with this content is really here: a row with that hash whose file is on
	/// disk at the recorded size (the row alone outlives a file deleted behind our back until
	/// the next rescan). What the phone's "Free up space" trusts before deleting its copy.
	bool holdsHash(string hash)
	{
		import std.file : exists, getSize, isFile;

		auto s = db.prepare("SELECT path, size FROM photos WHERE hash = ? AND path IS NOT NULL");
		s.bind(1, hash);
		while (s.step())
		{
			immutable path = s.getString(0);
			immutable size = s.getLong(1);
			try
				if (path.length && path.exists && path.isFile && getSize(path) == size)
					return true;
			catch (Exception)
			{
			}
		}
		return false;
	}

	bool hasHash(string hash)
	{
		auto s = db.prepare("SELECT 1 FROM photos WHERE hash = ?");
		s.bind(1, hash);
		return s.step();
	}

	/// Turn a file away for good: a phone that offers this hash during sync negotiation is
	/// told "refuse" and stops pushing it. Recorded when the user deletes an imported photo.
	void decline(string hash)
	{
		if (!hash.length)
			return;
		auto s = db.prepare("INSERT OR IGNORE INTO declined_hashes (hash) VALUES (?)");
		s.bind(1, hash);
		s.run();
	}

	bool isDeclined(string hash)
	{
		auto s = db.prepare("SELECT 1 FROM declined_hashes WHERE hash = ?");
		s.bind(1, hash);
		return s.step();
	}

	/// Welcome a declined file back: a phone offering it is asked to send it again.
	void undecline(string hash)
	{
		if (!hash.length)
			return;
		auto s = db.prepare("DELETE FROM declined_hashes WHERE hash = ?");
		s.bind(1, hash);
		s.run();
	}

	// ---- removed from Wagon (a quarantine: the file stays, the photo leaves) --------------

	/// One photo removed from Wagon, as it was when it left.
	struct Removed
	{
		string hash, fileHash, path;
		long size, mtimeMs;
		string takenAt, thumbHash, kind, removedAt;
	}

	/// The photos `ids` leave the library without their files being touched: their content
	/// (hash) is remembered, so a folder scan does not bring them back and a phone offering
	/// them is turned away — until restoreHashes. Faces and album entries go with the rows.
	/// Returns how many left.
	long removeFromWagon(const(long)[] ids, string[long] fileHashes = null, long[2][long] fileStats = null)
	{
		long n;
		foreach (id; ids)
		{
			auto q = db.prepare("SELECT hash, path, size, mtime_ms, taken_at, thumb_hash, kind FROM photos WHERE id = ?");
			q.bind(1, id);
			if (!q.step())
				continue;
			immutable hash = q.getString(0);
			if (!hash.length)
				continue;   // a remote placeholder: nothing on disk to quarantine
			// the file's bytes may no longer hash to the recorded hash (tags written into the
			// file keep the row's hash): remember those too, or a moved copy would come back
			string fileHash = fileHashes.get(id, null);
			if (fileHash == hash)
				fileHash = null;
			// the file as it is now (size, mtime) when the caller read it, else as on record
			long size = q.getLong(2), mtime = q.getLong(3);
			if (auto st = id in fileStats)
			{
				size = (*st)[0];
				mtime = (*st)[1];
			}
			auto i = db.prepare("INSERT OR REPLACE INTO removed_hashes (hash, file_hash, path, size, mtime_ms, taken_at, thumb_hash, kind) VALUES (?, ?, ?, ?, ?, ?, ?, ?)");
			i.bind(1, hash).bind(2, fileHash).bind(3, q.isNull(1) ? null : q.getString(1)).bind(4, size).bind(5, mtime)
				.bind(6, q.isNull(4) ? null : q.getString(4)).bind(7, q.isNull(5) ? null : q.getString(5))
				.bind(8, q.isNull(6) ? null : q.getString(6));
			i.run();
			remove(id);
			n++;
		}
		return n;
	}

	bool isRemoved(string hash)
	{
		if (!hash.length)
			return false;
		auto s = db.prepare("SELECT 1 FROM removed_hashes WHERE hash = ? OR file_hash = ?");
		s.bind(1, hash).bind(2, hash);
		return s.step();
	}

	/// A file a scan meets again as it was when removed (same path, size and time): skipped
	/// without being hashed.
	bool removedAsIs(string path, long size, long mtimeMs)
	{
		auto s = db.prepare("SELECT 1 FROM removed_hashes WHERE path = ? AND size = ? AND mtime_ms = ?");
		s.bind(1, path).bind(2, size).bind(3, mtimeMs);
		return s.step();
	}

	/// Everything removed from Wagon, the most recent first.
	Removed[] removedList()
	{
		Removed[] out_;
		auto s = db.prepare("SELECT hash, file_hash, path, size, mtime_ms, taken_at, thumb_hash, kind, removed_at FROM removed_hashes ORDER BY removed_at DESC");
		while (s.step())
			out_ ~= Removed(s.getString(0), s.isNull(1) ? null : s.getString(1), s.isNull(2) ? null : s.getString(2),
				s.getLong(3), s.getLong(4), s.isNull(5) ? null : s.getString(5), s.isNull(6) ? null : s.getString(6),
				s.isNull(7) ? null : s.getString(7), s.getString(8));
		return out_;
	}

	/// One removed photo for the UI: what it was, its kept thumbnail, whether its file is
	/// still where it was.
	JSONValue removedToJson(Removed r)
	{
		import std.file : exists;
		import std.path : baseName;

		bool there;
		try
			there = r.path.length && r.path.exists;
		catch (Exception)
		{
		}
		JSONValue j = [
			"hash": JSONValue(r.hash),
			"path": r.path is null ? JSONValue(null) : JSONValue(r.path),
			"name": r.path is null ? JSONValue(null) : JSONValue(r.path.baseName),
			"size": JSONValue(r.size),
			"takenAt": r.takenAt is null ? JSONValue(null) : JSONValue(r.takenAt),
			"kind": r.kind is null ? JSONValue(null) : JSONValue(r.kind),
			"removedAt": JSONValue(r.removedAt),
			"exists": JSONValue(there),
		];
		j["thumbUrl"] = JSONValue(null);
		if (r.thumbHash.length)
			try
			{
				immutable tp = store.pathFor(r.thumbHash);
				if (tp.exists)
					j["thumbUrl"] = JSONValue(fileUrl(tp));
			}
			catch (Exception)
			{
			}
		return j;
	}

	/// Take `hashes` out of quarantine; returns what they were (the caller indexes the files
	/// that are still there).
	Removed[] restoreHashes(const(string)[] hashes)
	{
		Removed[] back;
		foreach (h; hashes)
		{
			auto s = db.prepare("SELECT hash, file_hash, path, size, mtime_ms, taken_at, thumb_hash, kind, removed_at FROM removed_hashes WHERE hash = ?");
			s.bind(1, h);
			if (!s.step())
				continue;
			back ~= Removed(s.getString(0), s.isNull(1) ? null : s.getString(1), s.isNull(2) ? null : s.getString(2),
				s.getLong(3), s.getLong(4), s.isNull(5) ? null : s.getString(5), s.isNull(6) ? null : s.getString(6),
				s.isNull(7) ? null : s.getString(7), s.getString(8));
			auto d = db.prepare("DELETE FROM removed_hashes WHERE hash = ?");
			d.bind(1, h);
			d.run();
			// restoring is asking for it back: a decline from an earlier deletion goes too
			undecline(h);
			undecline(back[$ - 1].fileHash);
		}
		return back;
	}

	/// The photos whose file lies under `dir` (the phones' imports folder): how many, and their
	/// bytes on record.
	long[2] countUnder(string dir)
	{
		long n, bytes;
		foreach (ref row; rowsUnder(dir))
		{
			n++;
			bytes += row.size;
		}
		return [n, bytes];
	}

	/// Every photo whose file lies under `dir` leaves the library: its file goes through
	/// `dispose` (the trash), then its row (faces and album entries follow by cascade). Unlike
	/// photo.delete the hash is NOT turned away — any decline is lifted — so the phone that sent
	/// it may send it again. A file `dispose` could not move keeps its row (it is still here).
	/// Returns [removed, failed].
	long[2] removeUnder(string dir, void delegate(string path) dispose)
	{
		import std.file : exists;

		long removed, failed;
		foreach (ref row; rowsUnder(dir))
		{
			try
			{
				if (row.path.exists)
					dispose(row.path);
			}
			catch (Exception)
			{
				failed++;
				continue;
			}
			remove(row.id);
			undecline(row.hash);
			removed++;
		}
		return [removed, failed];
	}

	private struct UnderRow { long id; string path, hash; long size; }

	/// The rows under `dir` by what the paths ARE, not how they are spelled: the data folder
	/// may be reached through a symlink now and was not when the photos landed (or the other
	/// way round), so a stored path is inside when its folder resolves inside `dir`'s real
	/// place — or, for a file gone from disk, when it is spelled inside `dir`. Candidates are
	/// the rows with the folder's name in their path.
	private UnderRow[] rowsUnder(string dir)
	{
		import std.algorithm : startsWith;
		import std.path : baseName, dirName;

		immutable spelled = dirPrefix(dir);
		immutable real_ = dirPrefix(realPathOr(dir));
		immutable needle = "/" ~ baseName(dir.length > 1 && dir[$ - 1] == '/' ? dir[0 .. $ - 1] : dir) ~ "/";
		string[string] resolved;   // a folder → its real place (one lookup per folder)
		UnderRow[] rows;
		auto s = db.prepare("SELECT id, path, hash, size FROM photos WHERE path IS NOT NULL AND instr(path, ?) > 0");
		s.bind(1, needle);
		while (s.step())
		{
			auto row = UnderRow(s.getLong(0), s.getString(1), s.isNull(2) ? null : s.getString(2), s.getLong(3));
			bool inside = row.path.startsWith(spelled) || row.path.startsWith(real_);
			if (!inside)
			{
				immutable folder = dirName(row.path);
				auto r = folder in resolved;
				immutable where = r ? *r : (resolved[folder] = dirPrefix(realPathOr(folder)));
				inside = where.startsWith(real_);
			}
			if (inside)
				rows ~= row;
		}
		return rows;
	}

	/// The real place of `path` (symlinks resolved), or `path` itself when it cannot be had.
	private static string realPathOr(string path)
	{
		import core.stdc.stdlib : free;
		import core.sys.posix.stdlib : realpath;
		import std.string : fromStringz, toStringz;

		auto r = realpath(path.toStringz, null);
		if (r is null)
			return path;
		scope (exit)
			free(r);
		return r.fromStringz.idup;
	}

	private static string dirPrefix(string dir)
	{
		return dir.length && dir[$ - 1] == '/' ? dir : dir ~ "/";
	}

	long insert(ref Photo p)
	{
		auto s = db.prepare(`INSERT INTO photos (hash, path, root_id, size, mtime_ms, taken_ts, taken_at,
			width, height, orientation, camera, lat, lon, thumb_hash, origin_peer, kind, kind_by, duration_ms)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`);
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
			thumb_hash = ?, origin_peer = ?, kind = ?, kind_by = ?, duration_ms = ? WHERE id = ?`);
		bindPhoto(s, p);
		s.bind(19, p.id);
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
		s.bind(14, p.thumbHash).bind(15, p.originPeer).bind(16, p.kind).bind(17, p.kindBy).bind(18, p.durationMs);
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

	private static JSONValue parseEdits(string json)
	{
		try
			return parseJSON(json);
		catch (Exception)
			return JSONValue(null);
	}

	/// The rendered result of the user's edits (null everywhere = reverted).
	void setEdits(long id, string editsJson, string editedHash, string thumbHash, int width, int height)
	{
		auto s = db.prepare("UPDATE photos SET edits = ?, edited_hash = ?, thumb_hash = ?, width = ?, height = ? WHERE id = ?");
		s.bind(1, editsJson).bind(2, editedHash).bind(3, thumbHash).bind(4, cast(long) width).bind(5, cast(long) height).bind(6, id);
		s.run();
	}

	/// The path the viewer and the region renderer should read: the edited result when there is one.
	string displayPath(ref const Photo p)
	{
		return p.editedHash !is null ? store.pathFor(p.editedHash) : p.path;
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

	/// The WHOLE listing of a filter, lean: only what the grid draws and selects with (id,
	/// date, size, kind, heart, video length, stack, thumbnail, path, the classifiers' words
	/// shown on hover). The grid lays out every photo from this at once and loads only the
	/// thumbnails on screen (9080 photos: ~40 ms, ~1.7 MB). Same order as page().
	/// `hashes`: also the start of each content hash and the file size (the phone leaves out
	/// the computer's copies of its own photos by them).
	JSONValue[] skeleton(Filter f, bool hashes = false)
	{
		auto w = whereClause(f);
		auto s = db.prepare(`SELECT p.id, p.taken_ts, p.width, p.height, p.kind, p.favorite, p.duration_ms,
			p.stack_id, p.thumb_hash, p.path, p.origin_peer,
			(SELECT t.tag FROM photo_tags t WHERE t.photo_id = p.id AND t.grp = 'scene' AND t.tag <> ''),
			(SELECT t.tag FROM photo_tags t WHERE t.photo_id = p.id AND t.grp = 'holiday' AND t.tag <> ''),
			(SELECT t.tag FROM photo_tags t WHERE t.photo_id = p.id AND t.grp = 'weather' AND t.tag <> ''),
			p.hash, p.size
			FROM photos p` ~ w.joins ~ w.where
				~ (f.albumId ? " ORDER BY ap.position ASC" : " ORDER BY p.taken_ts DESC, p.id DESC"));
		w.bind(s);
		JSONValue[] out_;
		while (s.step())
		{
			JSONValue j = JSONValue.emptyObject;
			j["id"] = s.getLong(0);
			j["takenTs"] = s.getLong(1);
			j["width"] = s.getLong(2);
			j["height"] = s.getLong(3);
			immutable kind = s.getString(4);
			j["kind"] = kind is null ? JSONValue(null) : JSONValue(kind);
			j["favorite"] = s.getLong(5) != 0;
			j["video"] = kind == "video";
			j["duration"] = s.getLong(6);
			j["stack"] = s.isNull(7) ? JSONValue(null) : JSONValue(s.getLong(7));
			j["thumbUrl"] = s.isNull(8) ? JSONValue(null) : JSONValue(fileUrl(store.pathFor(s.getString(8))));
			j["path"] = s.isNull(9) ? JSONValue(null) : JSONValue(s.getString(9));
			j["remote"] = !s.isNull(10);
			foreach (k, name; ["scene", "holiday", "weather"])
				j[name] = s.isNull(cast(int)(11 + k)) ? JSONValue(null) : JSONValue(s.getString(cast(int)(11 + k)));
			if (hashes)
			{
				immutable h = s.getString(14);
				j["hash16"] = h.length > 16 ? h[0 .. 16] : h;
				j["size"] = s.getLong(15);
			}
			out_ ~= j;
		}
		return out_;
	}

	/// Photos taken on the same calendar day(s) as any of `seedIds`, minus the seeds
	/// themselves — the "you're adding photos of an event; here's the rest of that day"
	/// suggestion. Newest first, capped at `limit`. Photos without a date are ignored.
	Photo[] sameDayAs(long[] seedIds, long limit)
	{
		import std.algorithm : map;
		import std.array : array, join;

		if (seedIds.length == 0)
			return null;
		immutable ph = seedIds.map!(_ => "?").array.join(",");   // ?,?,… — one per seed id
		auto s = db.prepare(selectColumns ~ " FROM photos p"
			~ " WHERE p.taken_ts > 0"
			~ " AND strftime('%Y-%m-%d', p.taken_ts, 'unixepoch', 'localtime') IN"
			~ " (SELECT strftime('%Y-%m-%d', taken_ts, 'unixepoch', 'localtime')"
			~ "  FROM photos WHERE id IN (" ~ ph ~ ") AND taken_ts > 0)"
			~ " AND p.id NOT IN (" ~ ph ~ ")"
			~ " AND (p.kind = 'photo' OR p.kind IS NULL)"
			~ " ORDER BY p.taken_ts DESC, p.id DESC LIMIT ?");
		int i = 0;
		foreach (id; seedIds)
			s.bind(++i, id);                       // the day-key subquery
		foreach (id; seedIds)
			s.bind(++i, id);                       // the NOT IN exclusion
		s.bind(++i, limit < 1 ? 1 : limit);
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
			"weather": p.weather is null ? JSONValue(null) : JSONValue(p.weather),
			"holiday": p.holiday is null ? JSONValue(null) : JSONValue(p.holiday),
			"keywords": JSONValue(p.keywords),
			"edits": p.edits is null ? JSONValue(null) : parseEdits(p.edits),
			"editedUrl": p.editedHash is null ? JSONValue(null) : JSONValue(fileUrl(store.pathFor(p.editedHash))),
			"video": JSONValue(p.kind == "video"),
			"duration": JSONValue(p.durationMs),
			"ocrText": JSONValue(p.ocrText),
			"stack": p.stackId ? JSONValue(p.stackId) : JSONValue(null),
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
		(SELECT t.tag FROM photo_tags t WHERE t.photo_id = p.id AND t.grp = 'mood' AND t.tag <> ''),
		(SELECT t.tag FROM photo_tags t WHERE t.photo_id = p.id AND t.grp = 'weather' AND t.tag <> ''),
		(SELECT t.tag FROM photo_tags t WHERE t.photo_id = p.id AND t.grp = 'holiday' AND t.tag <> ''),
		(SELECT group_concat(k.keyword, char(31)) FROM (SELECT keyword FROM photo_keywords WHERE photo_id = p.id ORDER BY keyword) k),
		p.edits, p.edited_hash, p.duration_ms, p.ocr_text, p.stack_id`;

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
		p.weather = s.getString(24);
		p.holiday = s.getString(25);
		if (!s.isNull(26))
		{
			import std.array : split;
			p.keywords = s.getString(26).split("\x1f");
		}
		p.edits = s.getString(27);
		p.editedHash = s.getString(28);
		p.durationMs = s.getLong(29);
		p.ocrText = s.getString(30);
		p.stackId = s.isNull(31) ? 0 : s.getLong(31);
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
		// JOINs first, so their bound values precede the WHERE values (bind order = call order).
		if (f.albumId)
		{
			w.joins ~= " JOIN album_photos ap ON ap.photo_id = p.id AND ap.album_id = ?";
			w.add(f.albumId);
		}
		if (f.personId)
		{
			// Drive from the faces index (person_id): a person's photos are a few hundred, so
			// this seeks them straight away. The old correlated EXISTS scanned every photo in
			// the library and ran a subquery per row — ~0.8 s on a big library, now a few ms.
			// GROUP BY dedups the (rare) two-faces-of-one-person-in-a-photo case.
			w.joins ~= " JOIN (SELECT photo_id FROM faces WHERE person_id = ? GROUP BY photo_id) fp ON fp.photo_id = p.id";
			w.add(f.personId);
		}
		if (f.rootId)
		{
			w.where ~= " AND p.root_id = ?";
			w.add(f.rootId);
		}
		if (f.favorites)
			w.where ~= " AND p.favorite = 1";
		if (f.kind == "photo")
			w.where ~= " AND (p.kind = 'photo' OR p.kind IS NULL)";   // not classified yet counts as a photograph
		else if (f.kind == "media")   // the library's own view: photos and videos, not screenshots or memes
			w.where ~= " AND (p.kind IN ('photo', 'video') OR p.kind IS NULL)";
		else if (f.kind.length)
		{
			w.where ~= " AND p.kind = ?";
			w.add(f.kind);
		}
		if (f.text.length)
		{
			import std.string : replace;

			// the file/folder name, and the text read from inside the picture (OCR)
			immutable like = "%" ~ f.text.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_") ~ "%";
			w.where ~= " AND (p.path LIKE ? ESCAPE '\\' OR p.ocr_text LIKE ? ESCAPE '\\')";
			w.add(like);
			w.add(like);
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
		if (f.keyword.length)
		{
			w.where ~= " AND EXISTS (SELECT 1 FROM photo_keywords kw WHERE kw.photo_id = p.id AND kw.keyword = ? COLLATE NOCASE)";
			w.add(f.keyword);
		}
		if (f.tag.length && f.tagGroup.length)
		{
			w.where ~= " AND EXISTS (SELECT 1 FROM photo_tags tg WHERE tg.photo_id = p.id AND tg.grp = ? AND tg.tag = ?)";
			w.add(f.tagGroup);
			w.add(f.tag);
		}
		if (f.monthDay.length)
		{
			w.where ~= " AND strftime('%m-%d', p.taken_ts, 'unixepoch', 'localtime') = ?";
			w.add(f.monthDay);
		}
		if (f.tsFrom)
		{
			w.where ~= " AND p.taken_ts >= ?";
			w.add(f.tsFrom);
		}
		if (f.tsTo)
		{
			w.where ~= " AND p.taken_ts < ?";
			w.add(f.tsTo);
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

unittest
{
	// holdsHash: the row AND its file on disk at the recorded size (Free up space trusts it)
	import photowagon.core.db.schema : migrate;
	import std.file : tempDir, write, remove, exists, mkdirRecurse;
	import std.path : buildPath;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	immutable dir = buildPath(tempDir, "pw-holds-ut");
	mkdirRecurse(dir);
	immutable here = buildPath(dir, "here.jpg"), gone = buildPath(dir, "gone.jpg"), grew = buildPath(dir, "grew.jpg");
	write(here, "12345");
	write(grew, "12345678");
	scope (exit)
		foreach (f; [here, grew])
			if (f.exists)
				remove(f);
	auto repo = new PhotoRepo(db, new ContentStore(buildPath(dir, "store")));
	Photo a = {hash: "h1", path: here, size: 5, takenAt: "x"};
	Photo b = {hash: "h2", path: gone, size: 5, takenAt: "x"};
	Photo c = {hash: "h3", path: grew, size: 5, takenAt: "x"};
	repo.insert(a);
	repo.insert(b);
	repo.insert(c);
	assert(repo.holdsHash("h1"));
	assert(repo.hasHash("h2") && !repo.holdsHash("h2"));   // a row, no file
	assert(!repo.holdsHash("h3"));                          // a file, not the size recorded
	assert(!repo.holdsHash("nope"));
}

unittest
{
	// removeUnder: the imports folder's photos leave (files through dispose, rows gone), their
	// hashes are welcomed back (not declined), photos elsewhere and in a look-alike folder stay
	import photowagon.core.db.schema : migrate;
	import std.file : tempDir, write, exists, mkdirRecurse, rmdirRecurse;
	import std.path : buildPath;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	immutable dir = buildPath(tempDir, "pw-rmimports-ut");
	if (dir.exists)
		rmdirRecurse(dir);
	immutable imports = buildPath(dir, "imports"), twin = buildPath(dir, "imports-other");
	mkdirRecurse(buildPath(imports, "2026-09"));
	mkdirRecurse(twin);
	scope (exit)
		rmdirRecurse(dir);
	immutable p1 = buildPath(imports, "2026-09", "a.jpg"), p2 = buildPath(imports, "b.jpg"),
		p3 = buildPath(twin, "c.jpg"), p4 = buildPath(imports, "stuck.jpg");
	foreach (f; [p1, p2, p3, p4])
		write(f, "12345");
	auto repo = new PhotoRepo(db, new ContentStore(buildPath(dir, "store")));
	Photo a = {hash: "i1", path: p1, size: 5, takenAt: "x"};
	Photo b = {hash: "i2", path: p2, size: 7, takenAt: "x"};
	Photo c = {hash: "o1", path: p3, size: 5, takenAt: "x"};
	Photo d = {hash: "i3", path: p4, size: 5, takenAt: "x"};
	repo.insert(a);
	repo.insert(b);
	repo.insert(c);
	repo.insert(d);
	repo.decline("i2");   // turned away earlier: must be welcomed back
	assert(repo.countUnder(imports) == [3L, 17L]);
	string[] disposed;
	auto r = repo.removeUnder(imports ~ "/", (string path) {
		if (path == p4)
			throw new Exception("trash refused");
		disposed ~= path;
	});
	assert(r == [2L, 1L]);
	assert(disposed.length == 2);
	assert(!repo.hasHash("i1") && !repo.hasHash("i2"));
	assert(repo.hasHash("i3"));                          // its file could not go: kept
	assert(repo.hasHash("o1"));                          // "imports-other" is not under imports/
	assert(!repo.isDeclined("i1") && !repo.isDeclined("i2"));
	assert(repo.countUnder(imports) == [1L, 5L]);

	// the data folder reached through a symlink now: the stored (real) paths still count
	import std.file : symlink;

	immutable alias_ = buildPath(dir, "alias");
	symlink(dir, alias_);
	assert(repo.countUnder(buildPath(alias_, "imports")) == [1L, 5L]);
	// and the other way round: stored through the alias, asked by the real path
	immutable p5 = buildPath(alias_, "imports", "e.jpg");
	write(p5, "123");
	Photo e = {hash: "i5", path: p5, size: 3, takenAt: "x"};
	repo.insert(e);
	assert(repo.countUnder(imports) == [2L, 8L]);
	auto r2 = repo.removeUnder(imports, (string path) {});
	assert(r2 == [2L, 0L]);   // e.jpg and stuck.jpg (dispose does not refuse now)
	assert(!repo.hasHash("i5") && repo.hasHash("o1"));
}

unittest
{
	// removed from Wagon: the row leaves, the content is remembered (scan skip by path/size/
	// mtime, refusal by hash), the list shows it, restore takes it out of quarantine
	import photowagon.core.db.schema : migrate;
	import std.file : tempDir;
	import std.path : buildPath;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	auto repo = new PhotoRepo(db, new ContentStore(buildPath(tempDir, "pw-removed-ut-store")));
	Photo a = {hash: "q1", path: "/p/a.jpg", size: 5, mtimeMs: 1000, takenAt: "2020-01-01T00:00:00Z", thumbHash: "t1", kind: "photo"};
	Photo b = {hash: "q2", path: "/p/b.jpg", size: 6, mtimeMs: 2000, takenAt: "x"};
	repo.insert(a);
	repo.insert(b);
	immutable ida = repo.byHash("q1").get.id;
	assert(repo.removeFromWagon([ida, 999_999]) == 1);
	assert(!repo.hasHash("q1") && repo.hasHash("q2"));
	assert(repo.isRemoved("q1") && !repo.isRemoved("q2") && !repo.isRemoved(""));
	assert(repo.removedAsIs("/p/a.jpg", 5, 1000));
	assert(!repo.removedAsIs("/p/a.jpg", 5, 1001));   // touched since: hashed again (and judged by hash)
	auto l = repo.removedList();
	assert(l.length == 1 && l[0].hash == "q1" && l[0].path == "/p/a.jpg" && l[0].thumbHash == "t1" && l[0].removedAt.length);
	// a tagged file's bytes hash differently from the row: both keys are kept out
	immutable idb = repo.byHash("q2").get.id;
	repo.decline("q2");
	assert(repo.removeFromWagon([idb], [idb: "q2file"]) == 1);
	assert(repo.isRemoved("q2") && repo.isRemoved("q2file"));
	assert(repo.restoreHashes(["q2"]).length == 1 && !repo.isRemoved("q2file") && !repo.isDeclined("q2"));
	auto back = repo.restoreHashes(["q1", "nope"]);
	assert(back.length == 1 && back[0].path == "/p/a.jpg");
	assert(!repo.isRemoved("q1") && repo.removedList().length == 0);
}
