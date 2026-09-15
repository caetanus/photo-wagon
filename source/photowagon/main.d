/// photo-wagon: the UI on the main thread with the core on a second thread,
/// or — with --headless or a build without the UI — the core alone, serving
/// the JSON-lines protocol on loopback TCP.
module photowagon.main;

import std.stdio : stderr;

import vibe.core.log : setLogLevel, LogLevel;

import photowagon.core.config : Config, parseArgs;
import photowagon.core.daemon : runCore, CoreThread;
import photowagon.core.ipc.link : InProcessLink;
import photowagon.core.metadata.exif : initExif;
import photowagon.core.thumbs.vips : initVips;

int main(string[] args)
{
	installQuitHandler();   // SIGTERM / SIGINT end the process: vibe's own handlers on the core thread only stop its loop
	Config cfg;
	try
		cfg = parseArgs(args);
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 2;
	}
	setLogLevel(cfg.verbose ? LogLevel.diagnostic : LogLevel.info);
	if (cfg.exitWithParent)
	{
		// a core started by a test or a script must not outlive it: a dozen forgotten
		// headless cores, each holding a model, once ate 15 GB
		version (linux)
		{
			import core.sys.linux.sys.prctl : prctl, PR_SET_PDEATHSIG;
			import core.sys.posix.signal : SIGTERM;

			prctl(PR_SET_PDEATHSIG, SIGTERM, 0, 0, 0);
		}
	}
	if (cfg.visionWorker)
	{
		// the OpenCV child: the models' gigabyte lives here, for one pass
		import photowagon.core.vision.worker : runVisionWorker, VisionModels;
		import photowagon.core.jobs.memguard : startMemoryGuard;

		startMemoryGuard(4096, "vision-worker");
		return runVisionWorker(VisionModels(cfg.visionModels[0], cfg.visionModels[1], cfg.visionModels[2]));
	}
	{
		import photowagon.core.jobs.memguard : startMemoryGuard;
		startMemoryGuard(cfg.memoryLimitMb);
	}
	if (cfg.p2pRelayMode)
	{
		// a pure circuit-relay node for NAT traversal — no library, no models, no vips
		import photowagon.core.p2p.relaynode : runRelay;

		return runRelay(cfg);
	}
	initVips(args[0]);
	initExif();

	version (WithUi)
	{
		if (!cfg.headless)
		{
			import photowagon.ui.app : runUi;

			// vibe-core installed handlers that only make sense for a thread
			// running its event loop; the UI thread wants the default (die).
			import core.sys.posix.signal : signal, SIGINT, SIGTERM, SIG_DFL;

			signal(SIGINT, SIG_DFL);
			signal(SIGTERM, SIG_DFL);

			auto link = new InProcessLink;
			auto core = new CoreThread(cfg, link);
			core.start();
			scope (exit)
				core.stop();
			return runUi(cfg, link);
		}
	}
	else
	{
		if (!cfg.headless)
		{
			stderr.writeln("this build has no UI; running headless (--serve)");
			cfg.headless = true;
			cfg.serve = true;
		}
	}
	return runCore(cfg);
}

/// SIGTERM / SIGINT end the process. vibe-core installs handlers for both on the
/// thread that runs its event loop (the core thread), which only stop that loop and
/// would leave the Qt window running after a `kill`. Ours is installed later and wins.
void installQuitHandler() nothrow @nogc
{
	version (Posix)
	{
		import core.sys.posix.signal : sigaction, sigaction_t, SIGTERM, SIGINT;
		import core.sys.posix.unistd : _exit;

		extern (C) static void quit(int) nothrow @nogc { _exit(0); }
		sigaction_t sa;
		sa.sa_handler = &quit;
		sigaction(SIGTERM, &sa, null);
		sigaction(SIGINT, &sa, null);
	}
}
