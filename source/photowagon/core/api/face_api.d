/// `people.*`, `photo.faces`, `face.setPerson`, `faces.*` of docs/ipc.md.
module photowagon.core.api.face_api;

import std.json;

import photowagon.core.faces.repo : FaceRepo;
import photowagon.core.faces.service : FaceService;
import photowagon.core.ipc.protocol;
import photowagon.core.ipc.events : Events;
import photowagon.core.store.store : ContentStore;
import photowagon.core.library.calendar : fileUrl;

void registerFaceApi(Registry r, FaceRepo faces, FaceService service, ContentStore store, Events events)
{
	string url(string hash)
	{
		return hash is null ? null : fileUrl(store.pathFor(hash));
	}

	// {inline: true}: the crops as data: URLs, for a client (the phone) that cannot open our files
	bool inline(JSONValue p)
	{
		return p.type == JSONType.object && "inline" in p && p["inline"].type == JSONType.true_;
	}

	string dataUrl(string hash)
	{
		import std.base64 : Base64;

		if (hash is null || !store.has(hash))
			return null;
		return "data:image/jpeg;base64," ~ cast(string) Base64.encode(store.get(hash));
	}

	r.add("people.list", (JSONValue p) {
		immutable inl = inline(p);
		JSONValue[] out_;
		foreach (person; faces.people())
			out_ ~= FaceRepo.toJson(person, inl ? dataUrl(person.coverThumb) : url(person.coverThumb));
		return JSONValue(["people": JSONValue(out_)]);
	});

	r.add("people.rename", (JSONValue p) {
		import std.string : strip;

		service.rename(requireLong(p, "id"), requireString(p, "name").strip);
		return obj();
	});

	// {id} → {people: [{id, name?, faces, coverUrl?, similarity}]}: who this face most likely is
	r.add("face.candidates", (JSONValue p) {
		immutable id = requireLong(p, "id");
		immutable inl = inline(p);
		float[] sims;
		auto ids = service.candidatesForFace(id, sims);
		JSONValue[] out_;
		foreach (person; faces.people())
			foreach (k, pid; ids)
				if (person.id == pid)
				{
					auto j = FaceRepo.toJson(person, inl ? dataUrl(person.coverThumb) : url(person.coverThumb));
					j["similarity"] = sims[k];
					out_ ~= j;
				}
		import std.algorithm : sort;
		out_.sort!((a, b) => a["similarity"].floating > b["similarity"].floating);
		return JSONValue(["faceId": JSONValue(id), "people": JSONValue(out_)]);
	});

	// {id} → {faces}: the person is removed from People; its detections stay, unnamed
	r.add("people.remove", (JSONValue p) {
		return JSONValue(["faces": JSONValue(service.removePerson(requireLong(p, "id")))]);
	});

	// {id, faceId?}: this face is the person's portrait (no faceId = back to automatic)
	r.add("people.setCover", (JSONValue p) {
		faces.setCover(requireLong(p, "id"), getLong(p, "faceId"));
		events.emit("people.changed", JSONValue.emptyObject);
		return obj();
	});

	r.add("people.merge", (JSONValue p) {
		service.merge(requireLong(p, "id"), requireLong(p, "into"));
		return obj();
	});

	r.add("photo.faces", (JSONValue p) {
		immutable id = requireLong(p, "id");
		immutable inl = inline(p);
		JSONValue[] out_;
		foreach (ref f; faces.facesOfPhoto(id))
			out_ ~= FaceRepo.toJson(f, inl ? dataUrl(f.thumbHash) : url(f.thumbHash));
		return JSONValue(["photoId": JSONValue(id), "faces": JSONValue(out_)]);
	});

	// {faceId, personId?, name?}: an existing person, or a (new) person by name; neither = unassign
	r.add("face.setPerson", (JSONValue p) {
		import std.string : strip;

		long followed;
		immutable person = service.assignFace(requireLong(p, "faceId"), getLong(p, "personId"), getString(p, "name", "").strip, followed);
		return JSONValue(["personId": person ? JSONValue(person) : JSONValue(null), "followed": JSONValue(followed)]);
	});

	// {id} → people that may be the same one (close, never in a photo together), closest first
	r.add("people.similar", (JSONValue p) {
		immutable id = requireLong(p, "id");
		float[] sims;
		auto ids = service.similarPersons(id, sims);
		JSONValue[] out_;
		foreach (k, pid; ids)
		{
			auto person = faces.person(pid);
			auto j = FaceRepo.toJson(person, url(person.coverThumb));
			j["similarity"] = sims[k];
			out_ ~= j;
		}
		auto me = faces.person(id);
		return JSONValue([
			"person": FaceRepo.toJson(me, url(me.coverThumb)),
			"candidates": JSONValue(out_),
		]);
	});

	r.add("face.delete", (JSONValue p) {
		service.deleteFace(requireLong(p, "faceId"));
		return obj();
	});

	r.add("people.delete", (JSONValue p) {
		return JSONValue(["faces": JSONValue(service.deletePerson(requireLong(p, "id")))]);
	});

	r.add("faces.scan", (JSONValue p) {
		if (!service.available)
			throw new ApiError("faces_off", "the face models did not load");
		service.start();
		return obj();
	});

	r.add("faces.recluster", (JSONValue p) {
		service.recluster();
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
			"people": JSONValue(service.index.personCount),
		]);
	});
}
