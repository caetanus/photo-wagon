/// `moments.*` methods: the timeline grouped into events, and their pages.
module photowagon.core.api.moments_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.library.moments : MomentsService;
import photowagon.core.library.photos : Filter, PhotoRepo;

void registerMomentsApi(Registry r, MomentsService moments, PhotoRepo photos)
{
	r.add("moments.list", (JSONValue p) { return moments.list(); });

	r.add("moments.page", (JSONValue p) {
		Filter f = moments.filterFor(requireString(p, "key"));
		immutable offset = getLong(p, "offset", 0);
		immutable limit = getLong(p, "limit", 100);
		return JSONValue([
			"total": JSONValue(photos.count(f)),
			"offset": JSONValue(offset),
			"items": photos.toJsonArray(photos.page(f, offset, limit < 1 ? 1 : limit)),
		]);
	});
}
