/// Import pipeline: scan → (hash · EXIF · thumbnail on workers) → row → events.
///
/// One job fiber per root, `cfg.workers` pipeline fibers per job. CPU work is
/// pushed to vibe's worker threads through `async`; the database is touched
/// only from the pipeline fibers, which run on the main thread.
module photowagon.core.indexer.indexer;

import core.time : MonoTime, msecs;
import std.json;

import vibe.core.concurrency : async;

import photowagon.core.jobs.scheduler : jobs, Priority;
import vibe.core.core : runTask;
import vibe.core.log : logInfo, logWarn, logDiagnostic;
import vibe.core.task : Task, InterruptException;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.config : Config;
import photowagon.core.indexer.hash : sha256File;
import photowagon.core.indexer.scan : Candidate, scanImages;
import photowagon.core.library.calendar : isoTime;
import photowagon.core.ipc.events : Events;
import photowagon.core.library.photos : Photo, PhotoRepo;
import photowagon.core.metadata.exif : ExifInfo, readExif;
import photowagon.core.library.kind : Signals, classify;
import photowagon.core.thumbs.vips : ThumbResult, makeThumbnail, imageStats;

final class Indexer
{
	private Config cfg;
	private PhotoRepo photos;
	private Events events;
	private FiberGroup fibers;
	/// Called on the main thread after each finished job (the face scan hangs here).
	void delegate() onDone;
	/// A freshly indexed file carried keywords (XMP / IPTC): the library takes them.
	void delegate(long photoId, string[] subjects) onFileSubjects;
	private bool[long] running; // root ids with a job in flight
	private bool[long] again; // roots asked for again while running

	this(Config cfg, PhotoRepo photos, Events events)
	{
		this.cfg = cfg;
		this.photos = photos;
		this.events = events;
		fibers = new FiberGroup((Exception e) nothrow {
			try
				logWarn("indexer: job failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	bool busy() const
	{
		return running.length > 0;
	}

	/// Starts indexing `path` as root `rootId`; a second call for the same
	/// root while one is running is ignored.
	void start(long rootId, string path)
	{
		if (rootId in running)
		{
			again[rootId] = true; // files arrived mid-run; go once more when done
			return;
		}
		running[rootId] = true;
		fibers.spawn(() {
			scope (exit)
				running.remove(rootId);
			new Job(this, rootId, path).run();
			if (rootId in again)
			{
				again.remove(rootId);
				new Job(this, rootId, path).run();
			}
			if (onDone)
				onDone();
		});
	}

	void close() nothrow
	{
		fibers.stopAll();
	}
}

private final class Job
{
	private Indexer owner;
	private long rootId;
	private string root;
	private Candidate[] candidates;
	private size_t next;
	private long imported, skipped, scanned;
	private MonoTime lastReport;
	private MonoTime started;

	this(Indexer owner, long rootId, string root)
	{
		this.owner = owner;
		this.rootId = rootId;
		this.root = root;
	}

	void run()
	{
		jobs.pass(Priority.indexer, "indexing " ~ root, &runPass);
	}

	private void runPass()
	{
		started = MonoTime.currTime;
		logInfo("indexer: scanning %s", root);
		candidates = jobs.background({ return async(&scanImages, root).getResult(); });
		logInfo("indexer: %s candidates under %s", candidates.length, root);
		report(true);

		Task[] workers;
		scope (failure)
			foreach (w; workers)
				if (w.running)
					w.interrupt();
		foreach (i; 0 .. owner.cfg.workers)
			workers ~= runTask(() nothrow {
				try
					pipeline();
				catch (InterruptException)
				{
				}
				catch (Exception e)
				{
					try
						logWarn("indexer: pipeline died: %s", e.msg);
					catch (Exception)
					{
					}
				}
			});
		foreach (w; workers)
			w.join();

		// files that vanished since the last run
		import std.file : exists;

		immutable removed = owner.photos.deleteMissingUnder(rootId, (string p) => p.exists);

		report(true);
		immutable secs = (MonoTime.currTime - started).total!"msecs" / 1000.0;
		logInfo("indexer: done %s — imported %s, skipped %s, removed %s in %.1fs", root, imported, skipped, removed, secs);
		owner.events.emit("index.done", JSONValue([
			"rootId": JSONValue(rootId), "imported": JSONValue(imported), "skipped": JSONValue(skipped),
			"removed": JSONValue(removed), "seconds": JSONValue(secs)
		]));
		if (imported || removed)
			owner.events.emit("library.changed", JSONValue.emptyObject);
	}

	private void pipeline()
	{
		while (next < candidates.length)
		{
			auto c = candidates[next++];
			try
				process(c);
			catch (InterruptException)
				throw new InterruptException;
			catch (Exception e)
			{
				logWarn("indexer: %s: %s", c.path, e.msg);
				skipped++;
			}
			scanned++;
			report(false);
		}
	}

	private void process(Candidate c)
	{
		auto known = owner.photos.byPath(c.path);
		if (!known.isNull && known.get.size == c.size && known.get.mtimeMs == c.mtimeMs)
		{
			skipped++;
			return;
		}
		if (!known.isNull)
			logDiagnostic("indexer: changed %s (size %s → %s, mtime %s → %s)", c.path, known.get.size, c.size,
				known.get.mtimeMs, c.mtimeMs);

		immutable hash = jobs.background({ return async(&sha256File, c.path).getResult(); });
		auto same = owner.photos.byHash(hash);
		if (!same.isNull && same.get.path != c.path)
		{
			// same bytes already indexed under another path: keep the first, count this one
			logDiagnostic("indexer: duplicate of %s: %s", same.get.path, c.path);
			skipped++;
			return;
		}

		auto exif = jobs.background({ return async(&readExif, c.path).getResult(); });
		auto thumb = jobs.background({ return async(&makeThumbnail, c.path, owner.cfg.storeDir, owner.cfg.thumbSize).getResult(); });
		if (!thumb.ok)
			throw new Exception(thumb.error);

		Photo p;
		if (!known.isNull)
			p = known.get;
		p.hash = hash;
		p.path = c.path;
		p.rootId = rootId;
		p.size = c.size;
		p.mtimeMs = c.mtimeMs;
		// EXIF, else a date in the name or the folder, else the file's mtime (the last copy)
		import photowagon.core.metadata.datefromname : dateFromPath;
		immutable named = exif.takenTs ? 0 : dateFromPath(c.path);
		p.takenTs = exif.takenTs ? exif.takenTs : (named ? named : c.mtimeMs / 1000);
		p.takenAt = isoTime(p.takenTs);
		// rotated dimensions: what the viewer will actually show
		immutable swap = exif.orientation >= 5;
		p.width = swap ? thumb.srcHeight : thumb.srcWidth;
		p.height = swap ? thumb.srcWidth : thumb.srcHeight;
		p.orientation = exif.orientation;
		p.camera = exif.camera;
		p.hasGps = exif.hasGps;
		p.lat = exif.lat;
		p.lon = exif.lon;
		p.thumbHash = thumb.hash;

		// what kind of picture it is (a user's choice on a re-import stays)
		if (p.kindBy != "user")
		{
			Signals sig;
			sig.path = c.path;
			sig.width = p.width;
			sig.height = p.height;
			sig.hasCamera = exif.camera !is null;
			try
				sig.stats = jobs.background({ return async(&imageStats, c.path).getResult(); }); // the original, not the thumbnail
			catch (Exception e)
				logDiagnostic("indexer: stats failed for %s: %s", c.path, e.msg);
			p.kind = classify(sig);
			p.kindBy = "auto";
		}

		if (p.id)
			owner.photos.update(p);
		else
			owner.photos.insert(p);
		if (exif.keywords.length && owner.onFileSubjects !is null && p.id)
			try
				owner.onFileSubjects(p.id, exif.keywords);
			catch (Exception e)
				logDiagnostic("indexer: file keywords of %s: %s", c.path, e.msg);
		imported++;
		if (imported % 200 == 0)
			owner.events.emit("library.changed", JSONValue.emptyObject);
	}

	private void report(bool force)
	{
		immutable now = MonoTime.currTime;
		if (!force && now - lastReport < 250.msecs)
			return;
		lastReport = now;
		owner.events.emit("index.progress", JSONValue([
			"rootId": JSONValue(rootId), "scanned": JSONValue(scanned), "imported": JSONValue(imported),
			"skipped": JSONValue(skipped), "total": JSONValue(candidates.length)
		]));
	}
}
