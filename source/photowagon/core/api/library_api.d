/// `library.*` and `photo.*` methods of docs/ipc.md.
module photowagon.core.api.library_api;

import std.json;

import photowagon.core.indexer.indexer : Indexer;
import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.protocol;
import photowagon.core.library.dates : DateTree;
import photowagon.core.library.photos : Filter, PhotoRepo;
import photowagon.core.library.roots : RootRepo;
import photowagon.core.library.kindjob : KindService;

void registerLibraryApi(Registry r, RootRepo roots, PhotoRepo photos, DateTree dates, Indexer indexer, Events events,
		KindService kinds = null, void delegate() scanFaces = null)
{
	r.add("library.stats", (JSONValue p) {
		JSONValue k = JSONValue.emptyObject;
		foreach (name, n; photos.kindCounts())
			k[name] = n;
		return JSONValue(["kinds": k, "total": JSONValue(photos.count(Filter.init))]);
	});

	// {id} → the pixel statistics the kind rules use (for tuning and curiosity)
	r.add("photo.stats", (JSONValue p) {
		import vibe.core.concurrency : async;
		import photowagon.core.thumbs.vips : imageStats;

		auto photo = photos.get(requireLong(p, "id"));
		if (photo.thumbHash is null)
			throw new ApiError("not_found", "no thumbnail");
		import std.file : exists;

		// the original when we have it: a re-compressed thumbnail flattens noise into plateaus
		immutable src = photo.path !is null && photo.path.exists ? photo.path : photos.thumbPath(photo.thumbHash);
		auto st = async(&imageStats, src).getResult();
		return JSONValue([
			"dominant": JSONValue(st.dominantFraction), "unique": JSONValue(st.uniqueFraction),
			"saturation": JSONValue(st.meanSaturation), "edges": JSONValue(st.edgeDensity),
			"light": JSONValue(st.lightFraction), "dark": JSONValue(st.darkFraction), "flat": JSONValue(st.flatFraction),
			"camera": JSONValue(photo.camera !is null), "width": JSONValue(photo.width), "height": JSONValue(photo.height),
			"path": JSONValue(photo.path), "kind": photo.kind is null ? JSONValue(null) : JSONValue(photo.kind),
		]);
	});

	r.add("photo.setKind", (JSONValue p) {
		if (kinds is null)
			throw new ApiError("unsupported", "kinds are not available here");
		immutable id = requireLong(p, "id");
		void nothing() {}
		kinds.setKind(id, requireString(p, "kind"), scanFaces ? scanFaces : &nothing);
		auto photo = photos.get(id);
		return photos.toJson(photo);
	});

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

	// the same filter as library.page (dates ignored): the tree of a person, an album, the favourites…
	r.add("library.dates", (JSONValue p) { return dates.build(filterOf(p)); });

	// {sha256} → {id, path}: the photo with that content, or not_found (the phone asks for
	// its own photos' faces this way)
	r.add("library.byHash", (JSONValue p) {
		immutable h = requireString(p, "sha256");
		auto have = photos.byHash(h);
		if (have.isNull)
			throw new ApiError("not_found", "no photo with that hash");
		return JSONValue(["id": JSONValue(have.get.id), "path": JSONValue(have.get.path)]);
	});

	r.add("photo.get", (JSONValue p) {
		auto photo = photos.get(requireLong(p, "id"));
		return photos.toJson(photo);
	});

	// {ids: [...], permanent?} → {deleted, failed: [{id, message}]}: the files go to the
	// desktop's trash (or away for good) and the photos leave the library
	r.add("photo.delete", (JSONValue p) {
		import std.file : exists, remove;
		import photowagon.core.library.trash : moveToTrash;

		if (p.type != JSONType.object || !("ids" in p) || p["ids"].type != JSONType.array)
			throw new ApiError("bad_params", "ids: [...] wanted");
		immutable permanent = "permanent" in p && p["permanent"].type == JSONType.true_;
		long deleted;
		JSONValue[] failed;
		foreach (v; p["ids"].array)
		{
			immutable id = v.integer;
			try
			{
				auto photo = photos.get(id);
				if (photo.path.length && photo.path.exists)
				{
					if (permanent) remove(photo.path);
					else moveToTrash(photo.path);
				}
				photos.remove(id);
				deleted++;
			}
			catch (Exception e)
				failed ~= JSONValue(["id": JSONValue(id), "message": JSONValue(e.msg)]);
		}
		if (deleted)
		{
			events.emit("library.changed", JSONValue.emptyObject);
			events.emit("people.changed", JSONValue.emptyObject);
		}
		return JSONValue(["deleted": JSONValue(deleted), "failed": JSONValue(failed)]);
	});

	r.add("photo.favorite", (JSONValue p) {
		immutable id = requireLong(p, "id");
		bool on = true;
		if (auto v = "on" in p)
			on = v.type != JSONType.false_;
		photos.setFavorite(id, on);
		events.emit("library.changed", JSONValue.emptyObject);
		return JSONValue(["id": JSONValue(id), "favorite": JSONValue(on)]);
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
	f.personId = getLong(p, "personId");
	f.kind = getString(p, "kind");
	f.text = getString(p, "q");
	f.place = getString(p, "place");
	f.country = getString(p, "country");
	foreach (g; ["scene", "mood", "weather", "holiday"])
		if (auto v = getString(p, g))
		{
			f.tagGroup = g;
			f.tag = v;
		}
	if (f.kind.length && f.kind != "photo" && f.kind != "screenshot" && f.kind != "meme")
		throw new ApiError("bad_params", "kind must be photo, screenshot or meme");
	if (p.type == JSONType.object)
		if (auto v = "favorites" in p)
			f.favorites = v.type == JSONType.true_;
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
