/// `album.*` methods of docs/ipc.md.
module photowagon.core.api.album_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.library.albums : AlbumRepo;
import photowagon.core.library.photos : Filter, PhotoRepo;
import photowagon.core.p2p.sharing : Sharing;

/// `sharing` may be null when the node is off; `album.publish` then errors.
void registerAlbumApi(Registry r, AlbumRepo albums, PhotoRepo photos, Sharing sharing)
{
	r.add("album.list", (JSONValue p) {
		JSONValue[] out_;
		foreach (a; albums.list())
		{
			auto j = AlbumRepo.toJson(a);
			// cover = the album's first photo (by position); real thumbnail beats a letter tile
			Filter f;
			f.albumId = a.id;
			auto first = photos.page(f, 0, 1);
			if (first.length)
			{
				auto pj = photos.toJsonArray(first);
				if (pj.array.length && "thumbUrl" in pj.array[0])
					j["coverUrl"] = pj.array[0]["thumbUrl"];
			}
			out_ ~= j;
		}
		return JSONValue(["albums": JSONValue(out_)]);
	});

	r.add("album.create", (JSONValue p) {
		immutable id = albums.create(requireString(p, "name"), getLongArray(p, "photoIds"));
		return JSONValue(["id": JSONValue(id)]);
	});

	r.add("album.addPhotos", (JSONValue p) {
		albums.addPhotos(requireLong(p, "id"), getLongArray(p, "photoIds"));
		return obj();
	});

	r.add("album.rename", (JSONValue p) {
		albums.rename(requireLong(p, "id"), requireString(p, "name"));
		return obj();
	});

	r.add("album.delete", (JSONValue p) {
		albums.remove(requireLong(p, "id"));
		return obj();
	});

	r.add("album.removePhotos", (JSONValue p) {
		albums.removePhotos(requireLong(p, "id"), getLongArray(p, "photoIds"));
		return obj();
	});

	// Photos from the same calendar day as the ones being added — the "smart album"
	// suggestion (an album often is an event; the rest of that day likely belongs too).
	r.add("album.dayMates", (JSONValue p) {
		immutable limit = getLong(p, "limit", 60);
		return JSONValue([
			"items": photos.toJsonArray(photos.sameDayAs(getLongArray(p, "ids"), limit < 1 ? 1 : limit)),
		]);
	});

	r.add("album.page", (JSONValue p) {
		Filter f;
		f.albumId = requireLong(p, "id");
		albums.get(f.albumId);
		immutable offset = getLong(p, "offset", 0);
		immutable limit = getLong(p, "limit", 100);
		return JSONValue([
			"total": JSONValue(photos.count(f)),
			"offset": JSONValue(offset),
			"items": photos.toJsonArray(photos.page(f, offset, limit < 1 ? 1 : limit)),
		]);
	});

	r.add("album.publish", (JSONValue p) {
		if (sharing is null)
			throw new ApiError("p2p_off", "the node is not running (--no-p2p)");
		return JSONValue(["manifest": JSONValue(sharing.publish(requireLong(p, "id")))]);
	});
}
