/// The face job: every local photo not yet scanned goes through the detector
/// on a worker thread; each face gets a crop in the store and a person from
/// the cluster index. One job at a time; a request during a run queues one more.
module photowagon.core.faces.service;

import core.time : MonoTime, msecs;
import std.json;

import vibe.core.concurrency : async;

import photowagon.core.jobs.scheduler : jobs, Priority;
import vibe.core.log : logInfo, logWarn;
import vibe.core.task : InterruptException;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.config : Config;
import photowagon.core.db.sqlite : Database;
import photowagon.core.db.schema : getSetting, setSetting;
import photowagon.core.faces.cluster : ClusterIndex, SplitFace, eligible, clusterVersion, splitTowards, keepScore,
	minScore, minFaceWidth;
import photowagon.core.faces.detect : FaceHit, detectFaces, initFaces;
import photowagon.core.faces.repo : FaceRepo;
import photowagon.core.ipc.events : Events;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.store.store : ContentStore;
import photowagon.core.thumbs.vips : renderFaceCrop;

/// Longest edge of a face crop in the store.
enum faceThumbEdge = 192;

final class FaceService
{
	private Config cfg;
	private Database db;
	private FaceRepo faces;
	private PhotoRepo photos;
	private ContentStore store;
	private Events events;
	private ClusterIndex cluster;
	private FiberGroup fibers;
	private bool running, again;
	bool available; // models loaded

	this(Config cfg, Database db, FaceRepo faces, PhotoRepo photos, ContentStore store, Events events)
	{
		this.cfg = cfg;
		this.db = db;
		this.faces = faces;
		this.photos = photos;
		this.store = store;
		this.events = events;
		cluster = new ClusterIndex(db);
		fibers = new FiberGroup((Exception e) nothrow {
			try
				logWarn("faces: job failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
		try
		{
			initFaces(cfg.yunetModel, cfg.sfaceModel);
			available = true;
		}
		catch (Exception e)
			logWarn("faces: disabled: %s", e.msg);
		import std.conv : to;

		// Repair the per-face vector index. An early build's addFace used an UPSERT that vec0
		// rejects ("UPSERT not implemented for virtual table"), so every face scanned by that
		// build is missing from face_vec and cannot be recognised. Rebuild it once from the
		// stored embeddings; the fix to addFace keeps it correct from here on.
		if (getSetting(db, "face_vec_build") != "2")
		{
			rebuildFaceVec();
			setSetting(db, "face_vec_build", "2");
		}

		if (getSetting(db, "cluster_version") != clusterVersion.to!string)
		{
			// grouped by an older rule (or never): redo it from the stored embeddings
			recluster();
			setSetting(db, "cluster_version", clusterVersion.to!string);
		}
		else
			loadIndex();
		logInfo("faces: %s faces in %s people", cluster.length, cluster.personCount);
	}

	private void loadIndex()
	{
		cluster = new ClusterIndex(db);
		faces.eachFace((ref FaceRepo.StoredFace f) {
			if (f.personId == 0)
				return;
			float[128] e = f.embedding[0 .. 128];
			cluster.add(f.personId, e, f.personNamed);
		});
	}

	/// Rebuild face_vec (the per-face recognition index) from every eligible face's stored
	/// embedding. Idempotent; used once to repair the index after the addFace UPSERT bug.
	private void rebuildFaceVec()
	{
		db.exec("DELETE FROM face_vec");
		auto q = db.prepare(`SELECT f.id, f.embedding FROM faces f JOIN photos p ON p.id = f.photo_id
			WHERE length(f.embedding) = 512 AND f.score >= ? AND f.w * p.width >= ?`);
		q.bind(1, cast(double) minScore).bind(2, cast(double) minFaceWidth);
		auto ins = db.prepare("INSERT INTO face_vec (face_id, embedding) VALUES (?, ?)");
		long n;
		while (q.step())
		{
			ins.reset();
			ins.bind(1, q.getLong(0)).bind(2, q.getBlob(1));
			ins.run();
			n++;
		}
		logInfo("faces: recognition index rebuilt with %s faces", n);
	}

	/// Rebuilds every automatic grouping with the current rule. Named persons
	/// keep their name and the faces that agree with their majority identity
	/// (a person named while the grouping was wrong keeps the name, not the
	/// strangers); everything else is reassigned.
	void recluster()
	{
		import photowagon.core.faces.cluster : unit, dot, joinThreshold;

		logInfo("faces: regrouping with rule %s", clusterVersion);
		immutable weak = faces.deleteBelowScore(keepScore);
		if (weak)
			logInfo("faces: dropped %s weak detections", weak);
		faces.clearUnnamedPersons();
		cluster = new ClusterIndex(db);
		struct Pending { long id; float[128] e; long photo; }
		Pending[] todo;
		Pending[][long] named; // faces of each named person, to be purified
		faces.eachFace((ref FaceRepo.StoredFace f) {
			float[128] e = f.embedding[0 .. 128];
			if (!eligible(f.widthPx, f.score))
			{
				if (f.personId)
					named[f.personId] ~= Pending(-f.id, e, f.photoId); // negative id: drop, never a seed
				return;
			}
			if (f.personId)
				named[f.personId] ~= Pending(f.id, e, f.photoId);
			else
				todo ~= Pending(f.id, e, f.photoId);
		});
		db.transaction!void({
			foreach (person, members; named)
			{
				// the majority identity: iterate the centroid over the faces that agree with it
				bool[] keep = new bool[members.length];
				foreach (i, ref m; members)
					keep[i] = m.id > 0;
				foreach (round; 0 .. 4)
				{
					float[128] sum = 0;
					uint n;
					foreach (i, ref m; members)
						if (keep[i])
						{
							auto u = unit(m.e);
							sum[] += u[];
							n++;
						}
					if (n == 0)
						break;
					auto mean = unit(sum);
					foreach (i, ref m; members)
					{
						auto u = unit(m.e);
						keep[i] = m.id > 0 && dot(mean, u) >= joinThreshold;
					}
					// one face per photo: of two kept faces in the same picture, only the closest stays
					float[long] bestInPhoto;
					size_t[long] bestIdx;
					foreach (i, ref m; members)
					{
						if (!keep[i])
							continue;
						auto u = unit(m.e);
						immutable sim = dot(mean, u);
						if (auto b = m.photo in bestInPhoto)
						{
							if (sim > *b)
							{
								keep[bestIdx[m.photo]] = false;
								bestInPhoto[m.photo] = sim;
								bestIdx[m.photo] = i;
							}
							else
								keep[i] = false;
						}
						else
						{
							bestInPhoto[m.photo] = sim;
							bestIdx[m.photo] = i;
						}
					}
				}
				long kept;
				foreach (i, ref m; members)
				{
					if (keep[i])
					{
						cluster.add(person, m.e, true);
						kept++;
					}
					else
					{
						immutable id = m.id > 0 ? m.id : -m.id;
						faces.setFacePerson(id, 0);
						if (m.id > 0)
							todo ~= Pending(id, m.e, m.photo);
					}
				}
				logInfo("faces: person %s keeps %s of %s faces", person, kept, members.length);
			}
			import std.algorithm : sort;

			todo.sort!((a, b) => a.id < b.id);
			// persons already present in each photo (the purified named ones)
			long[][long] inPhoto;
			foreach (person, members; named)
				foreach (i, ref m; members)
					if (m.id > 0 && faces.face(m.id).personId == person)
						inPhoto[m.photo] ~= person;
			long ambiguousCount;
			foreach (ref t; todo)
			{
				auto taken = t.photo in inPhoto;
				auto takenList = taken ? *taken : null;
				// recognise a named person by the face-vote first (this is what pulls a face
				// that was left unassigned back onto a person the user has since named)
				bool ambiguousNamed;
				long person = cluster.matchNamedByFaces(t.e, takenList, ambiguousNamed);
				if (person == 0 && !ambiguousNamed)
				{
					float best;
					bool ambiguous;
					person = cluster.match(t.e, best, ambiguous, takenList);
					if (person == 0 && ambiguous)
					{
						ambiguousCount++;
						continue; // stays unassigned: the user decides
					}
					if (person == 0)
						person = faces.createPerson(null);
				}
				else if (person == 0 && ambiguousNamed)
				{
					ambiguousCount++;
					continue; // two named people equally close: the user decides
				}
				faces.setFacePerson(t.id, person);
				cluster.add(person, t.e);
				inPhoto[t.photo] ~= person;
			}
			if (ambiguousCount)
				logInfo("faces: %s faces left for the user (too close to two people)", ambiguousCount);
			mergeClose();
			faces.pruneEmptyPersons();
		});
		logInfo("faces: regrouped %s faces into %s people", todo.length, cluster.personCount);
		events.emit("people.changed", JSONValue.emptyObject);
	}

	/// Persons whose centroids are close enough are one person — unless they
	/// were seen together in a photo, which settles that they are two. One
	/// merge at a time, with the co-occurrence carried over: after X joins Y,
	/// whoever was in a photo with X is in a photo with Y.
	private void mergeClose()
	{
		import std.conv : to;

		bool[long][long] together; // person → persons seen with it
		foreach (key, _; faces.coOccurringPersons())
		{
			import std.string : indexOf;

			immutable c = key.indexOf(':');
			immutable a = key[0 .. c].to!long, b = key[c + 1 .. $].to!long;
			together[a][b] = true;
			together[b][a] = true;
		}
		bool apart(long a, long b)
		{
			auto s = a in together;
			return s !is null && (b in *s) !is null;
		}

		foreach (round; 0 .. 500)
		{
			auto pairs = cluster.mergeCandidates(&apart);
			if (pairs.length == 0)
				break;
			immutable from = pairs[0][0], into = pairs[0][1];
			logInfo("faces: merging person %s into %s%s", from, into, apart(from, into) ? " (TOGETHER!)" : "");
			faces.mergePersons(from, into);
			cluster.merge(from, into);
			if (auto s = from in together)
				foreach (other, _; *s)
				{
					together[into][other] = true;
					together[other][into] = true;
					together[other].remove(from);
				}
			together.remove(from);
		}
	}

	ClusterIndex index()
	{
		return cluster;
	}

	bool busy() const
	{
		return running;
	}

	/// Scans whatever is unscanned. Cheap to call often.
	void start()
	{
		if (!available)
			return;
		if (running)
		{
			again = true;
			return;
		}
		running = true;
		fibers.spawn(() {
			scope (exit)
				running = false;
			do
			{
				again = false;
				run();
			}
			while (again);
		});
	}

	private void run()
	{
		if (faces.unscannedPhotos(1).length == 0)
			return;
		jobs.pass(Priority.faces, "looking for faces", &runPass);
		// OpenCV's memory goes with the worker; the next pass starts a fresh one
		import photowagon.core.vision.worker : releaseVision;
		releaseVision();
	}

	private void runPass()
	{
		auto ids = faces.unscannedPhotos();
		if (ids.length == 0)
			return;
		logInfo("faces: scanning %s photos", ids.length);
		auto started = MonoTime.currTime;
		auto lastReport = started;
		long done, found;
		foreach (id; ids)
		{
			try
				found += scanPhoto(id);
			catch (InterruptException)
				throw new InterruptException;
			catch (Exception e)
				logWarn("faces: photo %s: %s", id, e.msg);
			faces.markScanned(id);
			done++;
			if (MonoTime.currTime - lastReport > 300.msecs || done == ids.length)
			{
				lastReport = MonoTime.currTime;
				events.emit("faces.progress", JSONValue(["done": JSONValue(done), "total": JSONValue(ids.length), "faces": JSONValue(found)]));
			}
			if (found && done % 20 == 0)
				events.emit("people.changed", JSONValue.emptyObject);
		}
		mergeClose();
		faces.pruneEmptyPersons();
		immutable secs = (MonoTime.currTime - started).total!"msecs" / 1000.0;
		logInfo("faces: done — %s faces in %s photos, %.1fs", found, done, secs);
		events.emit("faces.done", JSONValue(["photos": JSONValue(done), "faces": JSONValue(found), "seconds": JSONValue(secs)]));
		events.emit("people.changed", JSONValue.emptyObject);
	}

	private long scanPhoto(long id)
	{
		auto photo = photos.get(id);
		if (photo.path is null)
			return 0;
		import std.algorithm : max;
		immutable edgeHint = max(photo.width, photo.height);
		auto hits = jobs.background({ return async(&detectFaces, photo.path, edgeHint).getResult(); });
		long[] inThisPhoto; // nobody appears twice in one picture
		foreach (ref hit; hits)
		{
			if (hit.w < 0.01 || hit.h < 0.01 || hit.score < keepScore)
				continue;
			string thumb;
			try
				thumb = jobs.background({ return async(&renderFaceCrop, photo.path, cfg.storeDir, cast(double) hit.x, cast(double) hit.y,
						cast(double) hit.w, cast(double) hit.h, faceThumbEdge).getResult(); });
			catch (Exception e)
				logWarn("faces: crop failed for %s: %s", photo.path, e.msg);
			long person;
			immutable elig = eligible(hit.w * photo.width, hit.score);
			if (elig)
			{
				// first, recognise a person the user has already named, by a vote of the
				// nearest faces (catches a known face at a new angle the centroid misses)
				bool ambiguousNamed;
				person = cluster.matchNamedByFaces(hit.embedding, inThisPhoto, ambiguousNamed);
				if (person == 0 && !ambiguousNamed)
				{
					// nobody named is near: the usual centroid grouping into automatic people
					float best;
					bool ambiguous;
					person = cluster.match(hit.embedding, best, ambiguous, inThisPhoto);
					if (person == 0 && !ambiguous)
						person = faces.createPerson(null);
					// ambiguous → leave unassigned for the user
				}
				// ambiguousNamed → leave unassigned for the user
				if (person)
					inThisPhoto ~= person;
			}
			immutable faceId = faces.insertFace(id, hit.x, hit.y, hit.w, hit.h, hit.score, hit.embedding[], thumb, person);
			if (person)
				cluster.add(person, hit.embedding);
			if (elig)
				cluster.addFace(faceId, hit.embedding); // this face can now vote for later ones
		}
		return hits.length;
	}

	// ---- edits from the UI --------------------------------------------------------------------

	/// Puts a face under `personId`, or under a person called `name` (created
	/// when new). When the face leaves a person for another one, the faces of
	/// the old person that look more like the new one follow it (this is how
	/// a look-alike — a sibling — gets separated: name one of her faces).
	/// Returns the person and how many other faces followed.
	long assignFace(long faceId, long personId, string name, out long followed)
	{
		auto before = faces.face(faceId);
		immutable beforeNamed = before.personId && faces.person(before.personId).name !is null;
		if (personId == 0 && name.length)
			personId = faces.personByName(name);

		// The face sits in an automatic (unnamed) group: the user is telling us
		// who that whole group is, not correcting one face.
		if (before.personId && !beforeNamed && (personId || name.length))
		{
			if (personId == 0)
			{
				faces.renamePerson(before.personId, name);
				cluster.setNamed(before.personId, true);
				followed = faces.person(before.personId).faces - 1;
				events.emit("people.changed", JSONValue.emptyObject);
				return before.personId;
			}
			if (personId != before.personId)
			{
				followed = mergeRespectingPhotos(before.personId, personId, faceId);
				events.emit("people.changed", JSONValue.emptyObject);
				return personId;
			}
		}

		if (personId == 0 && name.length)
			personId = faces.createPerson(name);
		faces.setFacePerson(faceId, personId);
		auto e = faces.embeddingOf(faceId);
		if (before.personId)
			cluster.remove(before.personId, e);
		if (personId)
		{
			cluster.add(personId, e, faces.person(personId).name !is null);
			// the user says this face is the person: any other face of hers in the same photo is not
			foreach (other; faces.sameFacesInPhoto(faceId, personId))
			{
				faces.setFacePerson(other, 0);
				auto oe = faces.embeddingOf(other);
				cluster.remove(personId, oe);
			}
		}

		if (before.personId && personId && before.personId != personId)
			followed = splitPerson(before.personId, personId, faceId, e);

		faces.pruneEmptyPersons();
		events.emit("people.changed", JSONValue.emptyObject);
		return personId;
	}

	/// Every face of `from` joins `into`, except those in a photo where `into`
	/// already has a face (they become unassigned). `keepId` always moves.
	private long mergeRespectingPhotos(long from, long into, long keepId)
	{
		bool[long] photoTaken;
		long[] fromFaces;
		faces.eachFace((ref FaceRepo.StoredFace f) {
			if (f.personId == into)
				photoTaken[f.photoId] = true;
			else if (f.personId == from)
				fromFaces ~= f.id;
		});
		long moved;
		db.transaction!void({
			// the face the user pointed at goes first, so it wins its photo
			foreach (id; [keepId] ~ fromFaces)
			{
				if (id != keepId && id == keepId)
					continue;
				auto f = faces.face(id);
				if (f.personId != from)
					continue;
				auto e = faces.embeddingOf(id);
				cluster.remove(from, e);
				if (id != keepId && f.photoId in photoTaken)
				{
					faces.setFacePerson(id, 0);
					continue;
				}
				photoTaken[f.photoId] = true;
				faces.setFacePerson(id, into);
				cluster.add(into, e, true);
				if (id != keepId)
					moved++;
			}
			faces.pruneEmptyPersons();
		});
		logInfo("faces: group %s is person %s (%s faces followed)", from, into, moved);
		return moved;
	}

	/// Moves the faces of `from` that look more like `into` (seeded by `seedId`).
	private long splitPerson(long from, long into, long seedId, const ref float[128] seed)
	{
		SplitFace[] ofFrom;
		const(float[128])[] ofInto;
		faces.eachFace((ref FaceRepo.StoredFace f) {
			if (f.id == seedId)
				return;
			float[128] e = f.embedding[0 .. 128];
			if (f.personId == from && eligible(f.widthPx, f.score))
				ofFrom ~= SplitFace(f.id, e);
			else if (f.personId == into)
				ofInto ~= e;
		});
		if (ofFrom.length == 0)
			return 0;
		auto moved = splitTowards(ofFrom, ofInto, seed);
		bool[long] movedSet;
		foreach (id; moved)
			movedSet[id] = true;
		// Also pull in the faces of `from` that most look like the very face the user just
		// corrected — its near-twins by direct similarity. The centroid split above misses
		// these when the two people are confusable (their averages sit almost on top of each
		// other), which is exactly the "I fixed one, the rest still say Tomás" case.
		bool[long] fromIds;
		foreach (ref f; ofFrom)
			fromIds[f.id] = true;
		foreach (fid; cluster.facesNear(seed, 0.52f, 150))
			if (fid in fromIds)
				movedSet[fid] = true;
		if (movedSet.length == 0)
			return 0;
		// one face per photo: photos where `into` already has a face keep it
		bool[long] photoTaken;
		faces.eachFace((ref FaceRepo.StoredFace f) {
			if (f.personId == into)
				photoTaken[f.photoId] = true;
		});
		long count;
		db.transaction!void({
			foreach (ref f; ofFrom)
				if (f.id in movedSet)
				{
					immutable photo = faces.face(f.id).photoId;
					if (photo in photoTaken)
						continue;
					photoTaken[photo] = true;
					faces.setFacePerson(f.id, into);
					cluster.remove(from, f.embedding);
					cluster.add(into, f.embedding);
					count++;
				}
		});
		moved.length = count;
		logInfo("faces: %s faces followed the correction from person %s to %s", moved.length, from, into);
		return moved.length;
	}

	/// Renames; giving a person the name of an existing one merges them.
	/// Persons that may be the same as `personId`: close centroids, never seen
	/// together in a photo. `sims` gets the cosine of each.
	long[] similarPersons(long personId, out float[] sims)
	{
		import std.conv : to;

		auto together = faces.coOccurringPersons();
		float[] all;
		auto ids = cluster.similarTo(personId, 0.42f, all);
		long[] out_;
		foreach (k, id; ids)
		{
			immutable a = id < personId ? id : personId, b = id < personId ? personId : id;
			if ((a.to!string ~ ":" ~ b.to!string) in together)
				continue;
			out_ ~= id;
			sims ~= all[k];
			if (out_.length == 5)
				break;
		}
		return out_;
	}

	/// Who this face most likely is: persons closest to its embedding, closest first.
	long[] candidatesForFace(long faceId, out float[] sims)
	{
		auto e = faces.embeddingOf(faceId);
		return cluster.rankFor(e, sims, 8);
	}

	/// "Remove from People": the person goes, its detections stay unnamed.
	long removePerson(long personId)
	{
		immutable n = faces.unassignAndDeletePerson(personId);
		loadIndex();
		events.emit("people.changed", JSONValue.emptyObject);
		return n;
	}

	/// "Not a face": the detection goes away.
	void deleteFace(long faceId)
	{
		auto f = faces.face(faceId);
		auto e = faces.embeddingOf(faceId);
		if (f.personId)
			cluster.remove(f.personId, e);
		faces.deleteFace(faceId);
		faces.pruneEmptyPersons();
		events.emit("people.changed", JSONValue.emptyObject);
	}

	/// "Not a person": an automatic group and all its detections go away.
	long deletePerson(long personId)
	{
		immutable n = faces.deletePersonWithFaces(personId);
		loadIndex();
		events.emit("people.changed", JSONValue.emptyObject);
		return n;
	}

	void rename(long personId, string name)
	{
		immutable existing = name.length ? faces.personByName(name) : 0;
		if (existing && existing != personId)
		{
			merge(personId, existing);
			return;
		}
		faces.renamePerson(personId, name);
		cluster.setNamed(personId, name.length > 0);
		events.emit("people.changed", JSONValue.emptyObject);
	}

	void merge(long from, long into)
	{
		faces.mergePersons(from, into);
		cluster.merge(from, into);
		events.emit("people.changed", JSONValue.emptyObject);
	}

	void close() nothrow
	{
		fibers.stopAll();
	}
}
