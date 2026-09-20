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

/// VmRSS from /proc/self/status, in MB (exact kB, not statm's page-scaled guess).
long vmRssMb() nothrow
{
	version (linux)
	{
		try
		{
			import std.file : readText;
			import std.string : splitLines, split, startsWith;
			import std.conv : to;

			foreach (line; readText("/proc/self/status").splitLines)
				if (line.startsWith("VmRSS:"))
				{
					auto p = line.split();
					if (p.length >= 2)
						return p[1].to!long / 1024;
				}
		}
		catch (Exception)
		{
		}
	}
	return 0;
}

// glibc malloc introspection: uordblks = in-use (C-side), fordblks = free-but-held-in-arena.
// Splits a real C-side leak (uordblks climbs with RSS) from arena retention (fordblks large).
private struct MallInfo2
{
	size_t arena, ordblks, smblks, hblks, hblkhd, usmblks, fsmblks, uordblks, fordblks, keepcost;
}

// glibc-only introspection; Android's bionic exports neither mallinfo2 nor malloc_trim,
// so the C-heap probe (and these declarations) are compiled out there — otherwise the
// phone's libphotowagon.so fails to dlopen with "cannot locate symbol mallinfo2".
version (Android) {} else
{
    private extern (C) MallInfo2 mallinfo2() @nogc nothrow;
    private extern (C) int malloc_trim(size_t pad) @nogc nothrow;
}

/// Debug (PW_MEMSAMPLE=1): every guard tick log VmRSS + GC used/free + glibc c_used/c_free
/// (texture); every ~30s the decisive experiment — GC.collect x2 then GC.minimize() (D heap),
/// then malloc_trim(0) (C heap), each with before/after RSS. Reads: gc_used climbs = D leak;
/// c_used (uordblks) climbs = C leak (unfreed vips/exif/sqlite); c_free large / trim_drop big
/// = arena retention (config fix); nothing drops = fragmentation/mmap.
private void memSample(long tick) nothrow
{
	try
	{
		import std.process : environment;
		if (environment.get("PW_MEMSAMPLE", "").length == 0)
			return;
		import core.memory : GC;
		import std.stdio : stderr;

		auto s = GC.stats;
		version (Android)
		{
			// bionic has no mallinfo2/malloc_trim: the D heap only.
			stderr.writefln("MEMSAMPLE t=%d rss=%dMB gc_used=%dMB gc_free=%dMB",
				tick, vmRssMb(), cast(long)(s.usedSize / 1048576), cast(long)(s.freeSize / 1048576));
		}
		else
		{
			auto mi = mallinfo2();
			stderr.writefln(
				"MEMSAMPLE t=%d rss=%dMB gc_used=%dMB gc_free=%dMB c_used=%dMB c_free=%dMB c_mmap=%dMB",
				tick, vmRssMb(), cast(long)(s.usedSize / 1048576), cast(long)(s.freeSize / 1048576),
				cast(long)(mi.uordblks / 1048576), cast(long)(mi.fordblks / 1048576),
				cast(long)(mi.hblkhd / 1048576));
			if (tick > 0 && tick % 15 == 0)
			{
				GC.collect();
				GC.collect();
				auto sc = GC.stats;
				immutable rssPostCollect = vmRssMb();
				GC.minimize();
				immutable rssPostMin = vmRssMb();
				malloc_trim(0);
				immutable rssPostTrim = vmRssMb();
				auto mi2 = mallinfo2();
				stderr.writefln(
					"MEMPROBE t=%d post_collect rss=%dMB gc_used=%dMB | post_minimize rss=%dMB | post_trim rss=%dMB trim_drop=%dMB | c_used=%dMB c_free=%dMB",
					tick, rssPostCollect, cast(long)(sc.usedSize / 1048576), rssPostMin,
					rssPostTrim, rssPostMin - rssPostTrim,
					cast(long)(mi2.uordblks / 1048576), cast(long)(mi2.fordblks / 1048576));
			}
		}
		stderr.flush();
	}
	catch (Exception)
	{
	}
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
		long tick = 0;
		for (;;)
		{
			Thread.sleep(2.seconds);
			memSample(tick++);
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
