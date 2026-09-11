/// `tags.*`, `photo.tags` and `photo.setTag` of docs/ipc.md: scenes and moods.
module photowagon.core.api.tags_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.library.scenes : SceneService;

void registerTagsApi(Registry r, SceneService scenes)
{
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
}
