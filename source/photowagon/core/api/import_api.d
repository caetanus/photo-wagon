/// `library.import` — a photo pushed to us by another device (the phone).
/// The bytes land under `<data dir>/imports/<yyyy-mm>/`, which is a root of the
/// library like any folder the user added, so the indexer does the rest.
module photowagon.core.api.import_api;

import std.base64 : Base64;
import std.file : exists, mkdirRecurse, write;
import std.json;
import std.path : buildPath, baseName, extension, stripExtension;

import vibe.core.log : logInfo;

import photowagon.core.config : Config;
import photowagon.core.indexer.indexer : Indexer;
import photowagon.core.ipc.protocol;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.library.roots : RootRepo;
import photowagon.core.p2p.blobpush : BlobStash;
import photowagon.core.store.partials : PartialStore;
import photowagon.core.sync.pieces : PieceStore;
import photowagon.core.store.store : sha256Hex;

void registerImportApi(Registry r, Config cfg, RootRepo roots, PhotoRepo photos, Indexer indexer,
	BlobStash blobs = null, PartialStore partials = null, PieceStore pieces = null,
	string delegate(long photoId, JSONValue facesJson) ingestFaces = null)
{
	immutable importsRoot = buildPath(cfg.dataDir, "imports");

	// Indexes a file just placed in imports/ (deduped by hash already); the phone's faces
	// are stored once the photo is in the library.
	JSONValue landed(string hash, string path, JSONValue facesJson)
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
		indexer.indexOne(rootId, path, then);   // just this file — no re-scan of the whole imports/ folder
		return JSONValue(["existed": JSONValue(false), "path": JSONValue(path)]);
	}

	// Writes `bytes` into imports/<yyyy-mm>/ and indexes just that file; deduped by hash, so
	// a photo already here is returned as `existed` without a second copy. Shared by the base64
	// path and the blob-pipe (ticket) path.
	JSONValue landBytes(string name, string takenAt, const(ubyte)[] bytes, JSONValue facesJson = JSONValue(null))
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
		immutable month = monthFolder(takenAt);
		immutable dir = buildPath(importsRoot, month);
		mkdirRecurse(dir);
		immutable path = freePath(dir, base);
		write(path, bytes);
		logInfo("import: %s (%s bytes)", path, bytes.length);
		return landed(hash, path, facesJson);
	}

	// The same for a file already complete and verified on disk (the piece store, the
	// offset spool): MOVED into imports/<yyyy-mm>/, never read into memory — a phone video
	// is hundreds of MB, and holding each one whole (read + hash + write) took the desktop
	// past its memory limit while a phone pushed its videos (2026-09-25).
	JSONValue landFile(string name, string takenAt, string src, string hash, JSONValue facesJson = JSONValue(null))
	{
		import std.file : rename, copy, remove, getSize;

		immutable base = name.baseName;
		if (base.length == 0 || base[0] == '.')
			throw new ApiError("bad_params", "bad file name");
		if (getSize(src) == 0)
			throw new ApiError("bad_params", "empty file");
		auto known = photos.byHash(hash);
		if (!known.isNull)
		{
			try
				remove(src);
			catch (Exception)
			{
			}
			return JSONValue(["id": JSONValue(known.get.id), "existed": JSONValue(true), "path": JSONValue(known.get.path)]);
		}
		immutable month = monthFolder(takenAt);
		immutable dir = buildPath(importsRoot, month);
		mkdirRecurse(dir);
		immutable path = freePath(dir, base);
		try
			rename(src, path);   // same file system (both under the data directory)
		catch (Exception)
		{
			copy(src, path);     // streamed by the OS, not through our heap
			remove(src);
		}
		logInfo("import: %s (%s bytes)", path, getSize(path));
		return landed(hash, path, facesJson);
	}


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
			else if (photos.isDeclined(h.str))
				refuse ~= h;
		}
		return JSONValue(["have": JSONValue(have), "refuse": JSONValue(refuse)]);
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
			return landFile(name, getString(p, "takenAt"), done, h.toLower, facesJson);
		}
		// Ticket path: the whole blob came over the pipe in one go (pre-resume wire).
		if (p.type == JSONType.object && "ticket" in p && p["ticket"].type == JSONType.integer)
		{
			if (blobs is null)
				throw new ApiError("unavailable", "no blob pipe here");
			auto bytes = blobs.take(p["ticket"].integer);
			if (bytes is null)
				throw new ApiError("no_blob", "no bytes arrived for this ticket");
			return landBytes(name, getString(p, "takenAt"), bytes, facesJson);
		}
		// Fallback: base64 in the JSON (a client with no blob pipe, e.g. the LAN TCP link).
		ubyte[] bytes;
		try
			bytes = Base64.decode(requireString(p, "base64"));
		catch (Exception e)
			throw new ApiError("bad_params", "base64: " ~ e.msg);
		return landBytes(name, getString(p, "takenAt"), bytes, facesJson);
	});
}

/// "2024-05" from an ISO timestamp, "undated" otherwise.
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
