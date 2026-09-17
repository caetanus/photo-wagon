// UsbWatcher — the phone over the cable, the way Photos imports from a camera.
//
// A background loop asks `adb` which devices are plugged in; when a new one
// appears it emits `device.connected` so the desktop can offer to sync. Nothing
// is pulled automatically: the UI shows a dialog, and only on the user's yes does
// `usb.sync` run — list the camera roll over adb, pull what is new straight off
// the device (raw bytes, no base64, no p2p), and hand each file to the indexer,
// which dedups by content hash. A per-device manifest of already-pulled paths
// keeps a second sync from re-copying everything.
//
// This is a companion to p2p sync, not a replacement: p2p is the everywhere,
// always-on path; USB is the fast first bulk import when the phone is plugged in.
module photowagon.core.usb.watcher;

import std.array : array, replace;
import std.conv : to;
import std.file : exists, mkdirRecurse, readText, write;
import std.json;
import std.path : baseName, buildPath, dirName, extension, stripExtension;
import std.process : execute;
import std.string : splitLines, startsWith, strip, split;

import core.time : seconds;

import vibe.core.core : runTask, sleep;
import vibe.core.concurrency : async;
import vibe.core.log : logInfo, logDiagnostic;

import photowagon.core.config : Config;
import photowagon.core.indexer.indexer : Indexer;
import photowagon.core.indexer.scan : isImagePath, isVideoPath;
import photowagon.core.ipc.events : Events;
import photowagon.core.library.roots : RootRepo;

// --- adb, run on the worker pool (execute() blocks; async keeps the loop live) ---

struct AdbOut
{
	int status;
	string output;
}

/// `adb devices -l`.
AdbOut adbDevices()
{
	try
	{
		auto r = execute(["adb", "devices", "-l"]);
		return AdbOut(r.status, r.output);
	}
	catch (Exception e)
		return AdbOut(-1, "");   // adb not installed / no server
}

/// Every file under the phone's camera folders.
AdbOut adbListFiles(string serial)
{
	try
	{
		auto r = execute(["adb", "-s", serial, "shell", "find",
			"/sdcard/DCIM", "/sdcard/Pictures", "-type", "f"]);
		return AdbOut(r.status, r.output);   // status may be nonzero if one dir is missing; output still has the rest
	}
	catch (Exception e)
		return AdbOut(-1, "");
}

/// Copy one file off the device.
AdbOut adbPull(string serial, string remote, string local)
{
	try
	{
		auto r = execute(["adb", "-s", serial, "pull", remote, local]);
		return AdbOut(r.status, r.output);
	}
	catch (Exception e)
		return AdbOut(-1, "");
}

final class UsbWatcher
{
	private Config cfg;
	private Events events;
	private RootRepo roots;
	private Indexer indexer;
	private bool[string] seen;      // serials announced and still plugged in
	private bool[string] syncing;   // serials with a pull in flight
	private shared bool running;

	this(Config cfg, Events events, RootRepo roots, Indexer indexer)
	{
		this.cfg = cfg;
		this.events = events;
		this.roots = roots;
		this.indexer = indexer;
	}

	void start()
	{
		if (running)
			return;
		running = true;
		runTask(() nothrow {
			for (;;)
			{
				if (!running)
					break;
				try
					pollOnce();
				catch (Exception e)
				{
					try logDiagnostic("usb: poll failed: %s", e.msg); catch (Exception) {}
				}
				try
					sleep(3.seconds);
				catch (Exception)
					break;
			}
		});
	}

	void stop() nothrow
	{
		running = false;
	}

	private void pollOnce()
	{
		auto r = async(&adbDevices).getResult();
		if (r.status != 0)
			return;   // no adb, or the server is down; try again next tick
		bool[string] now;
		foreach (line; r.output.splitLines)
		{
			immutable t = line.strip;
			if (!t.length || t.startsWith("List of devices"))
				continue;
			auto parts = t.split();
			if (parts.length < 2 || parts[1] != "device")   // skip "unauthorized" / "offline"
				continue;
			immutable serial = parts[0];
			string model = serial;
			foreach (p; parts[2 .. $])
				if (p.startsWith("model:"))
					model = p["model:".length .. $].replace("_", " ");
			now[serial] = true;
			if (serial !in seen)
			{
				seen[serial] = true;
				events.emit("device.connected",
					JSONValue(["serial": JSONValue(serial), "model": JSONValue(model)]));
				logInfo("usb: device connected %s (%s)", serial, model);
			}
		}
		foreach (s; seen.keys)
			if (s !in now)
			{
				seen.remove(s);
				events.emit("device.disconnected", JSONValue(["serial": JSONValue(s)]));
			}
	}

	/// Called by the `usb.sync` API method once the user confirms the dialog.
	void syncDevice(string serial)
	{
		if (serial in syncing)
			return;
		syncing[serial] = true;
		runTask(() nothrow {
			try
				doSync(serial);
			catch (Exception e)
			{
				try events.emit("usb.done", JSONValue(["error": JSONValue(e.msg)])); catch (Exception) {}
			}
			syncing.remove(serial);
		});
	}

	private void doSync(string serial)
	{
		immutable importsRoot = buildPath(cfg.dataDir, "imports");
		immutable dest = buildPath(importsRoot, "usb-" ~ sanitize(serial));
		mkdirRecurse(dest);
		immutable rootId = roots.add(importsRoot);

		immutable manifestPath = buildPath(cfg.dataDir, "usb", sanitize(serial) ~ ".json");
		bool[string] pulled = loadManifest(manifestPath);

		auto lr = async(&adbListFiles, serial).getResult();
		string[] todo;
		foreach (line; lr.output.splitLines)
		{
			immutable path = line.strip;
			if (!path.length || !(isImagePath(path) || isVideoPath(path)) || path in pulled)
				continue;
			todo ~= path;
		}
		events.emit("usb.progress", JSONValue([
			"serial": JSONValue(serial), "done": JSONValue(0), "total": JSONValue(todo.length),
		]));

		long done, imported;
		foreach (remote; todo)
		{
			immutable local = freePath(dest, baseName(remote));
			auto pr = async(&adbPull, serial, remote, local).getResult();
			done++;
			if (pr.status == 0 && local.exists)
			{
				indexer.indexOne(rootId, local);   // hashes, dedups by content, EXIF, thumbnail
				imported++;
				pulled[remote] = true;
			}
			if (done % 5 == 0 || done == todo.length)
				events.emit("usb.progress", JSONValue([
					"serial": JSONValue(serial), "done": JSONValue(done), "total": JSONValue(todo.length),
				]));
		}
		saveManifest(manifestPath, pulled);
		events.emit("usb.done", JSONValue([
			"serial": JSONValue(serial), "imported": JSONValue(imported), "total": JSONValue(todo.length),
		]));
		logInfo("usb: synced %s — %s of %s new files imported", serial, imported, todo.length);
	}

	// --- helpers --------------------------------------------------------------------

	private static string sanitize(string s)
	{
		char[] out_;
		foreach (char c; s)
			out_ ~= (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ? c : '_';
		return out_.idup;
	}

	private static string freePath(string dir, string name)
	{
		auto p = buildPath(dir, name);
		if (!p.exists)
			return p;
		immutable stem = name.stripExtension;
		immutable ext = name.extension;
		foreach (i; 1 .. 100_000)
		{
			auto q = buildPath(dir, stem ~ "-" ~ i.to!string ~ ext);
			if (!q.exists)
				return q;
		}
		return p;
	}

	private static bool[string] loadManifest(string path)
	{
		bool[string] m;
		try
			if (path.exists)
				foreach (v; parseJSON(readText(path)).array)
					m[v.str] = true;
		catch (Exception)
		{
		}
		return m;
	}

	private static void saveManifest(string path, bool[string] m)
	{
		try
		{
			mkdirRecurse(path.dirName);
			JSONValue[] a;
			foreach (k, _; m)
				a ~= JSONValue(k);
			write(path, JSONValue(a).toString());
		}
		catch (Exception)
		{
		}
	}
}
