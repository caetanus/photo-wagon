/// Stacks: "nearly identical photos of the same subject taken together within a short time
/// frame" (Google Photos' words, support.google.com/photos/answer/14169846) shown as one tile
/// with a count. Photographs are walked in time order and each is compared with the one
/// before it: taken within `maxGapSec` of it and with CLIP embeddings at least `minCosine`
/// alike, it joins that one's stack. Only two embeddings are ever held (vectors stay in
/// sqlite-vec). A stack's id is its smallest photo id, so it does not change as photos come
/// and go at its ends; a photo alone has none (NULL).
module photowagon.core.library.stacks;

import std.json;

import vibe.core.core : yield;
import vibe.core.log : logInfo, logWarn;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.events : Events;
import photowagon.core.jobs.scheduler : jobs, Priority;

enum maxGapSec = 60;      // a burst, not an afternoon
enum minCosine = 0.93;    // near-identical (the Tools' "similar photos" default is 0.95)

final class StackService
{
	private Database db;
	private Events events;
	private FiberGroup fibers;
	private bool running, again, closed;

	this(Database db, Events events)
	{
		this.db = db;
		this.events = events;
		fibers = new FiberGroup((Exception e) nothrow {
			try
				logWarn("stacks: job failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	void close() nothrow
	{
		closed = true;
		fibers.stopAll();
	}

	/// (Re)computes the stacks in the background; a call during a pass queues one more.
	void start()
	{
		if (closed)
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
				jobs.pass(Priority.ocr, "stacking similar photos", &run);
			}
			while (again);
		});
	}

	private void run()
	{
		import core.time : MonoTime;

		immutable t0 = MonoTime.currTime;
		// photo id → its stack (the run's smallest id), for photos in a stack of 2+
		long[long] stackOf;
		long[] run_;
		void closeRun()
		{
			if (run_.length > 1)
			{
				long root = run_[0];
				foreach (id; run_)
					if (id < root)
						root = id;
				foreach (id; run_)
					stackOf[id] = root;
			}
			run_ = null;
		}

		float[] prev;
		long prevTs;
		size_t n;
		{
			auto s = db.prepare(`SELECT p.id, p.taken_ts, v.embedding FROM photos p
				JOIN photo_vec v ON v.photo_id = p.id
				WHERE p.kind = 'photo' AND p.path IS NOT NULL
				ORDER BY p.taken_ts, p.id`);
			while (s.step())
			{
				immutable id = s.getLong(0), ts = s.getLong(1);
				auto blob = s.getBlob(2);
				auto emb = (cast(const(float)[]) blob).dup;
				immutable joins = prev.length == emb.length && ts - prevTs <= maxGapSec && ts >= prevTs
					&& cosine(prev, emb) >= minCosine;
				if (!joins)
					closeRun();
				run_ ~= id;
				prev = emb;
				prevTs = ts;
				if (++n % 256 == 0)
					yield();
			}
			closeRun();
		}

		// write only what changed: rows whose stack differs from the one computed
		long[long] cur;
		{
			auto s = db.prepare("SELECT id, stack_id FROM photos WHERE stack_id IS NOT NULL");
			while (s.step())
				cur[s.getLong(0)] = s.getLong(1);
		}
		long[] ids, roots;   // roots[i] 0 = no stack
		foreach (id, was; cur)
		{
			auto want = id in stackOf;
			if (want is null || *want != was)
			{
				ids ~= id;
				roots ~= want is null ? 0 : *want;
			}
		}
		foreach (id, root; stackOf)
			if (id !in cur)
			{
				ids ~= id;
				roots ~= root;
			}
		if (ids.length)
		{
			db.exec("BEGIN");
			scope (failure)
				db.exec("ROLLBACK");
			auto u = db.prepare("UPDATE photos SET stack_id = ? WHERE id = ?");
			foreach (i, id; ids)
			{
				if (roots[i] == 0)
					u.bindNull(1);
				else
					u.bind(1, roots[i]);
				u.bind(2, id);
				u.step();
				u.reset();
			}
			db.exec("COMMIT");
			events.emit("library.changed", JSONValue.emptyObject);
		}
		logInfo("stacks: %s photos looked at, %s changed in %s", n, ids.length, MonoTime.currTime - t0);
	}
}

/// Cosine similarity of two vectors of the same length.
double cosine(const(float)[] a, const(float)[] b) pure nothrow @nogc
{
	import std.math : sqrt;

	double dot = 0, na = 0, nb = 0;
	foreach (i; 0 .. a.length)
	{
		dot += a[i] * b[i];
		na += a[i] * a[i];
		nb += b[i] * b[i];
	}
	return na > 0 && nb > 0 ? dot / (sqrt(na) * sqrt(nb)) : 0;
}

unittest
{
	assert(cosine([1, 0], [1, 0]) > 0.999);
	assert(cosine([1, 0], [0, 1]) < 0.001);
}
