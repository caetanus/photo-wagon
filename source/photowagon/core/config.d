/// Where the daemon keeps its data and how it was asked to run.
module photowagon.core.config;

import std.path : buildPath, expandTilde;
import std.process : environment;

struct Config
{
	/// library.db, store/, identity.seed
	string dataDir;
	/// daemon.port lives here (tmpfs when XDG_RUNTIME_DIR is set)
	string runtimeDir;
	string ipcAddress = "127.0.0.1";
	/// 0 = let the kernel pick; the chosen port is written to the port file
	ushort ipcPort = 0;
	/// no UI: run the core on the main thread (implies --serve)
	bool headless = false;
	/// expose the JSON-lines protocol on loopback TCP and write the port file
	bool serve = false;
	bool p2p = true;
	string[] p2pListen;
	/// concurrent import pipelines (each hashes, reads EXIF and thumbnails one file)
	int workers = 4;
	/// longest edge of a thumbnail in pixels
	int thumbSize = 512;
	bool verbose = false;

	string dbPath() const
	{
		return buildPath(dataDir, "library.db");
	}

	string storeDir() const
	{
		return buildPath(dataDir, "store");
	}

	string identityPath() const
	{
		return buildPath(dataDir, "identity.seed");
	}

	string portFile() const
	{
		return buildPath(runtimeDir, "daemon.port");
	}
}

Config defaultConfig()
{
	Config c;
	immutable home = environment.get("HOME", "~".expandTilde);
	immutable dataHome = environment.get("XDG_DATA_HOME", buildPath(home, ".local", "share"));
	c.dataDir = buildPath(dataHome, "photowagon");
	immutable runtime = environment.get("XDG_RUNTIME_DIR", "");
	c.runtimeDir = runtime.length ? buildPath(runtime, "photowagon") : c.dataDir;
	c.p2pListen = ["/ip4/0.0.0.0/tcp/0"];
	return c;
}

/// `--data DIR --runtime DIR --port N --no-p2p --p2p-listen MADDR --workers N --thumb N -v`
Config parseArgs(string[] args)
{
	import std.conv : to;
	import std.exception : enforce;

	auto c = defaultConfig();
	bool listenGiven;
	for (size_t i = 1; i < args.length; i++)
	{
		string next()
		{
			enforce(i + 1 < args.length, args[i] ~ " needs a value");
			return args[++i];
		}

		switch (args[i])
		{
		case "--data":
			c.dataDir = next().expandTilde;
			if (c.runtimeDir == defaultConfig().dataDir)
				c.runtimeDir = c.dataDir;
			break;
		case "--runtime":
			c.runtimeDir = next().expandTilde;
			break;
		case "--port":
			c.ipcPort = next().to!ushort;
			break;
		case "--headless":
			c.headless = true;
			c.serve = true;
			break;
		case "--serve":
			c.serve = true;
			break;
		case "--no-p2p":
			c.p2p = false;
			break;
		case "--p2p-listen":
			if (!listenGiven)
				c.p2pListen = null;
			listenGiven = true;
			c.p2pListen ~= next();
			break;
		case "--workers":
			c.workers = next().to!int;
			break;
		case "--thumb":
			c.thumbSize = next().to!int;
			break;
		case "-v":
		case "--verbose":
			c.verbose = true;
			break;
		case "-h":
		case "--help":
			throw new Exception(usage);
		default:
			throw new Exception("unknown option " ~ args[i] ~ "\n" ~ usage);
		}
	}
	return c;
}

enum usage = `photo-wagon [--headless] [--serve] [--data DIR] [--runtime DIR] [--port N]
            [--no-p2p] [--p2p-listen MULTIADDR]... [--workers N] [--thumb PX] [-v]`;
