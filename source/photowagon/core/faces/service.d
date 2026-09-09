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
import photowagon.core.faces.cluster : ClusterIndex;
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
	private FaceRepo faces;
	private PhotoRepo photos;
	private ContentStore store;
	private Events events;
	private ClusterIndex cluster;
	private FiberGroup jobs;
	private bool running, again;
	bool available; // models loaded

	this(Config cfg, FaceRepo faces, PhotoRepo photos, ContentStore store, Events events)
	{
		this.cfg = cfg;
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
		faces.eachEmbedding((long fid, long pid, const(float)[] emb) {
			float[128] e = emb[0 .. 128];
			cluster.add(fid, pid, e);
		});
		logInfo("faces: %s known faces", cluster.length);
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
			float best;
			long person = cluster.match(hit.embedding, best);
			if (person == 0)
				person = faces.createPerson(null);
			immutable faceId = faces.insertFace(id, hit.x, hit.y, hit.w, hit.h, hit.score, hit.embedding[], thumb, person);
			cluster.add(faceId, person, hit.embedding);
		}
		return hits.length;
	}

	// ---- edits from the UI --------------------------------------------------------------------

	/// Puts a face under `personId`, or under a person called `name` (created when new).
	long assignFace(long faceId, long personId, string name)
	{
		if (personId == 0 && name.length)
		{
			personId = faces.personByName(name);
			if (personId == 0)
				personId = faces.createPerson(name);
		}
		faces.setFacePerson(faceId, personId);
		cluster.setPerson(faceId, personId);
		faces.pruneEmptyPersons();
		events.emit("people.changed", JSONValue.emptyObject);
		return personId;
	}

	void rename(long personId, string name)
	{
		faces.renamePerson(personId, name);
		events.emit("people.changed", JSONValue.emptyObject);
	}

	void merge(long from, long into)
	{
		faces.mergePersons(from, into);
		cluster.reassign(from, into);
		events.emit("people.changed", JSONValue.emptyObject);
	}

	void close() nothrow
	{
		jobs.stopAll();
	}
}
