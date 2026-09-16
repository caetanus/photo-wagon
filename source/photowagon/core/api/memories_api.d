/// `memories.*` methods: the curated collections and their pages.
module photowagon.core.api.memories_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.library.memories : MemoriesService;
import photowagon.core.library.photos : Filter, PhotoRepo;

void registerMemoriesApi(Registry r, MemoriesService memories, PhotoRepo photos)
{
	r.add("memories.list", (JSONValue p) { return memories.list(); });

	r.add("memories.page", (JSONValue p) {
		Filter f = memories.filterFor(requireString(p, "key"));
		immutable offset = getLong(p, "offset", 0);
		immutable limit = getLong(p, "limit", 100);
		return JSONValue([
			"total": JSONValue(photos.count(f)),
			"offset": JSONValue(offset),
			"items": photos.toJsonArray(photos.page(f, offset, limit < 1 ? 1 : limit)),
		]);
	});
}
