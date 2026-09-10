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
import photowagon.core.store.store : sha256Hex;

void registerImportApi(Registry r, Config cfg, RootRepo roots, PhotoRepo photos, Indexer indexer)
{
	immutable importsRoot = buildPath(cfg.dataDir, "imports");

	// {name, base64, takenAt?} → {id?, existed, path}
	// {name, sha256, probe: true} → {existed, id?, path?}: is this file here already? (no bytes)
	r.add("library.import", (JSONValue p) {
		immutable name = requireString(p, "name").baseName;
		if (name.length == 0 || name[0] == '.')
			throw new ApiError("bad_params", "bad file name");
		if (p.type == JSONType.object && "probe" in p && p["probe"].type == JSONType.true_)
		{
			immutable h = requireString(p, "sha256");
			if (h.length != 64)
				throw new ApiError("bad_params", "sha256 must be 64 hex characters");
			auto have = photos.byHash(h);
			if (have.isNull)
				return JSONValue(["existed": JSONValue(false)]);
			return JSONValue(["id": JSONValue(have.get.id), "existed": JSONValue(true), "path": JSONValue(have.get.path)]);
		}
		ubyte[] bytes;
		try
			bytes = Base64.decode(requireString(p, "base64"));
		catch (Exception e)
			throw new ApiError("bad_params", "base64: " ~ e.msg);
		if (bytes.length == 0)
			throw new ApiError("bad_params", "empty file");

		immutable hash = sha256Hex(bytes);
		auto known = photos.byHash(hash);
		if (!known.isNull)
			return JSONValue(["id": JSONValue(known.get.id), "existed": JSONValue(true), "path": JSONValue(known.get.path)]);

		immutable month = monthFolder(getString(p, "takenAt"));
		immutable dir = buildPath(importsRoot, month);
		mkdirRecurse(dir);
		immutable path = freePath(dir, name);
		write(path, bytes);
		logInfo("import: %s (%s bytes)", path, bytes.length);

		immutable rootId = roots.add(importsRoot);
		indexer.start(rootId, importsRoot);
		return JSONValue(["existed": JSONValue(false), "path": JSONValue(path)]);
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
