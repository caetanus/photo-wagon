/// Classifies photos the indexer left without a kind (an older library, or a
/// thumbnail that arrived from a peer): stats from the stored thumbnail on a
/// worker thread, the rules of `kind.d`, one UPDATE each. Faces found in
/// pictures that turn out not to be photographs are dropped.
module photowagon.core.library.kindjob;

import core.time : MonoTime, msecs;
import std.json;

import vibe.core.concurrency : async;
import vibe.core.log : logInfo, logWarn;
import vibe.core.task : InterruptException;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.jobs.scheduler : jobs, Priority;

import photowagon.core.faces.repo : FaceRepo;
import photowagon.core.ipc.events : Events;
import photowagon.core.db.sqlite : Database;
import photowagon.core.db.schema : getSetting, setSetting;
import photowagon.core.library.kind : Kind, Signals, classify, kindVersion;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.store.store : ContentStore;
import photowagon.core.thumbs.vips : ImageStats, imageStats;

final class KindService
{
	private PhotoRepo photos;
	private FaceRepo faces;
	private ContentStore store;
	private Events events;
	private FiberGroup fibers;
	private bool running, again;
	/// Runs after a pass that classified something (the face scan hangs here).
	void delegate() onDone;

	this(Database db, PhotoRepo photos, FaceRepo faces, ContentStore store, Events events)
	{
		import std.conv : to;

		this.photos = photos;
		if (getSetting(db, "kind_version") != kindVersion.to!string)
		{
			// classified by an older rule: redo the automatic ones
			photos.resetAutoKinds();
			setSetting(db, "kind_version", kindVersion.to!string);
		}
		this.faces = faces;
		this.store = store;
		this.events = events;
		fibers = new FiberGroup((Exception e) nothrow {
			try
				logWarn("kinds: job failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	bool busy() const
	{
		return running;
	}

	void start()
	{
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
			if (onDone)
				onDone();
		});
	}

	private void run()
	{
		if (photos.unclassified(1).length == 0)
			return;
		jobs.pass(Priority.kinds, "sorting photos, screenshots and memes", &runPass);
	}

	private void runPass()
	{
		auto ids = photos.unclassified();
		if (ids.length == 0)
			return;
		logInfo("kinds: classifying %s photos", ids.length);
		auto started = MonoTime.currTime, lastReport = started;
		long done;
		long[string] counts;
		foreach (id; ids)
		{
			try
			{
				auto p = photos.get(id);
				Signals sig;
				sig.path = p.path;
				sig.width = p.width;
				sig.height = p.height;
				sig.hasCamera = p.camera !is null;
				import std.file : exists;

				// the original when it is here: a re-compressed thumbnail flattens noise into plateaus
				immutable src = p.path !is null && p.path.exists ? p.path : store.pathFor(p.thumbHash);
				sig.stats = jobs.background({ return async(&imageStats, src).getResult(); });
				immutable kind = classify(sig);
				photos.setKind(id, kind, "auto");
				counts[kind]++;
			}
			catch (InterruptException)
				throw new InterruptException;
			catch (Exception e)
			{
				logWarn("kinds: photo %s: %s", id, e.msg);
				photos.setKind(id, Kind.photo, "auto"); // never leave it unclassified forever
			}
			done++;
			if (MonoTime.currTime - lastReport > 300.msecs || done == ids.length)
			{
				lastReport = MonoTime.currTime;
				events.emit("kinds.progress", JSONValue(["done": JSONValue(done), "total": JSONValue(ids.length)]));
			}
		}
		immutable dropped = faces.deleteFacesOfNonPhotos();
		faces.pruneEmptyPersons();
		immutable secs = (MonoTime.currTime - started).total!"msecs" / 1000.0;
		logInfo("kinds: done — %s in %.1fs, %s faces of memes/screenshots dropped", counts, secs, dropped);
		JSONValue c = JSONValue.emptyObject;
		foreach (k, n; counts)
			c[k] = n;
		events.emit("kinds.done", JSONValue(["photos": JSONValue(done), "counts": c, "seconds": JSONValue(secs)]));
		events.emit("library.changed", JSONValue.emptyObject);
		if (dropped)
			events.emit("people.changed", JSONValue.emptyObject);
	}

	/// The user says what a picture is. A photograph gets its faces scanned;
	/// anything else loses them.
	void setKind(long id, string kind, void delegate() scanFaces)
	{
		if (kind != Kind.photo && kind != Kind.screenshot && kind != Kind.meme)
			throw new Exception("kind must be photo, screenshot or meme");
		photos.setKind(id, kind, "user");
		if (kind == Kind.photo)
		{
			faces.unmarkScanned(id);
			scanFaces();
		}
		else
		{
			faces.deleteFacesOfNonPhotos();
			faces.pruneEmptyPersons();
			events.emit("people.changed", JSONValue.emptyObject);
		}
		events.emit("library.changed", JSONValue.emptyObject);
	}

	void close() nothrow
	{
		fibers.stopAll();
	}
}
