/// Bytes over the wire: `library.thumbs` and `photo.file`, for a front-end on
/// another machine that cannot open our `file://` URLs. Base64 inside JSON is
/// not elegant, but it keeps one protocol and one connection.
module photowagon.core.api.media_api;

import std.base64 : Base64;
import std.json;

import vibe.core.concurrency : async;

import photowagon.core.ipc.protocol;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.store.store : ContentStore;
import photowagon.core.thumbs.vips : renderJpeg;

/// Largest thumbnail batch one request may ask for.
enum maxThumbBatch = 200;

void registerMediaApi(Registry r, PhotoRepo photos, ContentStore store)
{
	r.add("library.thumbs", (JSONValue p) {
		auto ids = getLongArray(p, "ids");
		if (ids.length > maxThumbBatch)
			throw new ApiError("bad_params", "at most 200 ids per call");
		JSONValue thumbs = obj();
		foreach (id; ids)
		{
			import std.conv : to;

			auto photo = photos.get(id);
			if (photo.thumbHash is null || !store.has(photo.thumbHash))
				continue;
			thumbs[id.to!string] = JSONValue(cast(string) Base64.encode(store.get(photo.thumbHash)));
		}
		return JSONValue(["thumbs": thumbs]);
	});

	r.add("photo.thumb", (JSONValue p) {
		auto photo = photos.get(requireLong(p, "id"));
		if (photo.thumbHash is null || !store.has(photo.thumbHash))
			throw new ApiError("not_found", "no thumbnail");
		return JSONValue([
			"mime": JSONValue("image/jpeg"),
			"base64": JSONValue(cast(string) Base64.encode(store.get(photo.thumbHash))),
		]);
	});

	// {id, maxEdge?}: the original's bytes, or a JPEG no larger than maxEdge
	// on its longest side (rendered on a worker thread).
	r.add("photo.file", (JSONValue p) {
		import std.file : read, exists;

		auto photo = photos.get(requireLong(p, "id"));
		if (photo.path is null || !photo.path.exists)
			throw new ApiError("not_found", "the original is not on this machine");
		immutable maxEdge = cast(int) getLong(p, "maxEdge", 0);
		ubyte[] bytes;
		string mime;
		if (maxEdge > 0)
		{
			bytes = async(&renderJpeg, photo.path, maxEdge, 88).getResult();
			mime = "image/jpeg";
		}
		else
		{
			bytes = cast(ubyte[]) read(photo.path);
			mime = mimeFor(photo.path);
		}
		return JSONValue([
			"mime": JSONValue(mime),
			"size": JSONValue(bytes.length),
			"base64": JSONValue(cast(string) Base64.encode(bytes)),
		]);
	});
}

string mimeFor(string path) pure
{
	import std.path : extension;
	import std.uni : toLower;

	switch (path.extension.toLower)
	{
	case ".jpg", ".jpeg":
		return "image/jpeg";
	case ".png":
		return "image/png";
	case ".webp":
		return "image/webp";
	case ".gif":
		return "image/gif";
	case ".heic", ".heif":
		return "image/heic";
	case ".avif":
		return "image/avif";
	case ".tif", ".tiff":
		return "image/tiff";
	case ".bmp":
		return "image/bmp";
	default:
		return "application/octet-stream";
	}
}

unittest
{
	assert(mimeFor("/a/B.JPG") == "image/jpeg");
	assert(mimeFor("x.cr2") == "application/octet-stream");
}
