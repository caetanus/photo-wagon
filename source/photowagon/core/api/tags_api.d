/// `tags.*`, `photo.tags`, `photo.setTag` and `keywords.*` of docs/ipc.md: the
/// classifier tags and the user's own.
module photowagon.core.api.tags_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.library.keywords : KeywordService;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.library.scenes : SceneService;

void registerTagsApi(Registry r, SceneService scenes, KeywordService keywords = null, PhotoRepo photos = null)
{
	string[] stringsOf(JSONValue p, string key)
	{
		string[] out_;
		if (p.type == JSONType.object)
			if (auto v = key in p)
			{
				if (v.type == JSONType.array)
					foreach (x; v.array)
						if (x.type == JSONType.string)
							out_ ~= x.str;
				if (v.type == JSONType.string)
				{
					import std.array : split;
					out_ ~= v.str.split(",");
				}
			}
		return out_;
	}

	bool inline(JSONValue p)
	{
		return p.type == JSONType.object && "inline" in p && p["inline"].type == JSONType.true_;
	}

	// {inline?} → {scenes: [{tag, count, cover}], moods: […], available}
	r.add("tags.list", (JSONValue p) { return scenes.list(inline(p)); });

	// → {scenes: [names], moods: [names]}: what the user can pick
	r.add("tags.labels", (JSONValue p) { return scenes.labels(); });

	// {id} → {scene, mood, by, scores}
	r.add("photo.tags", (JSONValue p) { return scenes.photoTags(requireLong(p, "id")); });

	// {id, limit?} → {items: [Photo + similarity]}: the photos that look like this one (CLIP KNN)
	r.add("photo.similar", (JSONValue p) {
		immutable id = requireLong(p, "id");
		immutable limit = getLong(p, "limit", 60);
		JSONValue[] items;
		foreach (hit; scenes.similar(id, limit < 1 ? 1 : (limit > 500 ? 500 : limit)).array)
		{
			try
			{
				auto photo = photos.get(hit["id"].integer);
				auto j = photos.toJson(photo);
				j["similarity"] = hit["similarity"];
				items ~= j;
			}
			catch (Exception)
			{
			}
		}
		return JSONValue(["items": JSONValue(items), "total": JSONValue(items.length), "offset": JSONValue(0)]);
	});

	// {ids, group, tag}: the user's word; tag "" = nothing in particular
	r.add("photo.setTag", (JSONValue p) {
		auto ids = getLongArray(p, "ids");
		if (!ids.length && getLong(p, "id"))
			ids = [getLong(p, "id")];
		if (!ids.length)
			throw new ApiError("bad_params", "ids required");
		try
			scenes.setTag(ids, requireString(p, "group"), getString(p, "tag"));
		catch (Exception e)
			throw new ApiError("bad_params", e.msg);
		return obj();
	});

	if (keywords is null)
		return;

	// {inline?} → {keywords: [{keyword, count, cover}]}, most photos first
	r.add("keywords.list", (JSONValue p) { return keywords.list(inline(p)); });

	// {ids, keywords: [..] | "a, b"} → {}
	r.add("photo.addKeywords", (JSONValue p) {
		auto ids = getLongArray(p, "ids");
		if (!ids.length)
			throw new ApiError("bad_params", "ids required");
		keywords.add(ids, stringsOf(p, "keywords"));
		return obj();
	});

	// {ids, keyword} → {}
	r.add("photo.removeKeyword", (JSONValue p) {
		auto ids = getLongArray(p, "ids");
		if (!ids.length)
			throw new ApiError("bad_params", "ids required");
		keywords.remove(ids, requireString(p, "keyword"));
		return obj();
	});

	// {from, to} → {}: renames (merges) a keyword everywhere
	r.add("keywords.rename", (JSONValue p) {
		keywords.rename(requireString(p, "from"), requireString(p, "to"));
		return obj();
	});
}
