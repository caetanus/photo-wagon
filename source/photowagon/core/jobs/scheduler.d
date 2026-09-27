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
import vibe.core.sync : LocalTaskSemaphore;
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
	private LocalTaskSemaphore permits;
	private int foregroundActive;
	private immutable int permitCount;

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

	this(int heavyPermits)
	{
		permitCount = heavyPermits < 1 ? 1 : heavyPermits;
		permits = new LocalTaskSemaphore(permitCount);
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
		permits.lock();
		scope (exit)
			permits.unlock();
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
		permits.lock();
		scope (exit)
			permits.unlock();
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

	int heavyPermits() const
	{
		return permitCount;
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
