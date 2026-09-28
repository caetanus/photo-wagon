/// `takeout.*`: importing a Google Photos export (core/library/takeout.d).
module photowagon.core.api.takeout_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.library.takeout : TakeoutImporter;

void registerTakeoutApi(Registry r, TakeoutImporter importer)
{
	// {path} → {started}: the folder the Takeout was unpacked into (or its Google Photos folder)
	r.add("takeout.import", (JSONValue p) {
		import std.path : absolutePath, buildNormalizedPath;

		importer.start(requireString(p, "path").absolutePath.buildNormalizedPath);
		return JSONValue(["started": JSONValue(true)]);
	});
	// → {running, path, total, done, report{…}, reportFile?}
	r.add("takeout.status", (JSONValue p) => importer.status());
	r.add("takeout.cancel", (JSONValue p) {
		importer.cancel();
		return JSONValue(["cancelling": JSONValue(true)]);
	});
}
