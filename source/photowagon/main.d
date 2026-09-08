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
	Config cfg;
	try
		cfg = parseArgs(args);
	catch (Exception e)
	{
		stderr.writeln(e.msg);
		return 2;
	}
	setLogLevel(cfg.verbose ? LogLevel.diagnostic : LogLevel.info);
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
