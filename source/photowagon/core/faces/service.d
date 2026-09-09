/// The face job: every local photo not yet scanned goes through the detector
/// on a worker thread; each face gets a crop in the store and a person from
/// the cluster index. One job at a time; a request during a run queues one more.
module photowagon.core.faces.service;

import core.time : MonoTime, msecs;
import std.json;

import vibe.core.concurrency : async;
import vibe.core.log : logInfo, logWarn;
import vibe.core.task : InterruptException;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.config : Config;
import photowagon.core.db.sqlite : Database;
import photowagon.core.db.schema : getSetting, setSetting;
import photowagon.core.faces.cluster : ClusterIndex, SplitFace, eligible, clusterVersion, splitTowards;
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
	private FiberGroup jobs;
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
		cluster = new ClusterIndex;
		jobs = new FiberGroup((Exception e) nothrow {
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
		cluster = new ClusterIndex;
		faces.eachFace((ref FaceRepo.StoredFace f) {
			if (f.personId == 0)
				return;
			float[128] e = f.embedding[0 .. 128];
			cluster.add(f.personId, e, f.personNamed);
		});
	}

	/// Rebuilds every automatic grouping with the current rule. Named persons
	/// keep their name and the faces that agree with their majority identity
	/// (a person named while the grouping was wrong keeps the name, not the
	/// strangers); everything else is reassigned.
	void recluster()
	{
		import photowagon.core.faces.cluster : unit, dot, joinThreshold;

		logInfo("faces: regrouping with rule %s", clusterVersion);
		faces.clearUnnamedPersons();
		cluster = new ClusterIndex;
		struct Pending { long id; float[128] e; }
		Pending[] todo;
		Pending[][long] named; // faces of each named person, to be purified
		faces.eachFace((ref FaceRepo.StoredFace f) {
			float[128] e = f.embedding[0 .. 128];
			if (!eligible(f.widthPx, f.score))
			{
				if (f.personId)
					named[f.personId] ~= Pending(-f.id, e); // negative id: drop, never a seed
				return;
			}
			if (f.personId)
				named[f.personId] ~= Pending(f.id, e);
			else
				todo ~= Pending(f.id, e);
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
							todo ~= Pending(id, m.e);
					}
				}
				logInfo("faces: person %s keeps %s of %s faces", person, kept, members.length);
			}
			import std.algorithm : sort;

			todo.sort!((a, b) => a.id < b.id);
			foreach (ref t; todo)
			{
				float best;
				long person = cluster.match(t.e, best);
				if (person == 0)
					person = faces.createPerson(null);
				faces.setFacePerson(t.id, person);
				cluster.add(person, t.e);
			}
			mergeClose();
			faces.pruneEmptyPersons();
		});
		logInfo("faces: regrouped %s faces into %s people", todo.length, cluster.personCount);
		events.emit("people.changed", JSONValue.emptyObject);
	}

	/// Persons whose centroids are close enough are one person.
	private void mergeClose()
	{
		foreach (pair; cluster.mergeCandidates())
		{
			faces.mergePersons(pair[0], pair[1]);
			cluster.merge(pair[0], pair[1]);
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
		jobs.spawn(() {
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
		auto hits = async(&detectFaces, photo.path).getResult();
		foreach (ref hit; hits)
		{
			if (hit.w < 0.01 || hit.h < 0.01)
				continue;
			string thumb;
			try
				thumb = async(&renderFaceCrop, photo.path, cfg.storeDir, cast(double) hit.x, cast(double) hit.y,
						cast(double) hit.w, cast(double) hit.h, faceThumbEdge).getResult();
			catch (Exception e)
				logWarn("faces: crop failed for %s: %s", photo.path, e.msg);
			long person;
			if (eligible(hit.w * photo.width, hit.score))
			{
				float best;
				person = cluster.match(hit.embedding, best);
				if (person == 0)
					person = faces.createPerson(null);
			}
			faces.insertFace(id, hit.x, hit.y, hit.w, hit.h, hit.score, hit.embedding[], thumb, person);
			if (person)
				cluster.add(person, hit.embedding);
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
		if (personId == 0 && name.length)
		{
			personId = faces.personByName(name);
			if (personId == 0)
				personId = faces.createPerson(name);
		}
		faces.setFacePerson(faceId, personId);
		auto e = faces.embeddingOf(faceId);
		if (before.personId)
			cluster.remove(before.personId, e);
		if (personId)
			cluster.add(personId, e, faces.person(personId).name !is null);

		if (before.personId && personId && before.personId != personId)
			followed = splitPerson(before.personId, personId, faceId, e);

		faces.pruneEmptyPersons();
		events.emit("people.changed", JSONValue.emptyObject);
		return personId;
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
		if (moved.length == 0)
			return 0;
		bool[long] movedSet;
		foreach (id; moved)
			movedSet[id] = true;
		db.transaction!void({
			foreach (ref f; ofFrom)
				if (f.id in movedSet)
				{
					faces.setFacePerson(f.id, into);
					cluster.remove(from, f.embedding);
					cluster.add(into, f.embedding);
				}
		});
		logInfo("faces: %s faces followed the correction from person %s to %s", moved.length, from, into);
		return moved.length;
	}

	void rename(long personId, string name)
	{
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
		jobs.stopAll();
	}
}
