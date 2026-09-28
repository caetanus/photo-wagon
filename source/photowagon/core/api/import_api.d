/// `library.import` — a photo pushed to us by another device (the phone).
/// The bytes land under `<data dir>/imports/<yyyy-mm>/`, which is a root of the
/// library like any folder the user added, so the indexer does the rest.
module photowagon.core.api.import_api;

import std.base64 : Base64;
import std.file : exists, mkdirRecurse, write;
import std.json;
import std.path : buildPath, baseName, extension, stripExtension;

import vibe.core.log : logInfo, logWarn;

import photowagon.core.config : Config;
import photowagon.core.indexer.indexer : Indexer;
import photowagon.core.ipc.protocol;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.library.roots : RootRepo;
import photowagon.core.p2p.blobpush : BlobStash;
import photowagon.core.store.partials : PartialStore;
import photowagon.core.sync.pieces : PieceStore;
import photowagon.core.store.store : sha256Hex;

/// Lands a verified file into imports/ (see landFile): what another computer's mirror uses
/// for the files it pulls — `sub` is that computer's folder under imports/.
alias LandFn = JSONValue delegate(string name, string takenAt, string src, string hash, long mtimeMs, string sub);

void registerImportApi(Registry r, Config cfg, RootRepo roots, PhotoRepo photos, Indexer indexer,
	BlobStash blobs = null, PartialStore partials = null, PieceStore pieces = null,
	string delegate(long photoId, JSONValue facesJson) ingestFaces = null,
	void delegate(LandFn) exportLand = null)
{
	immutable importsRoot = buildPath(cfg.dataDir, "imports");
	{
		import photowagon.core.metadata.datefromname : importsRootForDates;

		// the same string the imported paths are built from (compared as is): its YYYY-MM
		// folders are not dates
		importsRootForDates = importsRoot;
	}

	// Indexes a file just placed in imports/ (deduped by hash already); the phone's faces
	// are stored once the photo is in the library.
	JSONValue landed(string hash, string path, JSONValue facesJson, string takenAt = null)
	{
		immutable rootId = roots.add(importsRoot);
		// The phone sent faces it detected + embedded (same r100 model; an empty array = it
		// looked and found nobody): store + cluster them instead of re-detecting here — once
		// the photo is actually in the library. Indexing is asynchronous, so a lookup right
		// after indexOne() found nothing and the faces were dropped. `ingestFaces` is null on
		// a no-vision (node) build.
		void delegate() then;
		if (ingestFaces !is null && facesJson.type == JSONType.array)
			then = () {
				auto landed = photos.byHash(hash);
				if (!landed.isNull)
					cast(void) ingestFaces(landed.get.id, facesJson);
			};
		// just this file — no re-scan of the whole imports/ folder; the phone's date of the
		// photo is the fallback for one without EXIF or a dated name (before the file time)
		indexer.indexOne(rootId, path, then, unixOf(takenAt));
		return JSONValue(["existed": JSONValue(false), "path": JSONValue(path)]);
	}

	// Writes `bytes` into imports/<yyyy-mm>/ and indexes just that file; deduped by hash, so
	// a photo already here is returned as `existed` without a second copy. Shared by the base64
	// path and the blob-pipe (ticket) path.
	JSONValue landBytes(string name, string takenAt, const(ubyte)[] bytes, JSONValue facesJson = JSONValue(null),
		long mtimeMs = 0)
	{
		immutable base = name.baseName;
		if (base.length == 0 || base[0] == '.')
			throw new ApiError("bad_params", "bad file name");
		if (bytes.length == 0)
			throw new ApiError("bad_params", "empty file");
		immutable hash = sha256Hex(bytes);
		auto known = photos.byHash(hash);
		if (!known.isNull)
			return JSONValue(["id": JSONValue(known.get.id), "existed": JSONValue(true), "path": JSONValue(known.get.path)]);
		if (photos.isRemoved(hash))   // removed from Wagon: taken as delivered, kept out
			return JSONValue(["existed": JSONValue(true), "removed": JSONValue(true)]);
		immutable month = monthFolder(takenAt);
		immutable dir = buildPath(importsRoot, month);
		mkdirRecurse(dir);
		immutable path = freePath(dir, base);
		write(path, bytes);
		keepTimes(path, mtimeMs);
		logInfo("import: %s (%s bytes)", path, bytes.length);
		return landed(hash, path, facesJson, takenAt);
	}

	// The same for a file already complete and verified on disk (the piece store, the
	// offset spool): MOVED into imports/<yyyy-mm>/, never read into memory — a phone video
	// is hundreds of MB, and holding each one whole (read + hash + write) took the desktop
	// past its memory limit while a phone pushed its videos (2026-09-25).
	JSONValue landFile(string name, string takenAt, string src, string hash, JSONValue facesJson = JSONValue(null),
		long mtimeMs = 0, string sub = null)
	{
		import std.file : rename, copy, remove, getSize;

		immutable base = name.baseName;
		if (base.length == 0 || base[0] == '.')
			throw new ApiError("bad_params", "bad file name");
		if (getSize(src) == 0)
			throw new ApiError("bad_params", "empty file");
		auto known = photos.byHash(hash);
		if (!known.isNull && known.get.path !is null)   // (a remote-only row gets this file)
		{
			try
				remove(src);
			catch (Exception)
			{
			}
			return JSONValue(["id": JSONValue(known.get.id), "existed": JSONValue(true), "path": JSONValue(known.get.path)]);
		}
		if (photos.isRemoved(hash))
		{
			// removed from Wagon: taken as delivered (the phone stops sending it), kept out
			try
				remove(src);
			catch (Exception)
			{
			}
			return JSONValue(["existed": JSONValue(true), "removed": JSONValue(true)]);
		}
		immutable month = monthFolder(takenAt);
		// a file another computer sent goes under imports/<that computer>/ (sub)
		immutable dir = sub.length ? buildPath(importsRoot, safeFolder(sub), month) : buildPath(importsRoot, month);
		mkdirRecurse(dir);
		immutable path = freePath(dir, base);
		try
			rename(src, path);   // same file system (both under the data directory)
		catch (Exception)
		{
			copy(src, path);     // streamed by the OS, not through our heap
			remove(src);
		}
		keepTimes(path, mtimeMs);
		logInfo("import: %s (%s bytes)", path, getSize(path));
		return landed(hash, path, facesJson, takenAt);
	}


	if (exportLand !is null)
		exportLand((string n, string t, string src, string h, long m, string sub) => landFile(n, t, src, h,
			JSONValue(null), m, sub));

	// {after?, limit?} → {items: [{sha256, size, name, takenAt, mtimeMs}], next}: the library's
	// local files page by page, for a paired computer mirroring this one — it pulls what it
	// lacks by sha256 over the piece protocol. `next` is the `after` of the next page, 0 at
	// the end. Files removed from Wagon are left out (they left the library).
	r.add("library.hashes", (JSONValue p) {
		long after;
		long limit = 500;
		if (p.type == JSONType.object)
		{
			if (auto a = "after" in p)
				if (a.type == JSONType.integer)
					after = a.integer;
			if (auto l = "limit" in p)
				if (l.type == JSONType.integer && l.integer > 0)
					limit = l.integer > 2000 ? 2000 : l.integer;
		}
		auto rows = photos.localFilesAfter(after, cast(int) limit);
		JSONValue[] items;
		foreach (f; rows)
		{
			if (photos.isRemoved(f.hash))
				continue;
			items ~= JSONValue(["sha256": JSONValue(f.hash), "size": JSONValue(f.size),
				"name": JSONValue(f.path.baseName), "takenAt": JSONValue(f.takenAt), "mtimeMs": JSONValue(f.mtimeMs)]);
		}
		immutable next = rows.length == limit ? rows[$ - 1].id : 0;
		return JSONValue(["items": JSONValue(items), "next": JSONValue(next)]);
	});

	// {hashes: [sha256, …]} → {have: [sha256, …], refuse: [sha256, …]}: the phone offers a
	// batch of the photos it means to send; the desktop answers which it already has and
	// which it turns away (a hash the user deleted). What is in neither list is wanted, so the
	// phone sends only those — one round trip for the whole batch instead of a probe per photo.
	r.add("library.offer", (JSONValue p) {
		if (p.type != JSONType.object || "hashes" !in p || p["hashes"].type != JSONType.array)
			throw new ApiError("bad_params", "hashes: [...] wanted");
		JSONValue[] have, refuse;
		foreach (h; p["hashes"].array)
		{
			if (h.type != JSONType.string || h.str.length != 64)
				continue;   // ignore a malformed entry rather than fail the whole batch
			if (photos.hasHash(h.str))
				have ~= h;
			else if (photos.isDeclined(h.str) || photos.isRemoved(h.str))
				refuse ~= h;   // deleted here, or removed from Wagon: not taken back
		}
		return JSONValue(["have": JSONValue(have), "refuse": JSONValue(refuse)]);
	});

	// {hashes: [sha256, …]} → {have: [sha256, …]}: which of these are really here — a file on
	// disk at its recorded size, not only a row (library.offer's `have` is the row). The phone
	// asks this before deleting its own copies ("Free up space").
	r.add("library.holds", (JSONValue p) {
		if (p.type != JSONType.object || "hashes" !in p || p["hashes"].type != JSONType.array)
			throw new ApiError("bad_params", "hashes: [...] wanted");
		JSONValue[] have;
		foreach (h; p["hashes"].array)
			if (h.type == JSONType.string && h.str.length == 64 && photos.holdsHash(h.str))
				have ~= h;
		return JSONValue(["have": JSONValue(have)]);
	});

	// {name, base64, takenAt?} → {id?, existed, path}
	// {sha256, faces} → {taken, reason?}: faces a device detected for a photo that is ALREADY here — its
	// face pass finished after the photo was sent (it yields to the sync, so that is the usual
	// order). Same contract as faces arriving with an upload: validated now (a refused batch
	// answers taken:false and the photo is scanned here instead), stored off this request.
	r.add("library.faces", (JSONValue p) {
		immutable sha = requireString(p, "sha256");
		if (ingestFaces is null)   // no vision here (the node hub): nothing to store, ever
			return JSONValue(["taken": JSONValue(false), "reason": JSONValue("no_vision")]);
		if (p.type != JSONType.object || "faces" !in p || p["faces"].type != JSONType.array)
			throw new ApiError("bad_params", "faces must be an array");
		auto ph = photos.byHash(sha);
		if (ph.isNull)
			throw new ApiError("not_found", "no photo with that sha256 here");
		immutable why = ingestFaces(ph.get.id, p["faces"]);
		return why is null ? JSONValue(["taken": JSONValue(true)])
			: JSONValue(["taken": JSONValue(false), "reason": JSONValue(why)]);
	});

	// {name, sha256, probe: true} → {existed, id?, path?}: is this file here already? (no bytes)
	r.add("library.import", (JSONValue p) {
		immutable name = requireString(p, "name").baseName;
		JSONValue facesJson = (p.type == JSONType.object && "faces" in p) ? p["faces"] : JSONValue(null);
		if (name.length == 0 || name[0] == '.')
			throw new ApiError("bad_params", "bad file name");
		if (p.type == JSONType.object && "probe" in p && p["probe"].type == JSONType.true_)
		{
			immutable h = requireString(p, "sha256");
			if (h.length != 64)
				throw new ApiError("bad_params", "sha256 must be 64 hex characters");
			auto have = photos.byHash(h);
			if (!have.isNull)
				return JSONValue(["id": JSONValue(have.get.id), "existed": JSONValue(true), "path": JSONValue(have.get.path)]);
			if (photos.isRemoved(h))   // removed from Wagon: nothing to send
				return JSONValue(["existed": JSONValue(true), "removed": JSONValue(true)]);
			// Not here yet — but part of it may be: tell the phone where to resume from, so an
			// interrupted push continues instead of restarting the whole file (`have` = bytes
			// spooled on the offset pipe; `pieces` = how many 1 MiB pieces the piece store holds).
			immutable partial = partials is null ? 0L : partials.have(h);
			immutable havePieces = pieces is null ? 0L : cast(long) pieces.have(h).haveCount;
			return JSONValue(["existed": JSONValue(false), "have": JSONValue(partial), "pieces": JSONValue(havePieces)]);
		}
		// Resumable path: the bytes were appended to the partial spool by sha256 — in slices,
		// possibly across several connections — and the phone now says the file is complete.
		// finish() verifies the whole-file hash before we land it.
		if (p.type == JSONType.object && "complete" in p && p["complete"].type == JSONType.true_)
		{
			immutable h = requireString(p, "sha256");
			string done;
			try
			{
				// the piece store first (the piece protocol), the offset spool otherwise —
				// both verify the whole file's hash in slices and hand back its path
				if (pieces !is null && pieces.complete(h))
					done = pieces.finish(h);
				else if (partials !is null)
					done = partials.finishToPath(h);
				else
					throw new ApiError("unavailable", "no partial store here");
			}
			catch (ApiError e)
				throw e;
			catch (Exception e)
				throw new ApiError("bad_blob", e.msg);
			import std.string : toLower;
			return landFile(name, getString(p, "takenAt"), done, h.toLower, facesJson, mtimeOf(p));
		}
		// Ticket path: the whole blob came over the pipe in one go (pre-resume wire).
		if (p.type == JSONType.object && "ticket" in p && p["ticket"].type == JSONType.integer)
		{
			if (blobs is null)
				throw new ApiError("unavailable", "no blob pipe here");
			auto bytes = blobs.take(p["ticket"].integer);
			if (bytes is null)
				throw new ApiError("no_blob", "no bytes arrived for this ticket");
			return landBytes(name, getString(p, "takenAt"), bytes, facesJson, mtimeOf(p));
		}
		// Fallback: base64 in the JSON (a client with no blob pipe, e.g. the LAN TCP link).
		ubyte[] bytes;
		try
			bytes = Base64.decode(requireString(p, "base64"));
		catch (Exception e)
			throw new ApiError("bad_params", "base64: " ~ e.msg);
		return landBytes(name, getString(p, "takenAt"), bytes, facesJson, mtimeOf(p));
	});
}

/// "2024-05" from an ISO timestamp, "undated" otherwise.
// The phone's own modification time on the copy (the only date a picture without EXIF
// has — a WhatsApp image, a screenshot): set before indexing, so the index and its
// size+mtime change test see the file as the phone had it. 0 = unknown, left as is.
void keepTimes(string path, long mtimeMs)
{
	import std.file : setTimes;
	import std.datetime.systime : SysTime, unixTimeToStdTime;

	// milliseconds between 1990 and 2100: anything else is a mistake (seconds sent as ms,
	// garbage) and would overflow the conversion
	if (mtimeMs < 631_152_000_000L || mtimeMs > 4_102_444_800_000L)
		return;
	try
	{
		auto t = SysTime(unixTimeToStdTime(mtimeMs / 1000) + (mtimeMs % 1000) * 10_000);
		setTimes(path, t, t);
	}
	catch (Exception e)
		logWarn("import: %s: cannot keep its time: %s", path, e.msg);
}

/// A computer's alias as a folder name under imports/: letters, digits, '-', '_', '.' kept,
/// anything else (and a leading dot) replaced; never empty, never a path.
string safeFolder(string s) pure nothrow @safe
{
	char[] o;
	foreach (char c; s)
		o ~= (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_'
			|| (c == '.' && o.length) ? c : '_';
	if (o.length > 64)
		o = o[0 .. 64];
	return o.length ? o.idup : "computer";
}

/// Unix seconds of an ISO time the phone sent ("takenAt"), 0 when absent or unreadable.
long unixOf(string iso) nothrow
{
	import std.datetime.systime : SysTime;

	if (iso.length < 10)
		return 0;
	try
	{
		immutable t = SysTime.fromISOExtString(iso).toUnixTime!long;
		return t > 0 ? t : 0;
	}
	catch (Exception)
		return 0;
}

/// The request's "mtimeMs" (the phone's file time), 0 when absent or not a number.
long mtimeOf(JSONValue p) nothrow
{
	try
		if (p.type == JSONType.object)
			if (auto v = "mtimeMs" in p)
				if (v.type == JSONType.integer || v.type == JSONType.uinteger)
					return v.integer;
	catch (Exception)
	{
	}
	return 0;
}

string monthFolder(string takenAt) pure
{
	if (takenAt.length >= 7 && takenAt[4] == '-')
		return takenAt[0 .. 7];
	return "undated";
}

/// `dir/name`, or `dir/name-2.ext`, … when taken by a different file.
string freePath(string dir, string name)
{
	import std.conv : to;

	auto path = buildPath(dir, name);
	int n = 1;
	while (path.exists)
		path = buildPath(dir, name.stripExtension ~ "-" ~ (++n).to!string ~ name.extension);
	return path;
}

unittest
{
	assert(monthFolder("2024-05-01T12:00:00Z") == "2024-05");
	assert(monthFolder("") == "undated");
	import std.file : tempDir, mkdirRecurse, write, remove;

	auto d = buildPath(tempDir, "pw-import-ut");
	mkdirRecurse(d);
	scope (exit)
	{
		import std.file : rmdirRecurse;

		rmdirRecurse(d);
	}
	write(buildPath(d, "a.jpg"), "x");
	assert(freePath(d, "a.jpg") == buildPath(d, "a-2.jpg"));
	assert(freePath(d, "b.jpg") == buildPath(d, "b.jpg"));
}

/// `library.removeImports` — the photos the phones sent (everything under `<data dir>/imports/`)
/// leave this computer, so a phone sends them again: {dryRun: true} → {count, bytes};
/// otherwise → {removed, failed}. The files go to the desktop's trash (recoverable), the rows
/// leave the library, and — unlike photo.delete — their hashes are NOT turned away (a decline
/// is lifted), so the phone's next sync is asked for them. The resumable-push spool
/// (imports/.pieces, .partial) is kept: it is keyed by sha256 and verified piece by piece, so
/// a re-send may only go faster from it; its files are not photos and are never listed.
void registerImportsCleanup(Registry r, Config cfg, PhotoRepo photos, void delegate() changed)
{
	immutable importsRoot = buildPath(cfg.dataDir, "imports");

	r.add("library.removeImports", (JSONValue p) {
		import photowagon.core.library.trash : moveToTrash;

		immutable dry = p.type == JSONType.object && "dryRun" in p && p["dryRun"].type == JSONType.true_;
		if (dry)
		{
			auto n = photos.countUnder(importsRoot);
			return JSONValue(["count": JSONValue(n[0]), "bytes": JSONValue(n[1])]);
		}
		auto res = photos.removeUnder(importsRoot, (string path) { moveToTrash(path); });
		logInfo("imports: %d photos from phones removed (%d could not go to the trash)", res[0], res[1]);
		if (res[0] && changed !is null)
			changed();
		return JSONValue(["removed": JSONValue(res[0]), "failed": JSONValue(res[1])]);
	});
}

unittest
{
	// a received file keeps the phone's modification time (ms precision); 0 leaves it alone
	import std.file : tempDir, write, remove, timeLastModified;
	import std.path : buildPath;
	import std.json : parseJSON;

	immutable f = buildPath(tempDir, "pw-keeptimes-test.jpg");
	write(f, "x");
	scope (exit)
		remove(f);
	keepTimes(f, 1_600_000_000_123);
	auto t = timeLastModified(f);
	assert(t.toUnixTime == 1_600_000_000 && t.fracSecs.total!"msecs" == 123, t.toString);
	immutable before = timeLastModified(f);
	keepTimes(f, 0);
	assert(timeLastModified(f) == before);
	assert(mtimeOf(parseJSON(`{"mtimeMs":1600000000123}`)) == 1_600_000_000_123);
	assert(mtimeOf(parseJSON(`{"name":"a"}`)) == 0);
	assert(unixOf("2020-09-13T12:26:40Z") == 1_600_000_000);
	assert(unixOf("") == 0 && unixOf("garbage-xx") == 0);
	assert(safeFolder("novigrad") == "novigrad" && safeFolder("../x y") == "_._x_y" && safeFolder("") == "computer");
}
