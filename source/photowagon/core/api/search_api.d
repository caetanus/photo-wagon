/// `search.combined`: free-text search that blends exact matches (file name, folder,
/// and the OCR text inside the picture) with CLIP natural-language matches ("a dog on
/// the beach" finds the photo with no tag). Exact matches first, then the nearest by
/// meaning. Falls back to the exact matches alone when the CLIP text model or the
/// vision worker is not available.
module photowagon.core.api.search_api;

import std.json;

import vibe.core.concurrency : async;
import vibe.core.log : logDiagnostic;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.protocol;
import photowagon.core.library.clipsearch : clipEncodeText, nearestPhotos;
import photowagon.core.library.photos : Filter, Photo, PhotoRepo;

void registerSearchApi(Registry r, PhotoRepo photos, Database db)
{
	r.add("search.combined", (JSONValue p) {
		immutable q = requireString(p, "q");
		immutable limit = getLong(p, "limit", 200);
		immutable cap = limit < 1 ? 1 : (limit > 500 ? 500 : limit);

		Photo[] result;
		bool[long] seen;

		// 1. exact matches — file name / folder / the text read from the picture (OCR)
		Filter tf;
		tf.text = q;
		foreach (ref ph; photos.page(tf, 0, cap))
		{
			result ~= ph;
			seen[ph.id] = true;
		}

		// 2. by meaning — the CLIP text tower, over the image embeddings in sqlite-vec.
		// Best-effort: if the model file or the worker is missing, the exact matches stand.
		try
		{
			auto emb = async(&clipEncodeText, q).getResult();
			foreach (id; nearestPhotos(db, emb, cap))
			{
				if (result.length >= cap)
					break;
				if (id in seen)
					continue;
				auto ph = photos.get(id);
				if (ph.id)
				{
					result ~= ph;
					seen[id] = true;
				}
			}
		}
		catch (Exception e)
			logDiagnostic("search: semantic off: %s", e.msg);

		return JSONValue([
			"total": JSONValue(result.length),
			"offset": JSONValue(0),
			"items": photos.toJsonArray(result),
		]);
	});
}
