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
	private MonoTime lastStart; // when a job was last (re)started — for the tagging quiet gate

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

	/// True while a job is running or one started within `d` — used to hold expensive
	/// tagging off while photos are still flowing in (a phone sync burst), so the scan
	/// that makes photos appear and the classifiers that label them stop competing.
	import core.time : Duration;
	bool activeWithin(Duration d) const
	{
		return running.length > 0 || (lastStart != MonoTime.init && MonoTime.currTime - lastStart < d);
	}

	/// Starts indexing `path` as root `rootId`; a second call for the same
	/// root while one is running is ignored.
	void start(long rootId, string path)
	{
		lastStart = MonoTime.currTime;
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

	/// Index a SINGLE file (a photo the phone just sent), without re-scanning its whole
	/// folder — so an import no longer logs "skipped N" for everything already there and
	/// does not walk the growing imports/ directory on every photo.
	void indexOne(long rootId, string path)
	{
		import std.file : exists, getSize, timeLastModified;

		if (!path.exists)
			return;
		import photowagon.core.indexer.scan : isVideoPath;

		Candidate c;
		c.path = path;
		c.isVideo = isVideoPath(path);
		try
		{
			c.size = cast(long) getSize(path);
			c.mtimeMs = timeLastModified(path).toUnixTime!long * 1000;
		}
		catch (Exception)
			return;
		lastStart = MonoTime.currTime;
		fibers.spawn(() {
			jobs.pass(Priority.indexer, "importing " ~ path, {
				try
				{
					if (importCandidate(rootId, c))
						events.emit("library.changed", JSONValue.emptyObject);
				}
				catch (Exception e)
					logWarn("indexer: import %s: %s", path, e.msg);
			});
			if (onDone)
				onDone();
		});
	}

	/// The per-file pipeline: hash, dedupe, EXIF, thumbnail, classify, insert. Returns
	/// true when a row was added or updated, false when the file was already current.
	/// Shared by the folder scan (Job) and by `indexOne`.
	package bool importCandidate(long rootId, Candidate c)
	{
		auto known = photos.byPath(c.path);
		if (!known.isNull && known.get.size == c.size && known.get.mtimeMs == c.mtimeMs)
			return false;
		if (!known.isNull)
			logDiagnostic("indexer: changed %s (size %s → %s, mtime %s → %s)", c.path, known.get.size, c.size,
				known.get.mtimeMs, c.mtimeMs);

		immutable hash = jobs.background({ return async(&sha256File, c.path).getResult(); });
		auto same = photos.byHash(hash);
		if (!same.isNull && same.get.path != c.path)
		{
			logDiagnostic("indexer: duplicate of %s: %s", same.get.path, c.path);
			return false;
		}

		// videos take a different path: a frame is the thumbnail, ffprobe gives duration and
		// size, there is no EXIF to read and nothing to classify — kind is simply 'video'.
		if (c.isVideo)
		{
			import photowagon.core.thumbs.video : makeVideoThumbnail;
			import photowagon.core.metadata.datefromname : dateFromPath;

			auto v = jobs.background({
				return async(&makeVideoThumbnail, c.path, cfg.storeDir, cfg.thumbSize).getResult();
			});
			if (!v.ok)
				throw new Exception(v.error);
			Photo pv;
			if (!known.isNull)
				pv = known.get;
			pv.hash = hash;
			pv.path = c.path;
			pv.rootId = rootId;
			pv.size = c.size;
			pv.mtimeMs = c.mtimeMs;
			immutable vnamed = dateFromPath(c.path);
			pv.takenTs = vnamed ? vnamed : c.mtimeMs / 1000;
			pv.takenAt = isoTime(pv.takenTs);
			pv.width = v.width;
			pv.height = v.height;
			pv.orientation = 1;
			pv.thumbHash = v.hash;
			pv.durationMs = v.durationMs;
			pv.kind = "video";
			if (pv.kindBy != "user")
				pv.kindBy = "auto";
			if (pv.id)
				photos.update(pv);
			else
				photos.insert(pv);
			return true;
		}

		auto exif = jobs.background({ return async(&readExif, c.path).getResult(); });
		auto thumb = jobs.background({ return async(&makeThumbnail, c.path, cfg.storeDir, cfg.thumbSize).getResult(); });
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
		import photowagon.core.metadata.datefromname : dateFromPath;
		immutable named = exif.takenTs ? 0 : dateFromPath(c.path);
		p.takenTs = exif.takenTs ? exif.takenTs : (named ? named : c.mtimeMs / 1000);
		p.takenAt = isoTime(p.takenTs);
		immutable swap = exif.orientation >= 5;
		p.width = swap ? thumb.srcHeight : thumb.srcWidth;
		p.height = swap ? thumb.srcWidth : thumb.srcHeight;
		p.orientation = exif.orientation;
		p.camera = exif.camera;
		p.hasGps = exif.hasGps;
		p.lat = exif.lat;
		p.lon = exif.lon;
		p.thumbHash = thumb.hash;

		if (p.kindBy != "user")
		{
			Signals sig;
			sig.path = c.path;
			sig.width = p.width;
			sig.height = p.height;
			sig.hasCamera = exif.camera !is null;
			try
				sig.stats = jobs.background({ return async(&imageStats, c.path).getResult(); });
			catch (Exception e)
				logDiagnostic("indexer: stats failed for %s: %s", c.path, e.msg);
			p.kind = classify(sig);
			p.kindBy = "auto";
		}

		if (p.id)
			photos.update(p);
		else
			photos.insert(p);
		if (exif.keywords.length && onFileSubjects !is null && p.id)
			try
				onFileSubjects(p.id, exif.keywords);
			catch (Exception e)
				logDiagnostic("indexer: file keywords of %s: %s", c.path, e.msg);
		return true;
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
		if (owner.importCandidate(rootId, c))
		{
			imported++;
			if (imported % 200 == 0)
				owner.events.emit("library.changed", JSONValue.emptyObject);
		}
		else
			skipped++;
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
