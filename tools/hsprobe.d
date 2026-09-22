/// hsprobe — a desk-side stand-in for the phone over hyperswarm/udx, so the whole sync
/// protocol is provable from the keyboard, no device in hand (the phone only confirms):
///
///   hsprobe <pairing-token> [seconds]                 auth only (expect needsPairing on first contact)
///   hsprobe <token> <seconds> <file> [stopAfter]      auth → 4-digit pair (confirm it on the desktop:
///                                                     devices.confirm {peerId:<my key>, code:1234})
///                                                     → probe → chunked push → complete.
///                                                     stopAfter = drop the link after N acked chunks,
///                                                     so a second run proves RESUME from `have`.
///
/// Exit 0 = the step chain finished (auth reply / complete landed / stopped on purpose), 1 = failure.
/// A fixed identity seed makes every run the same "device" to the desktop, so pairing sticks.
module hsprobe;

import core.time : seconds;
import std.conv : to;
import std.digest : toHexString, LetterCase;
import std.digest.sha : sha256Of;
import std.file : read, exists;
import std.json;
import std.path : baseName;
import std.stdio;

import vibe.core.core : exitEventLoop, runEventLoop, runTask, sleep;

import hyperswarm.connection : Connection;

import photowagon.core.p2p.hswarm : HsTransport;
import photowagon.core.sync.frames;

enum long idAuth = 1, idPair = 2, idProbe = 3, idComplete = 4;
enum pairCode = "1234";

int main(string[] args)
{
	if (args.length < 2)
	{
		stderr.writeln("usage: hsprobe <pairing-token> [seconds] [file [stopAfterChunks]]");
		return 2;
	}
	immutable token = args[1];
	immutable secs = args.length > 2 ? args[2].to!int : 90;
	immutable path = args.length > 3 ? args[3] : null;
	immutable stopAfter = args.length > 4 ? args[4].to!int : 0;

	ubyte[] data;
	ubyte[32] sha;
	string shaHex;
	if (path.length)
	{
		if (!path.exists)
		{
			stderr.writeln("no such file: ", path);
			return 2;
		}
		data = cast(ubyte[]) read(path);
		sha = sha256Of(data);
		shaHex = toHexString!(LetterCase.lower)(sha[]).idup;
		writeln("file: ", path.baseName, " ", data.length, " bytes sha256 ", shaHex[0 .. 12], "…");
	}

	// PW_PROBE_SEED=<0-255> picks a different fixed identity (a "new device"), to tell a
	// same-key reconnect problem apart from a discovery problem.
	ubyte[32] seed;
	{
		import std.process : environment;
		immutable base = cast(ubyte) environment.get("PW_PROBE_SEED", "80").to!int;
		foreach (i, ref b; seed)
			b = cast(ubyte)(base + i);
	}
	auto ht = new HsTransport(HsTransport.defaultBootstrap(), seed[]);
	writeln("my key (peerId for devices.confirm): ", toHexString!(LetterCase.lower)(ht.publicKey()[]));
	stdout.flush();

	int rc = 1;
	bool finished;
	long ticket = 42, offset, acked;

	void done(int code, string why)
	{
		if (finished)
			return;
		finished = true;
		rc = code;
		writeln(code == 0 ? "OK: " : "FAIL: ", why);
		stdout.flush();
		exitEventLoop();
	}

	ht.onPeer = (Connection c) nothrow {
		try
		{
			writeln("peer: ", toHexString!(LetterCase.lower)(c.remotePublicKey[]));
			stdout.flush();
			FrameDecoder dec;

			void ctl(long id, string method, JSONValue[string] params)
			{
				JSONValue r = ["id": JSONValue(id), "method": JSONValue(method), "params": JSONValue(params)];
				c.write(encodeControl(r.toString()));
				writeln(">> ", method, id == idPair ? " (code " ~ pairCode ~ " — confirm on the desktop)" : "");
				stdout.flush();
			}

			JSONValue[string] meta()
			{
				return ["name": JSONValue(path.baseName), "takenAt": JSONValue("2026-09-20T12:00:00Z"),
					"mtimeMs": JSONValue(0L), "sha256": JSONValue(shaHex)];
			}

			void chunk()
			{
				immutable n = cast(size_t)((data.length - offset) < maxChunk ? (data.length - offset) : maxChunk);
				c.write(encodeChunk(ticket, sha, offset, data[cast(size_t) offset .. cast(size_t) offset + n]));
				writeln(">> chunk @", offset, " +", n);
				stdout.flush();
			}

			c.onData((ubyte[] bytes) nothrow {
				try
				{
					dec.feed(bytes);
					Frame f;
					while (dec.next(f))
					{
						if (f.type == typeAck)
						{
							auto a = decodeAck(f.payload);
							writeln("<< ack ticket=", a.ticket, " offset=", a.offset, " status=", a.status);
							if (a.status != AckStatus.ok)
							{
								done(1, "chunk refused: " ~ a.status.to!string);
								return;
							}
							offset = a.offset;
							acked++;
							if (stopAfter && acked >= stopAfter && offset < data.length)
							{
								writeln("stopping on purpose after ", acked, " chunks at offset ", offset, " — rerun to resume");
								stdout.flush();
								c.closeGracefully(1.seconds);
								done(0, "stopped for the resume test");
								return;
							}
							if (offset >= data.length)
							{
								auto m = meta();
								m["complete"] = JSONValue(true);
								ctl(idComplete, "library.import", m);
							}
							else
								chunk();
							continue;
						}
						if (f.type != typeControl)
							continue;
						auto line = cast(string) f.payload.idup;
						auto j = parseJSON(line);
						if (j.type != JSONType.object)
							continue;
						if ("event" in j.object)
						{
							writeln("<< event ", j["event"].str);
							continue;
						}
						writeln("<< ", line);
						stdout.flush();
						immutable id = "id" in j.object && j["id"].type == JSONType.integer ? j["id"].integer : -1;
						immutable ok = ("result" in j.object) !is null;
						switch (id)
						{
						case idAuth:
							if (!ok) { done(1, "auth refused"); return; }
							auto r = j["result"];
							immutable needs = r.type == JSONType.object && "needsPairing" in r.object && r["needsPairing"].type == JSONType.true_;
							if (needs)
							{
								ctl(idPair, "daemon.pair", ["code": JSONValue(pairCode), "name": JSONValue("hsprobe")]);
								return;
							}
							if (path.length) ctl(idProbe, "library.import", ["name": JSONValue(path.baseName), "sha256": JSONValue(shaHex), "probe": JSONValue(true)]);
							else done(0, "authenticated (known device)");
							return;
						case idPair:
							if (!ok) { done(1, "pairing refused"); return; }
							writeln("paired.");
							if (path.length) ctl(idProbe, "library.import", ["name": JSONValue(path.baseName), "sha256": JSONValue(shaHex), "probe": JSONValue(true)]);
							else done(0, "paired");
							return;
						case idProbe:
							if (!ok) { done(1, "probe failed"); return; }
							auto r = j["result"];
							if (r.type == JSONType.object && "existed" in r.object && r["existed"].type == JSONType.true_)
							{
								done(0, "file already on the desktop");
								return;
							}
							offset = r.type == JSONType.object && "have" in r.object && r["have"].type == JSONType.integer ? r["have"].integer : 0;
							writeln("desktop has ", offset, " of ", data.length, " bytes — ", offset ? "RESUMING" : "starting");
							if (offset >= cast(long) data.length)
							{
								auto m = meta();
								m["complete"] = JSONValue(true);
								ctl(idComplete, "library.import", m);
							}
							else
								chunk();
							return;
						case idComplete:
							done(ok ? 0 : 1, ok ? "complete → landed: " ~ j["result"].toString() : "complete refused: " ~ line);
							return;
						default:
							break;
						}
					}
				}
				catch (Exception e)
				{
					try done(1, e.msg); catch (Exception) {}
				}
			});
			c.onClose = () nothrow { try { writeln("peer closed"); if (!finished) done(1, "connection closed"); } catch (Exception) {} };
			ctl(idAuth, "daemon.auth", ["token": JSONValue(token), "name": JSONValue("hsprobe")]);
		}
		catch (Exception e)
		{
			try done(1, e.msg); catch (Exception) {}
		}
	};

	runTask(() nothrow {
		try
		{
			ht.start(HsTransport.topicFor(cast(const(ubyte)[]) token), /*asServer*/ false);
			writeln("joined topic for token ", token[0 .. token.length < 8 ? token.length : 8], "…; waiting up to ", secs, "s");
			stdout.flush();
			sleep(secs.seconds);
			if (!finished)
				done(1, "timeout");
		}
		catch (Exception e)
		{
			try done(1, e.msg); catch (Exception) {}
		}
	});
	runEventLoop();
	return rc;
}
