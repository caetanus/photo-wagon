/// The core's background work, on a leash. Two rules, both for the person in
/// front of the window:
///
/// 1. One pass at a time. Indexing, kinds, faces, scenes, tags-into-files each
///    run as a *pass* over their pending photos; passes queue on a single lane
///    and run one after another, the most useful first (new photos before
///    classifiers). The memory of the core is then the memory of one pass, not
///    the sum of four.
/// 2. The user first. Every native operation — a decode, a model, a render —
///    takes one of a few permits (`--jobs N`, default 2), and a background pass
///    steps aside while a request from the UI or the phone is being answered.
///
/// Everything here runs on the core's event-loop thread, inside fibers.
module photowagon.core.jobs.scheduler;

import core.memory : GC;
import core.time : MonoTime, msecs, seconds;

import vibe.core.core : sleep;
import vibe.core.log : logInfo, logDiagnostic;
import vibe.core.sync : LocalManualEvent, createManualEvent;
import vibe.core.task : Task;

/// Lane priorities: lower runs first among the passes waiting.
enum Priority : int
{
	indexer = 0,   // the user is waiting to see the photos
	kinds = 1,     // what is a photograph decides what the rest looks at
	scenes = 2,
	faces = 3,
	fileTags = 4,
	ocr = 5,       // reads text in screenshots/memes/documents; after kinds + scenes decide what to read
}

final class Scheduler
{
	private int foregroundActive;
	private immutable int fixedPermits;   // --jobs N; 0 = by the machine's resources
	private int inUse;                    // native operations running
	private LocalManualEvent released;    // a permit came back
	private int cachedLimit;
	private MonoTime limitAt;
	private MonoTime relievedAt;   // the last memory hand-back when over budget (underBudget)

	private struct Waiter
	{
		int prio;
		long seq;
	}

	private Waiter[] waiting;
	private long seq;
	private bool laneBusy;
	private string laneName;
	private int lanePrio;
	private Task laneOwner;   // the fiber whose pass holds the lane (a borrower while lent)

	/// `heavyPermits` > 0 fixes how many native operations run at once (`--jobs N`); 0 = by
	/// the machine: up to half its cores (2..10), fewer when memory runs short.
	this(int heavyPermits)
	{
		fixedPermits = heavyPermits < 0 ? 0 : heavyPermits;
		released = createManualEvent();
	}

	/// How many native operations may run now: fixed, or from the cores and the memory
	/// available (re-read every 2 s): 5–10 on a roomy machine, 1–2 when memory is short.
	int limit() nothrow
	{
		if (fixedPermits > 0)
			return underBudget(fixedPermits);
		immutable now = MonoTime.currTime;
		if (cachedLimit > 0 && now - limitAt < 2.seconds)
			return cachedLimit;
		limitAt = now;
		import std.parallelism : totalCPUs;

		int base = totalCPUs / 2;
		base = base < 2 ? 2 : base > 10 ? 10 : base;
		immutable avail = memAvailableMb();
		int lim = base;
		if (avail > 0)
		{
			if (avail < 1536)
				lim = 1;
			else if (avail < 3072)
				lim = base < 2 ? base : 2;
			else if (avail < 6144)
				lim = base < 4 ? base : 4;
		}
		lim = underBudget(lim);
		cachedLimit = lim;
		return lim;
	}

	/// The PROCESS's budget over the machine's: the memory guard aborts this process past
	/// its limit, whatever the machine has free (7 GB free did not stop six photo decodes
	/// at once from carrying the app past its 1.5 GB guard). Background work keeps well
	/// clear of it — at most two at once past half of the budget, one past 65 %; past 80 %
	/// memory is also handed back (every 10 s at most). Never none: a limit of 0 would stall
	/// the lane, the photos queued behind it and the shutdown for as long as memory stays up
	/// — and what stays up with one at a time is not background work. A user's request
	/// still goes: acquire(true) gets one past the limit.
	private int underBudget(int lim) nothrow
	{
		import core.atomic : atomicLoad;
		import photowagon.core.jobs.memguard : guardLimitMb, lastResidentMb, residentMb, relieveMemory;

		immutable budget = atomicLoad(guardLimitMb);
		if (budget <= 0)
			return lim;
		immutable last = atomicLoad(lastResidentMb);
		immutable rss = last > 0 ? last : residentMb();
		if (rss >= budget * 80 / 100)
		{
			immutable now = MonoTime.currTime;
			if (now - relievedAt >= 10.seconds)
			{
				relievedAt = now;
				relieveMemory();
			}
		}
		if (rss >= budget * 65 / 100)
			return lim < 1 ? lim : 1;
		if (rss >= budget * 50 / 100)
			return lim < 2 ? lim : 2;
		return lim;
	}

	private void acquire(bool user)
	{
		// the user's own request takes one past the limit rather than wait behind background work
		auto c = released.emitCount;
		while (inUse >= (user ? limit() + 1 : limit()))   // (re-read: memory may have freed, or gone)
			c = released.wait(250.msecs, c);
		inUse++;
	}

	private void release() nothrow
	{
		inUse--;
		released.emit();
	}

	// ---- the user's requests -------------------------------------------------------

	/// Marks a request from the UI or the phone as in flight; background work yields to it.
	void foregroundBegin() nothrow
	{
		foregroundActive++;
	}

	void foregroundEnd() nothrow
	{
		if (foregroundActive > 0)
			foregroundActive--;
	}

	/// A native operation for the user's own request: takes a permit right away.
	T foreground(T)(scope T delegate() op)
	{
		foregroundBegin();
		scope (exit)
			foregroundEnd();
		acquire(true);
		scope (exit)
			release();
		return op();
	}

	// ---- background passes ---------------------------------------------------------

	/// A native operation of a background pass: waits (up to 2 s) while the user's
	/// requests are being answered, then takes a permit.
	T background(T)(scope T delegate() op)
	{
		auto t0 = MonoTime.currTime;
		while (foregroundActive > 0 && MonoTime.currTime - t0 < 2.seconds)
			sleep(10.msecs);
		acquire(false);
		scope (exit)
			release();
		return op();
	}

	/// Runs `body_` as the lane's pass once its turn comes: no other pass runs meanwhile,
	/// and among those waiting the lowest `prio` goes first. Must be called from a fiber.
	void pass(int prio, string name, scope void delegate() body_)
	{
		immutable mySeq = ++seq;
		waiting ~= Waiter(prio, mySeq);
		scope (exit)
			dropWaiter(mySeq);
		auto queuedAt = MonoTime.currTime;
		bool said;
		while (laneBusy || !isNext(mySeq))
		{
			if (!said && MonoTime.currTime - queuedAt > 2.seconds)
			{
				said = true;
				logInfo("jobs: %s waits for %s", name, laneName);
			}
			sleep(50.msecs);
		}
		dropWaiter(mySeq);
		laneBusy = true;
		laneName = name;
		lanePrio = prio;
		auto me = Task.getThis();
		laneOwner = me;
		auto started = MonoTime.currTime;
		logDiagnostic("jobs: %s starts (%s queued)", name, waiting.length);
		scope (exit)
		{
			// only if this pass still holds it: interrupted while lending, a borrower does
			if (laneOwner == me)
			{
				laneBusy = false;
				laneName = null;
				laneOwner = Task.init;
				// a pass leaves a heap behind it (JSON, decoded pixels, blobs): give it back —
				// after a real pass only. One received photo is a pass of its own, and a full
				// collection of the whole heap per photo, on the event-loop thread, stalled
				// everything else during a sync (the phone's link went silent and dropped).
				if (MonoTime.currTime - started >= 1.seconds)
				{
					GC.collect();
					GC.minimize();
				}
				logDiagnostic("jobs: %s done in %.1fs", name, (MonoTime.currTime - started).total!"msecs" / 1000.0);
			}
		}
		body_();
	}

	/// Called by a long pass between two of its photos: when a more urgent pass waits (a
	/// photo that just arrived — the user wants to SEE it; enrichment can wait), the lane
	/// is lent to it and this pass resumes after, ahead of passes of its own rank. Still
	/// one pass at a time. A no-op outside a pass or when nothing more urgent waits.
	void yieldLane()
	{
		auto me = Task.getThis();
		if (!laneBusy || laneOwner != me)
			return;   // not inside this fiber's own pass
		bool urgent;
		foreach (w; waiting)
			if (w.prio < lanePrio)
				urgent = true;
		if (!urgent)
			return;
		immutable myPrio = lanePrio;
		immutable myName = laneName;
		immutable mySeq = -(++seq);   // negative: first among its own rank when the lane frees
		laneBusy = false;
		laneName = null;
		laneOwner = Task.init;
		waiting ~= Waiter(myPrio, mySeq);
		scope (exit)
			dropWaiter(mySeq);
		logDiagnostic("jobs: %s steps aside", myName);
		while (laneBusy || !isNext(mySeq))
			sleep(20.msecs);
		laneBusy = true;
		laneName = myName;
		lanePrio = myPrio;
		laneOwner = me;
	}

	private bool isNext(long mySeq) const
	{
		int bestPrio = int.max;
		long bestSeq = long.max;
		foreach (w; waiting)
			if (w.prio < bestPrio || (w.prio == bestPrio && w.seq < bestSeq))
			{
				bestPrio = w.prio;
				bestSeq = w.seq;
			}
		return bestSeq == mySeq;
	}

	private void dropWaiter(long mySeq)
	{
		foreach (i, w; waiting)
			if (w.seq == mySeq)
			{
				waiting = waiting[0 .. i] ~ waiting[i + 1 .. $];
				return;
			}
	}

	/// For the status line: the pass running, and how many wait.
	string current() const
	{
		return laneBusy ? laneName : null;
	}

	size_t queued() const
	{
		return waiting.length;
	}

	int heavyPermits() nothrow
	{
		return limit();
	}

	/// Works through `items` a few at once: `fetch` — the heavy part, a model or a decode
	/// through `background` — runs for up to `limit()` items at a time, each on a fiber of its
	/// own, and `use` gets the results on the calling fiber IN ORDER (so clustering and tags
	/// come out as if one at a time). `use` gets the exception `fetch` threw, if any, and
	/// returning false stops: nothing more is started, and everything started is waited for
	/// before this returns (also when the caller is interrupted).
	void ordered(T, R)(const(T)[] items, R delegate(T) fetch, bool delegate(T, R, Exception) use)
	{
		import vibe.core.core : runTask;

		static struct Slot
		{
			R value;
			Exception err;
			bool done;
			Task task;
		}

		// only the window in flight is held (not a slot per item: a pass may have a million)
		Slot*[size_t] slots;
		auto ev = createManualEvent();
		size_t next;   // the next item to start
		scope (exit)
			foreach (sl; slots.byValue)
				sl.task.joinUninterruptible();
		foreach (i; 0 .. items.length)
		{
			while (next < items.length && next - i < limit())
			{
				auto sl = new Slot;
				slots[next] = sl;
				sl.task = runTask((Slot* sl, size_t k) nothrow {
					try
						sl.value = fetch(items[k]);
					catch (Exception e)
						sl.err = e;
					sl.done = true;
					ev.emit();
				}, sl, next);
				next++;
			}
			auto sl = slots[i];
			auto c = ev.emitCount;
			while (!sl.done)
				c = ev.wait(c);
			slots.remove(i);
			auto v = sl.value;
			auto e = sl.err;
			if (!use(items[i], v, e))
				break;
		}
	}
}

private Scheduler theJobs;

/// The core's scheduler (one per core thread). Services take it from here, so a
/// service built in a unit test gets a default one.
Scheduler jobs()
{
	if (theJobs is null)
		theJobs = new Scheduler(2);
	return theJobs;
}

void installScheduler(Scheduler s)
{
	theJobs = s;
}

unittest
{
	// passes run one at a time, and the lowest priority number goes first
	import vibe.core.core : runTask, runEventLoop, exitEventLoop;

	auto s = new Scheduler(1);
	string[] order;
	int inside;
	int maxInside;
	void take(string name, int prio, int ms)
	{
		s.pass(prio, name, {
			inside++;
			if (inside > maxInside)
				maxInside = inside;
			order ~= name;
			sleep(ms.msecs);
			inside--;
		});
	}

	void safe(void delegate() f) nothrow
	{
		try
			f();
		catch (Exception)
		{
		}
	}

	runTask(() nothrow {
		safe({
			auto a = runTask(() nothrow { safe({ take("first", Priority.scenes, 150); }); });
			sleep(20.msecs);
			auto b = runTask(() nothrow { safe({ take("faces", Priority.faces, 10); }); });
			auto c = runTask(() nothrow { safe({ take("indexer", Priority.indexer, 10); }); });
			auto d = runTask(() nothrow { safe({ take("kinds", Priority.kinds, 10); }); });
			a.join();
			b.join();
			c.join();
			d.join();
			exitEventLoop();
		});
	});
	runEventLoop();
	assert(maxInside == 1);
	assert(order == ["first", "indexer", "kinds", "faces"], order.to!string);
}

version (unittest) import std.conv : to;

unittest
{
	// a long pass lends the lane between its photos to a more urgent one (a photo that just
	// arrived), then resumes before a waiting pass of its own rank; still one at a time
	import vibe.core.core : runTask, runEventLoop, exitEventLoop;

	auto s = new Scheduler(1);
	string[] order;
	int inside, maxInside;
	void enter(string what)
	{
		inside++;
		if (inside > maxInside)
			maxInside = inside;
		order ~= what;
	}

	void safe(void delegate() f) nothrow
	{
		try
			f();
		catch (Exception)
		{
		}
	}

	runTask(() nothrow {
		safe({
			auto long_ = runTask(() nothrow {
				safe({
					s.pass(Priority.faces, "faces", {
						foreach (i; 0 .. 3)
						{
							s.yieldLane();
							enter("faces" ~ i.to!string);
							sleep(40.msecs);
							inside--;
						}
					});
				});
			});
			sleep(10.msecs);   // faces0 runs
			auto peer = runTask(() nothrow {
				safe({ s.pass(Priority.faces, "faces-b", { enter("faces-b"); inside--; }); });
			});
			auto imp = runTask(() nothrow {
				safe({ s.pass(Priority.indexer, "import", { enter("import"); sleep(5.msecs); inside--; }); });
			});
			long_.join();
			peer.join();
			imp.join();
			s.yieldLane();   // outside a pass: nothing
			exitEventLoop();
		});
	});
	runEventLoop();
	assert(maxInside == 1);
	assert(order == ["faces0", "import", "faces1", "faces2", "faces-b"], order.to!string);
}

/// MemAvailable in MB (0 when unknown).
long memAvailableMb() nothrow
{
	return meminfoMb("MemAvailable:");
}

/// MemTotal in MB (0 when unknown).
long memTotalMb() nothrow
{
	return meminfoMb("MemTotal:");
}

private long meminfoMb(string key) nothrow
{
	version (linux)
	{
		try
		{
			import std.stdio : File;
			import std.algorithm.searching : startsWith;
			import std.string : split;
			import std.conv : to;

			foreach (line; File("/proc/meminfo").byLine)
				if (line.startsWith(key))
					return line.split[1].to!long / 1024;
		}
		catch (Exception)
		{
		}
	}
	return 0;
}

unittest
{
	auto s = new Scheduler(0);
	immutable l = s.limit();
	assert(l >= 1 && l <= 10);
	assert(new Scheduler(3).limit() == 3);
}

unittest
{
	import vibe.core.core : runTask, exitEventLoop, runEventLoop, sleep;
	import core.time : msecs;
	import std.conv : to;

	// several at once, results in order, a stop waits for what was started
	auto s = new Scheduler(3);
	int inside, maxInside;
	int[] got;
	runTask(() nothrow {
		try
		{
			s.ordered!(int, int)([1, 2, 3, 4, 5, 6, 7], (int x) {
				inside++;
				if (inside > maxInside)
					maxInside = inside;
				sleep(((8 - x) * 3).msecs);   // later items finish first
				inside--;
				return x * 10;
			}, (int x, int r, Exception e) {
				got ~= r;
				return x < 5;
			});
			assert(inside == 0);
		}
		catch (Exception e)
			assert(false, e.msg);
		exitEventLoop();
	});
	runEventLoop();
	assert(got == [10, 20, 30, 40, 50], got.to!string);
	assert(maxInside == 3);
}

unittest
{
	// background work sizes itself against the PROCESS budget (the memory guard's limit),
	// not only the machine: 6 permits shrink to 2 and 1 as the process nears its limit,
	// and never to 0 (that would stall the lane and ordered())
	import core.atomic : atomicLoad, atomicStore;
	import photowagon.core.jobs.memguard : guardLimitMb, lastResidentMb;

	immutable savedLimit = atomicLoad(guardLimitMb), savedRss = atomicLoad(lastResidentMb);
	scope (exit)
	{
		atomicStore(guardLimitMb, savedLimit);
		atomicStore(lastResidentMb, savedRss);
	}
	auto s = new Scheduler(6);
	atomicStore(guardLimitMb, 1000L);
	atomicStore(lastResidentMb, 400L);
	assert(s.limit() == 6);
	atomicStore(lastResidentMb, 550L);
	assert(s.limit() == 2);
	atomicStore(lastResidentMb, 700L);
	assert(s.limit() == 1);
	atomicStore(lastResidentMb, 850L);
	assert(s.limit() == 1);   // memory handed back, still one at a time: never none
	atomicStore(guardLimitMb, 0L);   // no guard: the machine alone decides
	assert(s.limit() == 6);
}
