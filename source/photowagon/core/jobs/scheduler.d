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
		auto started = MonoTime.currTime;
		logDiagnostic("jobs: %s starts (%s queued)", name, waiting.length);
		scope (exit)
		{
			laneBusy = false;
			laneName = null;
			// a pass leaves a heap behind it (JSON, decoded pixels, blobs): give it back
			GC.collect();
			GC.minimize();
			logDiagnostic("jobs: %s done in %.1fs", name, (MonoTime.currTime - started).total!"msecs" / 1000.0);
		}
		body_();
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
