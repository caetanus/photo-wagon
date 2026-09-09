/// `people.*`, `photo.faces`, `face.setPerson`, `faces.*` of docs/ipc.md.
module photowagon.core.api.face_api;

import std.json;

import photowagon.core.faces.repo : FaceRepo;
import photowagon.core.faces.service : FaceService;
import photowagon.core.ipc.protocol;
import photowagon.core.store.store : ContentStore;
import photowagon.core.library.calendar : fileUrl;

void registerFaceApi(Registry r, FaceRepo faces, FaceService service, ContentStore store)
{
	string url(string hash)
	{
		return hash is null ? null : fileUrl(store.pathFor(hash));
	}

	r.add("people.list", (JSONValue p) {
		JSONValue[] out_;
		foreach (person; faces.people())
			out_ ~= FaceRepo.toJson(person, url(person.coverThumb));
		return JSONValue(["people": JSONValue(out_)]);
	});

	r.add("people.rename", (JSONValue p) {
		import std.string : strip;

		service.rename(requireLong(p, "id"), requireString(p, "name").strip);
		return obj();
	});

	r.add("people.merge", (JSONValue p) {
		service.merge(requireLong(p, "id"), requireLong(p, "into"));
		return obj();
	});

	r.add("photo.faces", (JSONValue p) {
		immutable id = requireLong(p, "id");
		JSONValue[] out_;
		foreach (ref f; faces.facesOfPhoto(id))
			out_ ~= FaceRepo.toJson(f, url(f.thumbHash));
		return JSONValue(["photoId": JSONValue(id), "faces": JSONValue(out_)]);
	});

	// {faceId, personId?, name?}: an existing person, or a (new) person by name; neither = unassign
	r.add("face.setPerson", (JSONValue p) {
		import std.string : strip;

		immutable person = service.assignFace(requireLong(p, "faceId"), getLong(p, "personId"), getString(p, "name", "").strip);
		return JSONValue(["personId": person ? JSONValue(person) : JSONValue(null)]);
	});

	r.add("faces.scan", (JSONValue p) {
		if (!service.available)
			throw new ApiError("faces_off", "the face models did not load");
		service.start();
		return obj();
	});

	r.add("faces.status", (JSONValue p) {
		auto c = faces.scanCounts();
		return JSONValue([
			"available": JSONValue(service.available),
			"running": JSONValue(service.busy),
			"scanned": JSONValue(c[0]),
			"total": JSONValue(c[1]),
			"known": JSONValue(service.index.length),
		]);
	});
}
