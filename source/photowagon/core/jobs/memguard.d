/// The memory guard: a thread that reads this process's resident size every two
/// seconds and, past the limit, ends the process with SIGSEGV — on purpose, so a
/// core dump is written and the leak can be read instead of guessed at. The user's
/// rule: "se a app consumir mais de 1.5 GB ela precisa se suicidar, mas com
/// SIGSEGV pra podermos analisar o dump".
module photowagon.core.jobs.memguard;

import core.thread : Thread;
import core.time : seconds;

/// Resident set size of this process, in megabytes (0 when unknown).
long residentMb() nothrow
{
	version (linux)
	{
		import std.file : readText;
		import std.string : split;
		import std.conv : to;

		try
		{
			auto f = readText("/proc/self/statm").split();
			if (f.length >= 2)
				return f[1].to!long * 4096 / (1024 * 1024);
		}
		catch (Exception)
		{
		}
	}
	return 0;
}

/// Lets the kernel write a full core dump when we do die.
void allowCoreDumps() nothrow @nogc
{
	version (Posix)
	{
		import core.sys.posix.sys.resource : setrlimit, rlimit, RLIMIT_CORE, RLIM_INFINITY;

		rlimit r;
		r.rlim_cur = RLIM_INFINITY;
		r.rlim_max = RLIM_INFINITY;
		setrlimit(RLIMIT_CORE, &r);
	}
}

/// Forbids core dumps. On the phone a SIGSEGV (the guard's, or a real crash) otherwise
/// writes a multi-GB `core` into the app's data dir, which fills /data, makes Android
/// evict the thumbnail cache, and spirals into a re-decode + OOM loop.
void disableCoreDumps() nothrow @nogc
{
	version (Posix)
	{
		import core.sys.posix.sys.resource : setrlimit, rlimit, RLIMIT_CORE;

		rlimit r;
		r.rlim_cur = 0;
		r.rlim_max = 0;
		setrlimit(RLIMIT_CORE, &r);
	}
}

/// Starts the watchdog; `limitMb <= 0` disables it. `what` names the process in the log.
/// `dump` = true (the desktop) ends with a SIGSEGV core dump so a leak can be read; false
/// (the phone) exits cleanly with no dump — a giant core on a phone is never worth its cost.
void startMemoryGuard(long limitMb, string what = "photo-wagon", bool dump = true)
{
	if (limitMb <= 0)
		return;
	if (dump)
		allowCoreDumps();
	else
		disableCoreDumps();
	auto t = new Thread({
		for (;;)
		{
			Thread.sleep(2.seconds);
			immutable rss = residentMb();
			if (rss > limitMb)
			{
				if (dump)
					dieForTheDump(what, rss, limitMb);
				else
					exitCleanly(what, rss, limitMb);
			}
		}
	});
	t.name = "memguard";
	t.isDaemon = true;
	t.start();
}

/// Says why and exits without a core dump: for the phone, where the OS restarts the app
/// and the work resumes from the last saved state.
private void exitCleanly(string what, long rss, long limitMb) nothrow
{
	import core.stdc.stdio : fprintf, fflush, stderr;
	import core.sys.posix.unistd : _exit;
	import std.string : toStringz;

	try
	{
		import vibe.core.log : logError;
		logError("memory: %s is at %s MB, over the %s MB limit — exiting cleanly (no dump)", what, rss, limitMb);
	}
	catch (Exception)
	{
	}
	fprintf(stderr, "memory: %s at %ld MB (limit %ld MB): exiting cleanly, no core dump\n",
		what.toStringz, rss, limitMb);
	fflush(stderr);
	_exit(137);
}

/// Says why, flushes, and segfaults on purpose (the default action dumps core).
private void dieForTheDump(string what, long rss, long limitMb) nothrow
{
	import core.sys.posix.signal : raise, signal, SIGSEGV, SIG_DFL;
	import core.stdc.stdio : fprintf, fflush, stderr;
	import std.string : toStringz;

	try
	{
		import vibe.core.log : logError;
		logError("memory: %s is at %s MB, over the %s MB limit — aborting with SIGSEGV for the dump", what, rss, limitMb);
	}
	catch (Exception)
	{
	}
	fprintf(stderr, "memory: %s at %ld MB (limit %ld MB): aborting with SIGSEGV so the core dump can be analysed\n",
		what.toStringz, rss, limitMb);
	fflush(stderr);
	signal(SIGSEGV, SIG_DFL);   // not the phone's pretty-printing handler: the raw dump
	raise(SIGSEGV);
}

unittest
{
	assert(residentMb() > 0);   // a running test binary is resident
}
