/// The organization of the library, the same on every computer of the user: in-app deletions,
/// "removed from Wagon" (and its restore), favorites, albums and what is in them, the user's
/// keywords, a kind set by hand, and the names given to faces. (Phase 2, core/sync/mirror.d,
/// makes the FILES the same; this makes what the user did to them the same.)
///
/// State-based, last writer wins. Every replicated fact is one row of meta_state, keyed by
/// (kind, key) with content hashes in the keys (never local ids): its value, the hybrid
/// clock of its last change (`hlc`: wall ms, a counter, this node — sortable as text) and a
/// local sequence number. Nothing hooks the individual APIs: `refresh` derives the current
/// facts from the library tables and records whatever differs from meta_state as a local
/// change (a new hlc) — so every way the user changes something (a menu, the Tools cleanup,
/// a merge of two people) is seen. Another computer pages through our rows by sequence
/// (`meta.since`); what it takes it records with OUR hlc and applies, so a fact travels
/// A→B→C and comes back to A as nothing new (the same hlc is not newer): no echo.
///
/// Kinds (key → value):
///   del   hash → "1" deleted in the app (declined; the file went to the Trash) · "0" undone
///   rm    hash → "1" removed from Wagon (the file stays) · "0" restored
///   fav   hash → "1" · "0"
///   kw    hash|keyword → "1" the user put that keyword on the photo · "0" took it off (one
///         row per keyword, not the set: two computers that each hold part of a photo's
///         keywords end with all of them, and a removal travels as itself)
///   kind  hash → the kind the user set by hand
///   album uid  → {"name":…} · "" deleted
///   ap    uid|hash → "1" in that album · "0" taken out
///   face  hash|x|y|w|h → the name of the person on that face ("" = unnamed). People are
///         clusters that differ from computer to computer, so a NAME travels per face: the
///         receiving computer finds its own face on that photo that overlaps the box and names
///         it (directly, FaceService.nameFaceFromPeer — an unnamed group takes the name as a whole). Each computer then
///         states the name for its own box too; both converge on the same name.
///
/// A fact about a photo that is not here yet (the mirror has not brought it, its faces have
/// not been found yet) waits in meta_pending and is applied when it can be.
///
/// Deletions only move files to the Trash (photo.delete), and many at once are not applied
/// unasked: more than `massDeletion` files, or more than a fifth of the library, from one
/// exchange wait in meta_held for the user to apply or keep (computers.applyDeletions). A
/// file missing because it was removed outside the app is not a deletion: nothing records it
/// (it is not declined), and the mirror brings it back.
module photowagon.core.sync.meta;

import std.json;
import std.conv : to;
import std.format : format;
import std.algorithm : sort;
import std.array : join, split;

import vibe.core.log : logInfo, logWarn;
import vibe.core.sync : TaskMutex;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.protocol : Registry;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.library.keywords : KeywordService;

/// More in-app deletions than this from one exchange wait for the user.
enum long massDeletion = 200;
/// …or more than this share of the library.
enum double massDeletionShare = 0.20;
/// A fact about a photo that never arrives is dropped after this many days.
enum long pendingDays = 30;
private enum int pageLimit = 1000;

/// One replicated fact.
struct MetaRow
{
	string kind, key, value, hlc;
	long seq;
}

/// A hybrid logical clock stamp: wall ms, a counter for the same ms, the node — fixed width,
/// so text order is time order (the node breaks exact ties).
string hlcText(long wall, long counter, string node) pure @safe
{
	return format("%013d-%06d-%s", wall, counter, node);
}

/// (wall, counter) of a stamp, or (0, 0) if it is not one.
long[2] hlcParts(string hlc) pure @safe nothrow
{
	try
	{
		auto p = hlc.split('-');
		if (p.length >= 2)
			return [p[0].to!long, p[1].to!long];
	}
	catch (Exception)
	{
	}
	return [0, 0];
}

/// meta_state and its clock.
final class MetaStore
{
	private Database db;
	private string delegate() nothrow nodeKey;   // this node's key (hex): known once the node is up

	this(Database db, string delegate() nothrow nodeKey)
	{
		this.db = db;
		this.nodeKey = nodeKey;
	}

	private string node()
	{
		immutable k = nodeKey();
		return k.length > 16 ? k[0 .. 16] : (k.length ? k : "0000000000000000");
	}

	private long nowMs() const
	{
		import std.datetime.systime : Clock;

		return Clock.currStdTime / 10_000 - 62_135_596_800_000L;   // hnsecs since 0001 → unix ms
	}

	/// The next local stamp: never behind the wall clock, never behind anything seen.
	string next()
	{
		auto s = db.prepare("SELECT wall, counter FROM meta_clock WHERE id = 1");
		s.step();
		long wall = s.getLong(0), counter = s.getLong(1);
		immutable now = nowMs();
		if (now > wall)
		{
			wall = now;
			counter = 0;
		}
		else
			counter++;
		auto u = db.prepare("UPDATE meta_clock SET wall = ?, counter = ? WHERE id = 1");
		u.bind(1, wall).bind(2, counter);
		u.run();
		return hlcText(wall, counter, node);
	}

	/// A stamp from another computer: our clock moves past it (the next local change is later).
	void observe(string hlc)
	{
		immutable p = hlcParts(hlc);
		auto u = db.prepare("UPDATE meta_clock SET wall = ?, counter = ? WHERE id = 1 AND (wall < ? OR (wall = ? AND counter < ?))");
		u.bind(1, p[0]).bind(2, p[1]).bind(3, p[0]).bind(4, p[0]).bind(5, p[1]);
		u.run();
	}

	private long nextSeq()
	{
		db.exec("UPDATE meta_clock SET seq = seq + 1 WHERE id = 1");
		auto s = db.prepare("SELECT seq FROM meta_clock WHERE id = 1");
		s.step();
		return s.getLong(0);
	}

	bool get(string kind, string key, out MetaRow row)
	{
		auto s = db.prepare("SELECT value, hlc, seq FROM meta_state WHERE kind = ? AND key = ?");
		s.bind(1, kind).bind(2, key);
		if (!s.step())
			return false;
		row = MetaRow(kind, key, s.getString(0), s.getString(1), s.getLong(2));
		return true;
	}

	private void put(string kind, string key, string value, string hlc)
	{
		auto s = db.prepare("INSERT OR REPLACE INTO meta_state (kind, key, value, hlc, seq) VALUES (?, ?, ?, ?, ?)");
		// "" read back from sqlite is a null slice (getString's idup), which would bind as NULL
		s.bind(1, kind).bind(2, key).bind(3, value is null ? "" : value).bind(4, hlc).bind(5, nextSeq());
		s.run();
	}

	/// A local change: recorded (a new stamp) only if the value differs. True when recorded.
	bool record(string kind, string key, string value)
	{
		MetaRow cur;
		if (get(kind, key, cur) && cur.value == value)
			return false;
		put(kind, key, value, next());
		return true;
	}

	/// Whether another computer's fact is newer than ours (last writer wins).
	bool isNewer(ref const MetaRow r)
	{
		MetaRow cur;
		return !get(r.kind, r.key, cur) || r.hlc > cur.hlc;
	}

	/// Take another computer's fact as ours (its stamp kept, a new local sequence so the
	/// computers we serve see it too). False (nothing done) when ours is as new or newer.
	bool take(ref const MetaRow r)
	{
		observe(r.hlc);
		if (!isNewer(r))
			return false;
		put(r.kind, r.key, r.value, r.hlc);
		return true;
	}

	/// This library's sequence space (another after a reset of its organization).
	string epoch()
	{
		auto s = db.prepare("SELECT epoch FROM meta_clock WHERE id = 1");
		s.step();
		return s.getString(0);
	}

	/// Our facts changed after sequence `after`, oldest first.
	MetaRow[] since(long after, int limit)
	{
		MetaRow[] out_;
		auto s = db.prepare("SELECT kind, key, value, hlc, seq FROM meta_state WHERE seq > ? ORDER BY seq LIMIT ?");
		s.bind(1, after).bind(2, cast(long) limit);
		while (s.step())
			out_ ~= MetaRow(s.getString(0), s.getString(1), s.getString(2), s.getString(3), s.getLong(4));
		return out_;
	}

	/// Every row of a kind (for refresh).
	string[string] all(string kind)
	{
		string[string] out_;
		auto s = db.prepare("SELECT key, value FROM meta_state WHERE kind = ?");
		s.bind(1, kind);
		while (s.step())
			out_[s.getString(0)] = s.getString(1);
		return out_;
	}

	/// The epoch we last read `peer` in ("" never).
	string lastEpoch(string peer)
	{
		auto s = db.prepare("SELECT epoch FROM meta_cursor WHERE peer = ?");
		s.bind(1, peer);
		return s.step() && !s.isNull(0) ? s.getString(0) : "";
	}

	/// How far we read `peer`, in its epoch `peerEpoch`: 0 when that epoch is not the one the
	/// cursor was counted in (its organization was reset — read it all again).
	long cursor(string peer, string peerEpoch)
	{
		auto s = db.prepare("SELECT seq, epoch FROM meta_cursor WHERE peer = ?");
		s.bind(1, peer);
		if (!s.step())
			return 0;
		return (s.isNull(1) ? "" : s.getString(1)) == peerEpoch ? s.getLong(0) : 0;
	}

	void setCursor(string peer, long seq, string peerEpoch)
	{
		auto s = db.prepare("INSERT OR REPLACE INTO meta_cursor (peer, seq, epoch) VALUES (?, ?, ?)");
		s.bind(1, peer).bind(2, seq).bind(3, peerEpoch);
		s.run();
	}

	// ---- pending: facts whose photo is not here yet ---------------------------------------

	void addPending(string kind, string key)
	{
		import std.datetime.systime : Clock;

		auto s = db.prepare("INSERT OR IGNORE INTO meta_pending (kind, key, since) VALUES (?, ?, ?)");
		s.bind(1, kind).bind(2, key).bind(3, Clock.currTime.toUnixTime);
		s.run();
	}

	void dropPending(string kind, string key)
	{
		auto s = db.prepare("DELETE FROM meta_pending WHERE kind = ? AND key = ?");
		s.bind(1, kind).bind(2, key);
		s.run();
	}

	bool[string] pendingKeys(string kind)
	{
		bool[string] out_;
		auto s = db.prepare("SELECT key FROM meta_pending WHERE kind = ?");
		s.bind(1, kind);
		while (s.step())
			out_[s.getString(0)] = true;
		return out_;
	}

	/// Pending facts with their current value (the latest taken), dropping the stale ones.
	MetaRow[] pending()
	{
		import std.datetime.systime : Clock;

		auto d = db.prepare("DELETE FROM meta_pending WHERE since < ?");
		d.bind(1, Clock.currTime.toUnixTime - pendingDays * 86_400);
		d.run();
		MetaRow[] out_;
		auto s = db.prepare("SELECT p.kind, p.key, m.value, m.hlc, m.seq FROM meta_pending p JOIN meta_state m ON m.kind = p.kind AND m.key = p.key");
		while (s.step())
			out_ ~= MetaRow(s.getString(0), s.getString(1), s.getString(2), s.getString(3), s.getLong(4));
		return out_;
	}

	// ---- held: deletions waiting for the user ---------------------------------------------

	void hold(string peer, string key, string hlc)
	{
		auto s = db.prepare("INSERT OR REPLACE INTO meta_held (peer, key, hlc) VALUES (?, ?, ?)");
		s.bind(1, peer).bind(2, key).bind(3, hlc);
		s.run();
	}

	MetaRow[] held(string peer)
	{
		MetaRow[] out_;
		auto s = db.prepare("SELECT key, hlc FROM meta_held WHERE peer = ?");
		s.bind(1, peer);
		while (s.step())
			out_ ~= MetaRow("del", s.getString(0), "1", s.getString(1), 0);
		return out_;
	}

	long heldCount(string peer)
	{
		auto s = db.prepare("SELECT count(*) FROM meta_held WHERE peer = ?");
		s.bind(1, peer);
		s.step();
		return s.getLong(0);
	}

	void clearHeld(string peer)
	{
		auto s = db.prepare("DELETE FROM meta_held WHERE peer = ?");
		s.bind(1, peer);
		s.run();
	}

	/// The newest stamp of a deletion of `key` waiting for the user (from any computer), or "".
	string heldHlc(string key)
	{
		auto s = db.prepare("SELECT max(hlc) FROM meta_held WHERE key = ?");
		s.bind(1, key);
		return s.step() && !s.isNull(0) ? s.getString(0) : "";
	}

	/// A newer fact about `key` was taken: whatever deletion of it waited is moot.
	void unhold(string key)
	{
		auto s = db.prepare("DELETE FROM meta_held WHERE key = ?");
		s.bind(1, key);
		s.run();
	}

	/// The user kept `key` here against a deletion up to stamp `hlc`.
	void keep(string key, string hlc)
	{
		auto s = db.prepare("INSERT INTO meta_kept (key, hlc) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET hlc = max(hlc, excluded.hlc)");
		s.bind(1, key).bind(2, hlc);
		s.run();
	}

	/// Whether a deletion of `key` stamped `hlc` was already turned down by the user.
	bool isKept(string key, string hlc)
	{
		auto s = db.prepare("SELECT 1 FROM meta_kept WHERE key = ? AND hlc >= ?");
		s.bind(1, key).bind(2, hlc);
		return s.step();
	}
}

/// What one pull from another computer did.
struct PullResult
{
	long taken, applied, pending, held;
}

/// Glue between meta_state and the library: derive, serve, pull, apply.
final class MetaSync
{
	private Database db;
	private MetaStore store;
	private PhotoRepo photos;
	private Registry registry;
	private Events events;
	// every application of facts (a pull, a decision about held deletions) runs alone: two
	// pulls from two computers could otherwise apply an older fact after a newer one (an apply
	// yields). Serving (meta.since) never takes it — two computers pulling each other at once
	// would each wait for the other.
	private TaskMutex applying;
	/// Keywords taken from another computer go in here directly, NOT rewriting the file (see
	/// KeywordService.add); null (tests): through photo.addKeywords.
	KeywordService keywords;
	/// Names a face with a name from another computer, directly (FaceService.nameFaceFromPeer),
	/// and settles a batch of them; null (no vision here): the face.setPerson API.
	void delegate(long faceId, string name) nameFace;
	void delegate() settleFaces;
	private long seenDirty = -1;   // meta_dirty.n right after the last full refresh (-1: never)
	/// The guard (see the module comment); fields so a test can lower them.
	long massDeletionCount = massDeletion;
	double massDeletionFraction = massDeletionShare;

	this(Database db, string delegate() nothrow nodeKey, PhotoRepo photos, Registry registry, Events events)
	{
		this.db = db;
		store = new MetaStore(db, nodeKey);
		applying = new TaskMutex;
		this.photos = photos;
		this.registry = registry;
		this.events = events;
	}

	MetaStore metaStore()
	{
		return store;
	}

	// ---- the local facts ------------------------------------------------------------------

	private string[] column(string sql)
	{
		string[] out_;
		auto s = db.prepare(sql);
		while (s.step())
			out_ ~= s.getString(0);
		return out_;
	}

	private bool[string] set(string sql)
	{
		bool[string] out_;
		foreach (v; column(sql))
			out_[v] = true;
		return out_;
	}

	/// Photos that are here as a row we have not seen at the last pass (brought back after
	/// their file was deleted outside the app, re-imported): the facts meta_state already has
	/// about them are applied again — the new row starts empty, and reading that as the user
	/// taking everything off would undo the organization on every computer. Returns how many
	/// such photos there were.
	long reapplyArrivals()
	{
		// the rows made since the last pass (a trigger notes each local photo row inserted)
		string[] arrived;
		{
			auto s = db.prepare("SELECT hash FROM meta_arrived");
			while (s.step())
				arrived ~= s.getString(0);
		}
		if (!arrived.length)
			return 0;
		events.hold();
		scope (exit)
			events.release();
		bool faces;
		scope (exit)
			if (faces)
				settle();
		foreach (h; arrived)
		{
			// the marker goes only once this photo's facts are all applied again: meanwhile
			// (an apply may yield) a refresh from serving still leaves its empty row alone
			scope (exit)
			{
				auto d = db.prepare("DELETE FROM meta_arrived WHERE hash = ?");
				d.bind(1, h);
				d.run();
			}
			// every fact about this photo (a deletion or a removal is not re-applied: the
			// mirror never brings such a photo, and a file the user put back by hand is theirs)
			// (kw/face keys start with the hash: a key RANGE, which the primary key serves — a
			// case-insensitive LIKE scanned all of meta_state for every photo that arrived)
			auto s = db.prepare("SELECT kind, key, value, hlc, seq FROM meta_state WHERE kind IN ('fav', 'kind') AND key = ?"
				~ " UNION ALL SELECT kind, key, value, hlc, seq FROM meta_state WHERE kind IN ('kw', 'face') AND key >= ? AND key < ?"
				~ " UNION ALL SELECT kind, key, value, hlc, seq FROM meta_state WHERE kind = 'ap' AND key LIKE '%|' || ?");
			s.bind(1, h).bind(2, h ~ "|").bind(3, h ~ "}").bind(4, h);
			MetaRow[] facts, faceRows;
			while (s.step())
				facts ~= MetaRow(s.getString(0), s.getString(1), s.getString(2), s.getString(3), s.getLong(4));
			PullResult ignored;
			foreach (row; facts)
			{
				// what was taken OFF counts too (a keyword the file still carries, re-read at
				// the re-import, must not come back); an unnamed face says nothing
				if (row.kind == "face")
				{
					if (row.value.length)
						faceRows ~= row;
					continue;
				}
				applyOrWait(row, ignored, /*replay*/ true);
			}
			// this photo's names together, before its marker goes (settled once, at the end)
			applyFaces(faceRows, ignored, /*replay*/ true, /*take*/ false);
			faces = faces || faceRows.length > 0;
		}
		return cast(long) arrived.length;
	}

	/// The facts as the library holds them now; whatever differs from meta_state becomes a
	/// local change. Keys with a fact from another computer still waiting (meta_pending) are
	/// left alone: that is not the user undoing it here. Returns how many changed.
	long refresh(bool replay = true)
	{
		if (replay)
			reapplyArrivals();
		// nothing it replicates changed here and nothing was taken from a peer since the last
		// scan: the answer is the same — no scan (it read every face, keyword and album; per
		// served page and per pull that was O(library) of garbage each time)
		immutable dirty = dirtyCount();
		if (dirty >= 0 && dirty == seenDirty && !hasArrivals())
			return 0;
		// read AFTER the scan: its own records bump the counter too (meta_state has triggers)
		scope (success)
			seenDirty = dirtyCount();
		// photos just made whose facts were not applied again yet (serving does not replay):
		// their empty rows say nothing
		auto fresh = set("SELECT hash FROM meta_arrived");
		return db.transaction!long({
			long n;
			bool rec(string kind, string key, string value)
			{
				if (kind != "del" && kind != "rm" && (hashOfKey(kind, key) in fresh) !is null)
					return false;
				if (store.record(kind, key, value))
				{
					n++;
					return true;
				}
				return false;
			}

			auto present = set("SELECT hash FROM photos WHERE path IS NOT NULL");

			// del / rm: a set each; a key that left the set was undone here
			foreach (kind, sql; ["del": "SELECT hash FROM declined_hashes", "rm": "SELECT hash FROM removed_hashes"])
			{
				auto now = set(sql);
				auto waiting = store.pendingKeys(kind);
				foreach (h, _; now)
					rec(kind, h, "1");
				foreach (h, v; store.all(kind))
					if (v == "1" && (h in now) is null && (h in waiting) is null)
						rec(kind, h, "0");
			}

			// fav: only photos that are here say anything about it
			{
				auto now = set("SELECT hash FROM photos WHERE favorite = 1 AND path IS NOT NULL");
				auto waiting = store.pendingKeys("fav");
				foreach (h, _; now)
					rec("fav", h, "1");
				foreach (h, v; store.all("fav"))
					if (v == "1" && (h in now) is null && (h in present) !is null && (h in waiting) is null)
						rec("fav", h, "0");
			}

			// kw: each keyword on each photo
			{
				bool[string] kw;   // hash|keyword
				auto s = db.prepare("SELECT p.hash, k.keyword FROM photo_keywords k JOIN photos p ON p.id = k.photo_id WHERE p.path IS NOT NULL");
				while (s.step())
					kw[s.getString(0) ~ "|" ~ s.getString(1)] = true;
				auto waiting = store.pendingKeys("kw");
				foreach (k, _; kw)
					if ((k in waiting) is null)
						rec("kw", k, "1");
				foreach (k, v; store.all("kw"))
				{
					if (v != "1" || (k in kw) !is null || (k in waiting) !is null)
						continue;
					immutable bar = indexOfBar(k);
					// taken off here: the photo is here without it
					if (bar > 0 && (k[0 .. bar] in present) !is null)
						rec("kw", k, "0");
				}
			}

			// kind: set by hand (never un-set: the automatic kind is each computer's own)
			{
				auto waiting = store.pendingKeys("kind");
				auto s = db.prepare("SELECT hash, kind FROM photos WHERE kind_by = 'user' AND path IS NOT NULL AND kind IS NOT NULL");
				while (s.step())
					if ((s.getString(0) in waiting) is null)
						rec("kind", s.getString(0), s.getString(1));
			}

			// albums (our own — not an album another person shared with us) and their photos
			{
				string[string] albums;   // uid → name
				auto s = db.prepare("SELECT uid, name FROM albums WHERE origin_peer IS NULL AND uid IS NOT NULL");
				while (s.step())
					albums[s.getString(0)] = s.getString(1);
				foreach (uid, name; albums)
					rec("album", uid, JSONValue(["name": JSONValue(name)]).toString());
				foreach (uid, v; store.all("album"))
					if (v.length && (uid in albums) is null)
						rec("album", uid, "");

				bool[string] members;   // uid|hash
				auto m = db.prepare("SELECT a.uid, p.hash FROM album_photos ap JOIN albums a ON a.id = ap.album_id JOIN photos p ON p.id = ap.photo_id WHERE a.origin_peer IS NULL AND a.uid IS NOT NULL");
				while (m.step())
					members[m.getString(0) ~ "|" ~ m.getString(1)] = true;
				auto waiting = store.pendingKeys("ap");
				foreach (k, _; members)
					rec("ap", k, "1");
				foreach (k, v; store.all("ap"))
				{
					if (v != "1" || (k in members) !is null || (k in waiting) !is null)
						continue;
					auto parts = k.split('|');
					// taken out here: the album and the photo are both here and it is not in it
					if (parts.length == 2 && (parts[0] in albums) !is null && (parts[1] in present) !is null)
						rec("ap", k, "0");
				}
			}

			// face names, per face (see the module comment)
			{
				string[string] named;   // hash|box → name ("" unnamed)
				auto s = db.prepare("SELECT p.hash, f.x, f.y, f.w, f.h, pe.name FROM faces f JOIN photos p ON p.id = f.photo_id LEFT JOIN persons pe ON pe.id = f.person_id WHERE p.path IS NOT NULL");
				while (s.step())
					named[faceKey(s.getString(0), s.getDouble(1), s.getDouble(2), s.getDouble(3), s.getDouble(4))] =
						s.isNull(5) ? "" : s.getString(5);
				auto waiting = store.pendingKeys("face");
				auto known = store.all("face");
				foreach (k, name; named)
				{
					if ((k in waiting) !is null)
						continue;
					// an unnamed face says nothing until it had a name here (then: unnamed now)
					if (name.length || ((k in known) !is null && known[k].length))
						rec("face", k, name);
				}
			}
			return n;
		});
	}

	private long dirtyCount()
	{
		try
		{
			auto s = db.prepare("SELECT n FROM meta_dirty WHERE id = 1");
			return s.step() ? s.getLong(0) : -1;
		}
		catch (Exception)
			return -1;   // no counter (an older schema in a test): always scan
	}

	private bool hasArrivals()
	{
		auto s = db.prepare("SELECT 1 FROM meta_arrived LIMIT 1");
		return s.step();
	}

	// the photo a key is about
	private static string hashOfKey(string kind, string key)
	{
		if (kind == "ap")
		{
			immutable b = indexOfBar(key);
			return b >= 0 ? key[b + 1 .. $] : key;
		}
		if (kind == "kw" || kind == "face")
		{
			immutable b = indexOfBar(key);
			return b >= 0 ? key[0 .. b] : key;
		}
		return key;
	}

	// the first '|' (a hash has none; a keyword may)
	private static ptrdiff_t indexOfBar(string k) pure @safe nothrow
	{
		foreach (i, c; k)
			if (c == '|')
				return cast(ptrdiff_t) i;
		return -1;
	}

	/// hash|x|y|w|h with the box to 3 decimals.
	static string faceKey(string hash, double x, double y, double w, double h)
	{
		return format("%s|%.3f|%.3f|%.3f|%.3f", hash, x, y, w, h);
	}

	// ---- serving --------------------------------------------------------------------------

	/// meta.since {after} → {items: [{k, key, v, h, s}], next}: our facts after that sequence.
	JSONValue serve(JSONValue p)
	{
		refresh(/*replay*/ false);
		long after;
		if (p.type == JSONType.object)
			if (auto a = "after" in p)
				if (a.type == JSONType.integer)
					after = a.integer;
		auto rows = store.since(after, pageLimit);
		JSONValue[] items;
		foreach (r; rows)
			items ~= JSONValue(["k": JSONValue(r.kind), "key": JSONValue(r.key), "v": JSONValue(r.value),
				"h": JSONValue(r.hlc), "s": JSONValue(r.seq)]);
		return JSONValue(["items": JSONValue(items), "next": JSONValue(rows.length == pageLimit ? rows[$ - 1].seq : 0),
			"epoch": JSONValue(store.epoch())]);
	}

	// ---- pulling --------------------------------------------------------------------------

	/// Page through what `peer` has after our cursor and take what is newer. `call` asks the
	/// other computer (its result, or throws).
	PullResult pull(string peer, JSONValue delegate(string method, JSONValue params) call)
	{
		applying.lock();
		scope (exit)
			applying.unlock();
		// ours first: a change the user just made here must be stamped before theirs is weighed
		refresh();
		MetaRow[] got;
		string peerEpoch = store.lastEpoch(peer);
		long cursor = store.cursor(peer, peerEpoch), last = cursor;
		for (;;)
		{
			auto res = call("meta.since", JSONValue(["after": JSONValue(last)]));
			if (res.type != JSONType.object || "items" !in res || res["items"].type != JSONType.array)
				throw new Exception("meta.since: bad answer");
			immutable ep = "epoch" in res && res["epoch"].type == JSONType.string ? res["epoch"].str : "";
			if (ep != peerEpoch)
			{
				// another sequence space (its organization was reset, or the first time): all of it
				peerEpoch = ep;
				if (last != 0)
				{
					got = null;
					cursor = last = 0;
					continue;
				}
			}
			foreach (it; res["items"].array)
			{
				if (it.type != JSONType.object)
					continue;
				MetaRow r;
				try
				{
					r = MetaRow(it["k"].str, it["key"].str, it["v"].str, it["h"].str, it["s"].integer);
				}
				catch (Exception)
					continue;
				if (r.seq > last)
					last = r.seq;
				if (known(r.kind))
					got ~= r;
			}
			immutable next = "next" in res && res["next"].type == JSONType.integer ? res["next"].integer : 0;
			if (next == 0)
				break;
			if (next <= cursor)
				throw new Exception("meta.since: the cursor did not move");
			cursor = next;
		}
		// the user may have changed something while we waited for the network: stamp it first,
		// so a fact from there does not overwrite an edit made here meanwhile
		refresh();
		auto result = takeAll(peer, got);
		store.setCursor(peer, last, peerEpoch);
		result.pending = retryPending();
		if (result.applied)
			try
				events.emit("library.changed", JSONValue.emptyObject);
			catch (Exception)
			{
			}
		return result;
	}

	private static bool known(string kind)
	{
		switch (kind)
		{
		case "del", "rm", "fav", "kw", "kind", "album", "ap", "face":
			return true;
		default:
			return false;   // a newer computer's kind: skipped (its cursor still moves)
		}
	}

	private static int order(string kind)
	{
		switch (kind)
		{
		case "album": return 0;   // an album before what goes in it
		case "del": return 1;
		case "rm": return 2;
		default: return 3;
		}
	}

	// the newer facts, applied — mass deletions held
	private PullResult takeAll(string peer, MetaRow[] got)
	{
		import std.algorithm : sort;

		PullResult r;
		// the newest fact per key only (a page may carry a key once; several pages, several)
		MetaRow[string] latest;
		foreach (row; got)
		{
			immutable k = row.kind ~ "\x00" ~ row.key;
			if (auto p = k in latest)
			{
				if (row.hlc > p.hlc)
					*p = row;
			}
			else
				latest[k] = row;
		}
		MetaRow[] rows;
		foreach (_, row; latest)
			if (store.isNewer(row))
				rows ~= row;
		rows.sort!((a, b) => order(a.kind) < order(b.kind) || (order(a.kind) == order(b.kind) && a.hlc < b.hlc));

		// the guard: deletions that would move files here to the Trash
		MetaRow[] trashing;
		// deletions the user kept here, or the same deletion (or an older one) already waiting
		// for the user: not taken. A NEWER fact goes on (an undo clears the wait; a new
		// deletion is weighed again)
		bool[string] skip;
		foreach (row; rows)
			if (row.kind == "del" && row.value == "1"
				&& (store.isKept(row.key, row.hlc) || (store.heldHlc(row.key).length && row.hlc <= store.heldHlc(row.key))))
				skip[row.key] = true;
		foreach (row; rows)
			if (row.kind == "del" && row.value == "1" && (row.key in skip) is null && photos.hasLocalFile(row.key))
				trashing ~= row;
		immutable library = photoCount();
		immutable mass = trashing.length > massDeletionCount
			|| (library > 0 && trashing.length > massDeletionFraction * library);
		bool[string] heldNow;
		if (mass)
		{
			foreach (row; trashing)
			{
				store.hold(peer, row.key, row.hlc);
				heldNow[row.key] = true;
			}
			r.held = trashing.length;
			logWarn("meta: %s in-app deletion(s) from %s… held for the user (a mass deletion)", trashing.length, peer.length > 12 ? peer[0 .. 12] : peer);
		}
		// one change notice for the whole batch, and the face names applied together
		events.hold();
		scope (exit)
			events.release();
		MetaRow[] faceRows;
		foreach (row; rows)
		{
			if (row.kind == "del" && ((row.key in heldNow) !is null || (row.key in skip) !is null))
				continue;   // not taken: nothing here says it was deleted, until the user agrees
			if (row.kind == "face")
			{
				faceRows ~= row;   // taken with its apply, in the batch's transaction
				continue;
			}
			if (!store.take(row))
				continue;
			r.taken++;
			if (row.kind == "del")
				store.unhold(row.key);   // a newer fact about it: an older held deletion is moot
			applyOrWait(row, r);
		}
		applyFaces(faceRows, r, false, /*take*/ true);
		if (faceRows.length)
			settle();
		return r;
	}

	private void applyOrWait(ref const MetaRow row, ref PullResult r, bool replay = false)
	{
		// in flight until done: an apply may yield (hashing a file…), and a refresh meanwhile
		// must not read the not-yet-applied fact as the user undoing it here
		store.addPending(row.kind, row.key);
		bool done;
		try
			done = apply(row, replay);
		catch (Exception e)
		{
			logWarn("meta: %s %s: %s", row.kind, row.key, e.msg);
			done = false;
		}
		if (done)
		{
			r.applied++;
			store.dropPending(row.kind, row.key);
		}
	}

	/// A batch of face names in one transaction (`take`: accepting each fact too, so none is
	/// taken without its apply or its pending marker). The caller settles (see nameFace).
	private void applyFaces(MetaRow[] rows, ref PullResult r, bool replay, bool take)
	{
		if (!rows.length)
			return;
		db.transaction!void({
			foreach (ref row; rows)
			{
				if (take)
				{
					if (!store.take(row))
						continue;
					r.taken++;
				}
				applyOrWait(row, r, replay);
			}
		});
	}

	private void settle()
	{
		if (settleFaces !is null)
			try
				settleFaces();
			catch (Exception e)
				logWarn("meta: settling faces: %s", e.msg);
	}

	/// Facts whose photo was not here: try them again. Returns how many still wait.
	long retryPending()
	{
		events.hold();
		scope (exit)
			events.release();
		long left;
		bool faces;
		void one(ref MetaRow row)
		{
			bool done;
			try
				done = apply(row);
			catch (Exception)
				done = false;
			if (done)
			{
				store.dropPending(row.kind, row.key);
				faces = faces || row.kind == "face";
			}
			else
				left++;
		}
		MetaRow[] faceRows;
		foreach (row; store.pending())
			if (row.kind == "face")
				faceRows ~= row;
			else
				one(row);   // (not in a transaction: a deletion moves a file and may yield)
		if (faceRows.length)
			db.transaction!void({
				foreach (ref row; faceRows)
					one(row);
			});
		if (faces)
			settle();
		return left;
	}

	private long photoCount()
	{
		auto s = db.prepare("SELECT count(*) FROM photos WHERE path IS NOT NULL");
		s.step();
		return s.getLong(0);
	}

	// ---- held deletions -------------------------------------------------------------------

	long heldCount(string peer)
	{
		return store.heldCount(peer);
	}

	/// The user decided about the deletions held from `peer`: apply them (each still only if
	/// nothing newer came since) or keep the photos here. Returns how many were applied.
	long resolveHeld(string peer, bool apply_)
	{
		applying.lock();
		scope (exit)
			applying.unlock();
		long n;
		events.hold();
		scope (exit)
			events.release();
		if (apply_)
			foreach (row; store.held(peer))
			{
				if (!store.take(row))
					continue;
				PullResult r;
				applyOrWait(row, r);
				n += r.applied;
			}
		else
			foreach (row; store.held(peer))
				store.keep(row.key, row.hlc);   // the same deletion, relayed later, is not applied either
		store.clearHeld(peer);
		if (n)
			try
				events.emit("library.changed", JSONValue.emptyObject);
			catch (Exception)
			{
			}
		logInfo("meta: deletions held from %s… %s (%s applied)", peer.length > 12 ? peer[0 .. 12] : peer,
			apply_ ? "applied" : "kept", n);
		return n;
	}

	// ---- applying one fact here -----------------------------------------------------------

	private JSONValue call(string method, JSONValue params)
	{
		return registry.find(method)(params);
	}

	private long idOf(string hash)
	{
		auto s = db.prepare("SELECT id FROM photos WHERE hash = ? AND path IS NOT NULL");
		s.bind(1, hash);
		return s.step() ? s.getLong(0) : 0;
	}

	private long albumOf(string uid)
	{
		auto s = db.prepare("SELECT id FROM albums WHERE uid = ?");
		s.bind(1, uid);
		return s.step() ? s.getLong(0) : 0;
	}

	/// Do what the fact says. False: it cannot be done yet (its photo, album or face is not
	/// here) — it waits in meta_pending.
	bool apply(ref const MetaRow row, bool replay = false)
	{
		final switch (kindOf(row.kind))
		{
		case K.del:
			if (row.value == "1")
			{
				immutable id = idOf(row.key);
				if (id)
				{
					// to the Trash, and declined; a file the Trash refused stays and is tried again
					auto res = call("photo.delete", JSONValue(["ids": JSONValue([JSONValue(id)])]));
					if (res.type == JSONType.object && "failed" in res && res["failed"].type == JSONType.array
						&& res["failed"].array.length)
						return false;
				}
				else
					photos.decline(row.key);   // not here: never to be mirrored in
			}
			else
				photos.undecline(row.key);     // undone there: welcome again (the mirror brings it)
			return true;
		case K.rm:
			if (row.value == "1")
			{
				immutable id = idOf(row.key);
				if (id)
					call("photo.removeFromWagon", JSONValue(["ids": JSONValue([JSONValue(id)])]));
				else
					photos.quarantineAbsent(row.key);   // not here: out all the same (never mirrored in)
			}
			else if (photos.isRemoved(row.key))
				call("photo.restoreToWagon", JSONValue(["hashes": JSONValue([JSONValue(row.key)])]));
			return true;
		case K.fav:
		{
			immutable id = idOf(row.key);
			if (!id)
				return false;
			// replaying onto a photo that just came back: a star the user put on it since stays
			if (replay && row.value != "1" && photos.get(id).favorite)
				return true;
			call("photo.favorite", JSONValue(["id": JSONValue(id), "on": JSONValue(row.value == "1")]));
			return true;
		}
		case K.kw:
		{
			immutable bar = indexOfBar(row.key);
			if (bar <= 0 || bar + 1 >= row.key.length)
				return true;   // malformed: nothing to wait for
			immutable id = idOf(row.key[0 .. bar]);
			if (!id)
				return false;
			immutable word = row.key[bar + 1 .. $];
			if (keywords !is null)
			{
				if (row.value == "1")
					keywords.add([id], [word], /*fromUser*/ false);
				else
					keywords.remove([id], word, false);
			}
			else if (row.value == "1")
				call("photo.addKeywords", JSONValue(["ids": JSONValue([JSONValue(id)]), "keywords": JSONValue([JSONValue(word)])]));
			else
				call("photo.removeKeyword", JSONValue(["ids": JSONValue([JSONValue(id)]), "keyword": JSONValue(word)]));
			return true;
		}
		case K.kind:
		{
			immutable id = idOf(row.key);
			if (!id)
				return false;
			if (replay && photos.get(id).kindBy == "user")
				return true;   // set by hand since it came back: the user's
			call("photo.setKind", JSONValue(["id": JSONValue(id), "kind": JSONValue(row.value)]));
			return true;
		}
		case K.album:
		{
			immutable id = albumOf(row.key);
			if (!row.value.length)
			{
				if (id)
					call("album.delete", JSONValue(["id": JSONValue(id)]));
				return true;
			}
			immutable name = parseJSON(row.value)["name"].str;
			if (!id)
			{
				immutable nid = call("album.create", JSONValue(["name": JSONValue(name)]))["id"].integer;
				auto u = db.prepare("UPDATE albums SET uid = ? WHERE id = ?");
				u.bind(1, row.key).bind(2, nid);
				u.run();
			}
			else
				call("album.rename", JSONValue(["id": JSONValue(id), "name": JSONValue(name)]));
			return true;
		}
		case K.ap:
		{
			auto parts = row.key.split('|');
			if (parts.length != 2)
				return true;   // malformed: nothing to wait for
			immutable aid = albumOf(parts[0]);
			if (!aid)
				return row.value != "1";   // no such album here (deleted): nothing to take out
			immutable pid = idOf(parts[1]);
			if (!pid)
				return row.value != "1";
			call(row.value == "1" ? "album.addPhotos" : "album.removePhotos",
				JSONValue(["id": JSONValue(aid), "photoIds": JSONValue([JSONValue(pid)])]));
			return true;
		}
		case K.face:
			return applyFace(row, replay);
		case K.unknown:
			return true;
		}
	}

	private enum K { del, rm, fav, kw, kind, album, ap, face, unknown }

	private static K kindOf(string k)
	{
		switch (k)
		{
		case "del": return K.del;
		case "rm": return K.rm;
		case "fav": return K.fav;
		case "kw": return K.kw;
		case "kind": return K.kind;
		case "album": return K.album;
		case "ap": return K.ap;
		case "face": return K.face;
		default: return K.unknown;
		}
	}

	// the face on that photo that overlaps the box the most (IoU ≥ 0.4) is named
	private bool applyFace(ref const MetaRow row, bool replay)
	{
		auto parts = row.key.split('|');
		if (parts.length != 5)
			return true;
		immutable pid = idOf(parts[0]);
		if (!pid)
			return false;   // the photo is not here yet
		double[4] box;
		try
			foreach (i; 0 .. 4)
				box[i] = parts[i + 1].to!double;
		catch (Exception)
			return true;
		long best;
		double bestIou = 0.4;
		string bestName;
		bool bestNamed;
		auto s = db.prepare("SELECT f.id, f.x, f.y, f.w, f.h, pe.name FROM faces f LEFT JOIN persons pe ON pe.id = f.person_id WHERE f.photo_id = ?");
		s.bind(1, pid);
		while (s.step())
		{
			immutable iou = overlap(box, [s.getDouble(1), s.getDouble(2), s.getDouble(3), s.getDouble(4)]);
			if (iou >= bestIou)
			{
				bestIou = iou;
				best = s.getLong(0);
				bestNamed = !s.isNull(5);
				bestName = bestNamed ? s.getString(5) : null;
			}
		}
		if (!best)
			return false;   // its faces were not found here yet
		if (replay && bestNamed)
			return true;    // named here since it came back: the user's
		if (!row.value.length)
		{
			// the name was taken off that face there: off here too (an unnamed face stays so)
			if (bestNamed)
			{
				if (nameFace !is null)
					nameFace(best, "");
				else
					call("face.setPerson", JSONValue(["faceId": JSONValue(best), "personId": JSONValue(0L)]));
			}
			return true;
		}
		if (bestNamed && bestName == row.value)
			return true;
		// directly: no look-alike "following" (see FaceService.nameFaceFromPeer)
		if (nameFace !is null)
			nameFace(best, row.value);
		else
			call("face.setPerson", JSONValue(["faceId": JSONValue(best), "name": JSONValue(row.value)]));
		return true;
	}

	/// Intersection over union of two x,y,w,h boxes.
	static double overlap(double[4] a, double[4] b) pure @safe nothrow
	{
		import std.algorithm.comparison : max, min;

		immutable ix = max(0.0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]));
		immutable iy = max(0.0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]));
		immutable inter = ix * iy;
		immutable uni = a[2] * a[3] + b[2] * b[3] - inter;
		return uni > 0 ? inter / uni : 0;
	}
}

unittest
{
	// the clock: text order is time order; a stamp seen from elsewhere pushes ours past it
	import photowagon.core.db.schema : migrate;

	assert(hlcText(5, 1, "aa") < hlcText(5, 2, "aa"));
	assert(hlcText(5, 9, "aa") < hlcText(6, 0, "aa"));
	assert(hlcText(5, 1, "aa") < hlcText(5, 1, "bb"));
	assert(hlcParts(hlcText(123, 4, "n")) == [123L, 4L]);

	auto db = new Database(":memory:");
	migrate(db);
	auto a = new MetaStore(db, () nothrow => "aaaaaaaaaaaaaaaa");
	immutable t1 = a.next();
	immutable t2 = a.next();
	assert(t1 < t2);
	immutable far = hlcText(hlcParts(t2)[0] + 1_000_000, 7, "zz");
	a.observe(far);
	assert(a.next() > far);

	// last writer wins, idempotent, no echo
	assert(a.record("fav", "h1", "1"));
	assert(!a.record("fav", "h1", "1"));   // same value: nothing new
	MetaRow mine;
	assert(a.get("fav", "h1", mine));
	auto older = MetaRow("fav", "h1", "0", hlcText(1, 0, "bb"), 1);
	assert(!a.take(older));                // older than ours: ignored
	auto newer = MetaRow("fav", "h1", "0", hlcText(hlcParts(mine.hlc)[0] + 1, 0, "bb"), 1);
	assert(a.take(newer));
	assert(!a.take(newer));                // the same fact again (an echo): nothing
	MetaRow now;
	a.get("fav", "h1", now);
	assert(now.value == "0" && now.hlc == newer.hlc);
	// served in sequence order, and the taken fact is served on (A→B→C)
	auto rows = a.since(0, 100);
	assert(rows.length == 1 && rows[0].hlc == newer.hlc);
	assert(a.since(rows[0].seq, 100).length == 0);

	// held deletions
	a.hold("peer", "hx", hlcText(9, 0, "bb"));
	assert(a.heldCount("peer") == 1 && a.held("peer")[0].key == "hx");
	a.clearHeld("peer");
	assert(a.heldCount("peer") == 0);

	assert(MetaSync.overlap([0.1, 0.1, 0.2, 0.2], [0.1, 0.1, 0.2, 0.2]) > 0.99);
	assert(MetaSync.overlap([0.1, 0.1, 0.2, 0.2], [0.5, 0.5, 0.2, 0.2]) == 0);
	assert(MetaSync.faceKey("h", 0.1234, 0.5, 0.25, 0.3) == "h|0.123|0.500|0.250|0.300");
}

unittest
{
	// the guard, taking and applying, idempotence and no echo — against a library in memory
	// and stand-ins for the methods the facts call
	import photowagon.core.db.schema : migrate;
	import photowagon.core.library.photos : Photo;
	import photowagon.core.store.store : ContentStore;
	import std.file : tempDir;
	import std.path : buildPath;

	auto db = new Database(":memory:");
	migrate(db);
	auto repo = new PhotoRepo(db, new ContentStore(buildPath(tempDir, "pw-meta-ut-store")));
	foreach (i; 0 .. 10)
	{
		Photo p = {hash: "h" ~ i.to!string, path: "/p/" ~ i.to!string ~ ".jpg", takenAt: "x"};
		repo.insert(p);
	}
	auto reg = new Registry;
	long[] trashed;
	reg.add("photo.delete", (JSONValue p) {
		foreach (v; p["ids"].array)
		{
			auto ph = repo.get(v.integer);
			repo.decline(ph.hash);
			repo.remove(v.integer);
			trashed ~= v.integer;
		}
		return JSONValue.emptyObject;
	});
	reg.add("photo.favorite", (JSONValue p) {
		repo.setFavorite(p["id"].integer, p["on"].type == JSONType.true_);
		return JSONValue.emptyObject;
	});
	auto sync = new MetaSync(db, () nothrow => "bbbbbbbbbbbbbbbb", repo, reg, new Events);
	sync.massDeletionCount = 3;
	sync.massDeletionFraction = 1.0;

	// the other computer's facts, served by sequence like meta.since
	JSONValue[] theirs;
	long seq;
	void fact(string k, string key, string v, long wall)
	{
		theirs ~= JSONValue(["k": JSONValue(k), "key": JSONValue(key), "v": JSONValue(v),
			"h": JSONValue(hlcText(wall, 0, "aaaaaaaaaaaaaaaa")), "s": JSONValue(++seq)]);
	}
	JSONValue remote(string method, JSONValue p)
	{
		JSONValue[] out_;
		foreach (it; theirs)
			if (it["s"].integer > p["after"].integer)
				out_ ~= it;
		return JSONValue(["items": JSONValue(out_), "next": JSONValue(0)]);
	}
	immutable later = 9_000_000_000_000;   // far after this run's own stamps
	foreach (i; 0 .. 5)
		fact("del", "h" ~ i.to!string, "1", later + i);
	fact("fav", "h7", "1", later + 10);
	fact("del", "gone", "1", later + 11);   // a photo not here: declined, nothing to trash

	// five deletions at once, over the (test) limit of three: held, nothing trashed; the rest applied
	auto r = sync.pull("peer", &remote);
	assert(r.held == 5 && trashed.length == 0, r.to!string);
	assert(repo.byHash("h7").get.favorite && repo.isDeclined("gone"));
	assert(sync.heldCount("peer") == 5);
	// nothing is asked again (the cursor moved), and nothing here claims they were deleted
	r = sync.pull("peer", &remote);
	assert(r.held == 0 && r.taken == 0 && sync.heldCount("peer") == 5);
	MetaRow row;
	assert(!sync.metaStore.get("del", "h0", row));
	// the user applies them: to the Trash, declined, and taken with THEIR stamp — no echo
	assert(sync.resolveHeld("peer", true) == 5 && trashed.length == 5 && sync.heldCount("peer") == 0);
	assert(sync.metaStore.get("del", "h0", row) && row.hlc == hlcText(later, 0, "aaaaaaaaaaaaaaaa"));
	assert(sync.refresh() == 0);

	// a few deletions (at the limit): applied at once
	fact("del", "h5", "1", later + 20);
	fact("del", "h6", "1", later + 21);
	r = sync.pull("peer", &remote);
	assert(r.held == 0 && trashed.length == 7);

	// held, then kept: the photos stay, and nothing travels back
	foreach (i; 7 .. 10)
		fact("del", "h" ~ i.to!string, "1", later + 30 + i);
	fact("del", "h8", "1", later + 50);   // the same photo twice: counted once
	sync.massDeletionCount = 2;
	r = sync.pull("peer", &remote);
	assert(r.held == 3 && trashed.length == 7);
	assert(sync.resolveHeld("peer", false) == 0 && repo.hasLocalFile("h7") && sync.heldCount("peer") == 0);
	assert(sync.refresh() == 0);
	assert(!sync.metaStore.get("del", "h9", row));
	// the same deletions relayed by a third computer, even a few (under the limit): kept
	sync.massDeletionCount = 100;
	r = sync.pull("third", &remote);
	assert(r.held == 0 && repo.hasLocalFile("h7") && repo.hasLocalFile("h9") && trashed.length == 7);

	// removed from Wagon there while not here: out here too, and not "restored" by refresh
	fact("rm", "not-here", "1", later + 55);
	r = sync.pull("peer", &remote);
	assert(repo.isRemoved("not-here") && sync.refresh() == 0);

	// a local change is stamped and served; the other side's older fact loses to it
	repo.setFavorite(repo.byHash("h9").get.id, true);
	assert(sync.refresh() == 1);
	assert(sync.metaStore.get("fav", "h9", row) && row.value == "1");
	fact("fav", "h9", "0", 1);   // older than ours
	r = sync.pull("peer", &remote);
	assert(repo.byHash("h9").get.favorite);
	auto served = sync.serve(JSONValue(["after": JSONValue(0)]));
	bool sawFav;
	foreach (it; served["items"].array)
		if (it["k"].str == "fav" && it["key"].str == "h9")
			sawFav = true;
	assert(sawFav);

	// a fact about a photo not here yet waits, and applies when it arrives
	fact("fav", "h-late", "1", later + 60);
	r = sync.pull("peer", &remote);
	assert(r.pending == 1);
	Photo late = {hash: "h-late", path: "/p/late.jpg", takenAt: "x"};
	repo.insert(late);
	assert(sync.retryPending() == 0 && repo.byHash("h-late").get.favorite);
	assert(sync.refresh() == 0);   // not recorded again as ours

	// a photo that comes back as a new row (its file deleted outside the app and brought back)
	// gets its facts back: its empty row is not the user taking them off
	immutable oldId = repo.byHash("h9").get.id;
	repo.remove(oldId);
	Photo again = {hash: "h9", path: "/p/9-again.jpg", takenAt: "x"};
	repo.insert(again);
	assert(repo.byHash("h9").get.id != oldId && !repo.byHash("h9").get.favorite);
	assert(sync.refresh() == 0);
	assert(repo.byHash("h9").get.favorite);
	assert(sync.metaStore.get("fav", "h9", row) && row.value == "1");
}

