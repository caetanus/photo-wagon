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
	// the change log as far as the last pass saw it: past it, only the time neighbourhoods
	// of what changed are walked again (an arriving photo re-stacks its burst, not the
	// library). 0 = walk it all.
	private long seenChange;

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
		// read before the walk: what changes during it is seen by the next pass
		immutable change = scalar("SELECT COALESCE(MAX(seq), 0) FROM photo_changes");
		scope (success)
			seenChange = change;
		if (seenChange == 0 || !incremental())
			walk(long.min, long.max);
	}

	private long scalar(string sql)
	{
		auto s = db.prepare(sql);
		return s.step() ? s.getLong(0) : 0;
	}

	// photographs that can be in a stack (an embedding, a file)
	private enum stackable = `p.kind = 'photo' AND p.path IS NOT NULL
		AND EXISTS (SELECT 1 FROM photo_clip c WHERE c.photo_id = p.id AND c.ok = 1)`;

	/// Re-walks only the stretches of time around what changed since the last pass. A stack
	/// never spans a gap longer than `maxGapSec` between neighbouring photographs, so the
	/// stretch around a photo — out to such a gap on each side — can be walked on its own.
	/// False when that cannot be told (the log was trimmed past it): the caller walks everything.
	private bool incremental()
	{
		long[] ids, times;
		bool[long] seen;
		{
			// (a move in time or a deletion also left where the photo was: that stretch lost it)
			auto s = db.prepare("SELECT photo_id, old_ts FROM photo_changes WHERE seq > ?");
			s.bind(1, seenChange);
			while (s.step())
			{
				if (s.getLong(0) !in seen)
				{
					seen[s.getLong(0)] = true;
					ids ~= s.getLong(0);
				}
				if (!s.isNull(1))
					times ~= s.getLong(1);
			}
			if (scalar("SELECT COALESCE(MIN(seq), 0) FROM photo_changes") > seenChange + 1)
				return false;   // the log was trimmed past what we saw
		}
		if (ids.length == 0)
			return true;
		if (ids.length > 5000)
			return false;   // most of the library: one walk is cheaper
		// the times to re-walk around: each changed photo, and the stack it was in (a photo
		// that moved in time, stopped being a photograph or went, leaves its old stack behind)
		bool[long] stacks;
		auto get = db.prepare("SELECT taken_ts, stack_id FROM photos WHERE id = ?");
		auto mates = db.prepare("SELECT taken_ts FROM photos WHERE stack_id = ?");
		foreach (id; ids)
		{
			get.reset();
			get.bind(1, id);
			immutable here = get.step();   // (a deleted one: its old time is above, its mates below)
			if (here)
				times ~= get.getLong(0);
			foreach (sid; [id, here && !get.isNull(1) ? get.getLong(1) : 0])
				if (sid && sid !in stacks)   // (each stack once, however many of it changed)
				{
					stacks[sid] = true;
					mates.reset();
					mates.bind(1, sid);
					while (mates.step())
						times ~= mates.getLong(0);
				}
		}
		import std.algorithm : sort, uniq;
		import std.array : array;

		times = times.sort.uniq.array;
		auto before = db.prepare("SELECT p.taken_ts FROM photos p WHERE " ~ stackable
			~ " AND p.taken_ts < ? ORDER BY p.taken_ts DESC, p.id DESC");
		auto after = db.prepare("SELECT p.taken_ts FROM photos p WHERE " ~ stackable
			~ " AND p.taken_ts > ? ORDER BY p.taken_ts, p.id");
		// out from `t` to the first gap longer than a stack allows
		long edge(ref typeof(before) q, long t, int dir)
		{
			q.reset();
			q.bind(1, t);
			long cur = t;
			while (q.step())
			{
				immutable ts = q.getLong(0);
				if ((ts - cur) * dir > maxGapSec)
					break;
				cur = ts;
			}
			return cur;
		}

		long lo = long.max, hi = long.min;
		foreach (t; times)
		{
			if (lo != long.max && t <= hi)
				continue;   // inside the stretch just found
			if (lo != long.max)
				walk(lo, hi);
			lo = edge(before, t, -1);
			hi = edge(after, t, 1);
		}
		if (lo != long.max)
			walk(lo, hi);
		return true;
	}

	/// Stacks the photographs taken in [lo, hi] afresh and writes what changed.
	private void walk(long lo, long hi)
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
				WHERE p.kind = 'photo' AND p.path IS NOT NULL AND p.taken_ts BETWEEN ? AND ?
				ORDER BY p.taken_ts, p.id`);
			s.bind(1, lo).bind(2, hi);
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
			auto s = db.prepare("SELECT id, stack_id FROM photos WHERE stack_id IS NOT NULL AND taken_ts BETWEEN ? AND ?");
			s.bind(1, lo).bind(2, hi);
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
		if (n > 1000 || ids.length)
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

unittest
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	float[512] e = 0, f = 0;
	e[0] = 1;
	f[1] = 1;
	void add(long id, long ts, const float[512] emb)
	{
		auto p = db.prepare("INSERT INTO photos (id, hash, path, taken_ts, taken_at, kind) VALUES (?, ?, ?, ?, 'x', 'photo')");
		p.bind(1, id).bind(2, "h" ~ cast(char)('0' + id)).bind(3, "/p" ~ cast(char)('0' + id)).bind(4, ts);
		p.run();
		auto v = db.prepare("INSERT INTO photo_vec (photo_id, embedding) VALUES (?, ?)");
		v.bind(1, id).bind(2, cast(const(ubyte)[]) emb[]);
		v.run();
		auto c = db.prepare("INSERT OR REPLACE INTO photo_clip (photo_id, version, ok) VALUES (?, 1, 1)");
		c.bind(1, id);
		c.run();
	}

	long stackOf(long id)
	{
		auto s = db.prepare("SELECT stack_id FROM photos WHERE id = ?");
		s.bind(1, id);
		s.step();
		return s.isNull(0) ? 0 : s.getLong(0);
	}

	auto st = new StackService(db, new Events);
	add(1, 1000, e);
	add(2, 1010, e);
	add(3, 5000, e);
	add(5, 5030, f);   // near in time, another subject
	st.run();          // the first pass walks everything
	assert(stackOf(1) == 1 && stackOf(2) == 1 && stackOf(3) == 0 && stackOf(5) == 0);
	assert(st.seenChange > 0);

	add(4, 5020, e);   // an arriving photo joins the lone one: only its stretch is walked
	st.run();
	assert(stackOf(3) == 3 && stackOf(4) == 3 && stackOf(1) == 1 && stackOf(5) == 0);

	db.exec("UPDATE photos SET taken_ts = 9000 WHERE id = 2");   // moved away: its stack goes
	st.run();
	assert(stackOf(1) == 0 && stackOf(2) == 0 && stackOf(3) == 3);

	db.exec("UPDATE photos SET kind = 'screenshot' WHERE id = 4");   // no longer a photograph
	st.run();
	assert(stackOf(3) == 0 && stackOf(4) == 0);

	db.exec("UPDATE photos SET kind = 'photo' WHERE id = 4");
	st.run();
	assert(stackOf(3) == 3 && stackOf(4) == 3);
	db.exec("DELETE FROM photos WHERE id = 4");   // a deletion: its stretch again
	st.run();
	assert(stackOf(3) == 0);

	// a photo moved OUT from between two alike ones: they are neighbours now
	add(6, 20_000, e);
	add(7, 20_010, f);
	add(8, 20_020, e);
	st.run();
	assert(stackOf(6) == 0 && stackOf(8) == 0);
	db.exec("UPDATE photos SET taken_ts = 30_000 WHERE id = 7");
	st.run();
	assert(stackOf(6) == 6 && stackOf(8) == 6);

	// an older photo embedded late (its id below everything seen) still joins
	auto p = db.prepare("INSERT INTO photos (id, hash, path, taken_ts, taken_at, kind) VALUES (9, 'h9', '/p9', 3005, 'x', 'photo')");
	p.run();
	add(11, 3010, e);
	st.run();
	assert(stackOf(11) == 0);   // 9 has no embedding yet
	auto v = db.prepare("INSERT INTO photo_vec (photo_id, embedding) VALUES (9, ?)");
	v.bind(1, cast(const(ubyte)[]) e[]);
	v.run();
	db.exec("INSERT INTO photo_clip (photo_id, version, ok) VALUES (9, 1, 1)");
	st.run();
	assert(stackOf(9) == 9 && stackOf(11) == 9);
}
