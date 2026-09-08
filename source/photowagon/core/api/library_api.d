/// `library.*` and `photo.*` methods of docs/ipc.md.
module photowagon.core.api.library_api;

import std.json;

import photowagon.core.indexer.indexer : Indexer;
import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.protocol;
import photowagon.core.library.dates : DateTree;
import photowagon.core.library.photos : Filter, PhotoRepo;
import photowagon.core.library.roots : RootRepo;

void registerLibraryApi(Registry r, RootRepo roots, PhotoRepo photos, DateTree dates, Indexer indexer, Events events)
{
	r.add("library.roots", (JSONValue p) {
		JSONValue[] out_;
		foreach (root; roots.list())
			out_ ~= RootRepo.toJson(root);
		return JSONValue(["roots": JSONValue(out_)]);
	});

	r.add("library.addRoot", (JSONValue p) {
		import std.file : isDir, exists;
		import std.path : absolutePath, buildNormalizedPath;

		auto path = requireString(p, "path").absolutePath.buildNormalizedPath;
		if (!path.exists || !path.isDir)
			throw new ApiError("not_found", "not a directory: " ~ path);
		immutable id = roots.add(path);
		indexer.start(id, path);
		return JSONValue(["id": JSONValue(id)]);
	});

	r.add("library.removeRoot", (JSONValue p) {
		roots.remove(requireLong(p, "id"));
		events.emit("library.changed", JSONValue.emptyObject);
		return obj();
	});

	r.add("library.rescan", (JSONValue p) {
		immutable id = getLong(p, "id");
		foreach (root; roots.list())
			if (id == 0 || root.id == id)
				indexer.start(root.id, root.path);
		return obj();
	});

	r.add("library.page", (JSONValue p) {
		auto f = filterOf(p);
		immutable offset = getLong(p, "offset", 0);
		immutable limit = clamp(getLong(p, "limit", 100), 1, 1000);
		return JSONValue([
			"total": JSONValue(photos.count(f)),
			"offset": JSONValue(offset),
			"items": photos.toJsonArray(photos.page(f, offset, limit)),
		]);
	});

	r.add("library.dates", (JSONValue p) { return dates.build(getLong(p, "rootId")); });

	r.add("photo.get", (JSONValue p) {
		auto photo = photos.get(requireLong(p, "id"));
		return photos.toJson(photo);
	});

	r.add("photo.neighbours", (JSONValue p) {
		auto nb = photos.neighbours(requireLong(p, "id"), filterOf(p));
		return JSONValue([
			"prev": nb.prev ? JSONValue(nb.prev) : JSONValue(null),
			"next": nb.next ? JSONValue(nb.next) : JSONValue(null),
		]);
	});
}

Filter filterOf(JSONValue p)
{
	Filter f;
	f.rootId = getLong(p, "rootId");
	f.albumId = getLong(p, "albumId");
	f.year = cast(int) getLong(p, "year");
	f.month = cast(int) getLong(p, "month");
	f.day = cast(int) getLong(p, "day");
	if (f.year && (f.year < 1800 || f.year > 3000))
		throw new ApiError("bad_params", "year out of range");
	if (f.month < 0 || f.month > 12 || f.day < 0 || f.day > 31)
		throw new ApiError("bad_params", "month/day out of range");
	if (!f.year)
		f.month = f.day = 0;
	if (!f.month)
		f.day = 0;
	return f;
}

private long clamp(long v, long lo, long hi)
{
	return v < lo ? lo : v > hi ? hi : v;
}
