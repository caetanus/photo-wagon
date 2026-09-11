/// `places.*` and `photo.setPlace` of docs/ipc.md.
module photowagon.core.api.places_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.library.places : PlaceService;

void registerPlacesApi(Registry r, PlaceService places)
{
	bool inline(JSONValue p)
	{
		return p.type == JSONType.object && "inline" in p && p["inline"].type == JSONType.true_;
	}

	// {inline?} → {places: [{place, country, count, cover}]}, most photos first
	r.add("places.list", (JSONValue p) { return places.list(inline(p)); });

	// {q} → {places: [{place, country, own}]}: the library's own places, then the world's cities
	r.add("places.suggest", (JSONValue p) { return places.suggest(getString(p, "q")); });

	// {ids, place, country?}: the user's word; an empty place clears
	r.add("photo.setPlace", (JSONValue p) {
		auto ids = getLongArray(p, "ids");
		if (!ids.length && getLong(p, "id"))
			ids = [getLong(p, "id")];
		if (!ids.length)
			throw new ApiError("bad_params", "ids required");
		places.setPlace(ids, getString(p, "place"), getString(p, "country"));
		return obj();
	});
}
