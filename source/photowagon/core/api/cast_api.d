/// `cast.*` methods: throwing a photo onto a Cast screen (Chromecast / Cast TV).
module photowagon.core.api.cast_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.casting.service : CastService;

/// `svc` may be null (headless / no desktop UI); the methods then error.
void registerCastApi(Registry r, CastService svc)
{
	r.add("cast.devices", (JSONValue p) {
		if (svc is null)
			throw new ApiError("cast_off", "casting runs only with the desktop UI");
		return svc.devices();
	});

	r.add("cast.photo", (JSONValue p) {
		if (svc is null)
			throw new ApiError("cast_off", "casting runs only with the desktop UI");
		svc.castPhoto(requireString(p, "host"), cast(ushort) getLong(p, "port", 8009),
			getString(p, "kind", "chromecast"), getString(p, "control", ""), requireLong(p, "id"));
		return obj();
	});

	r.add("cast.slideshow", (JSONValue p) {
		if (svc is null)
			throw new ApiError("cast_off", "casting runs only with the desktop UI");
		svc.castSlideshow(requireString(p, "host"), cast(ushort) getLong(p, "port", 8009),
			getString(p, "kind", "chromecast"), getString(p, "control", ""),
			cast(int) getLong(p, "intervalMs", 5000));
		return obj();
	});

	r.add("cast.stop", (JSONValue p) {
		if (svc !is null)
			svc.stop();
		return obj();
	});
}
