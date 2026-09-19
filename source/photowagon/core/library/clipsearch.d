/// Natural-language search: a text query → its CLIP text embedding (the worker runs
/// the text tower) → the nearest photos by the CLIP image embeddings already stored in
/// sqlite-vec. The tokenizer is cliptext.d; the image embeddings come from the scenes
/// pass; this joins the two so "a dog on the beach" finds the picture without any tag.
module photowagon.core.library.clipsearch;

import std.array : appender;
import std.conv : to;
import std.string : split;

import photowagon.core.db.sqlite : Database;
import photowagon.core.library.cliptext : encode;
import photowagon.core.vision.worker : visionRequest;

/// A query → its unit-length CLIP text embedding (512), in the image embeddings' space.
/// Blocking (talks to the worker); run it off the event loop, like clipEncode.
float[512] clipEncodeText(string query)
{
	auto ids = encode(query);
	auto app = appender!string;
	app.put("cliptext");
	foreach (v; ids)
	{
		app.put(' ');
		app.put(v.to!string);
	}
	auto ans = visionRequest(app.data);
	auto parts = ans.split(' ');
	if (parts.length != 512)
		throw new Exception("CLIP text worker: wrong embedding size");
	float[512] e = 0;
	foreach (i, s; parts)
		e[i] = s.to!float;
	return e;
}

/// Photo ids most similar to the text query, best first — a KNN over the CLIP image
/// embeddings in sqlite-vec. `emb` is the query embedding from clipEncodeText.
long[] nearestPhotos(Database db, const float[512] emb, long limit)
{
	auto s = db.prepare(
		"SELECT photo_id, distance FROM photo_vec WHERE embedding MATCH ? AND k = ? ORDER BY distance");
	s.bind(1, cast(const(ubyte)[]) emb[]).bind(2, limit < 1 ? 1 : limit);
	long[] out_;
	while (s.step())
		out_ ~= s.getLong(0);
	return out_;
}
