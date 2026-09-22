/// The desktop end of one phone session over a hyperswarm Connection — the same JSON-lines
/// protocol of docs/ipc.md that `IpcOverP2p` served on a libp2p stream, now framed onto ONE
/// end-to-end encrypted udx byte stream (photowagon.core.sync.frames):
///
///   control frames — IPC lines: `daemon.auth {token,name}` first (the shared pairing token),
///                    then the per-device gate (revoked / paused / known / needsPairing →
///                    `daemon.pair {code,name}` held until the operator types the 4-digit code),
///                    then every request through the Registry, events attached to this stream;
///   chunk frames   — a file being pushed, appended into the PartialStore by sha256 at the
///                    stated offset and acked per chunk, so a dropped link resumes from `have`;
///                    the phone then sends `library.import {sha256, complete:true}` (a normal
///                    control request) and import_api lands the verified file.
///
/// The phone is identified by its hyperswarm public key (the same ed25519 identity seed the
/// libp2p path used, so it is stable), as lowercase hex — that is the DeviceRepo/PairingManager
/// key here. Runs on the vibe thread that owns the udx loop (Connection callbacks are nothrow
/// and fire there; RequestHandler answers on fibers of that thread).
module photowagon.core.p2p.hsserve;

import std.json;

import vibe.core.log : logDiagnostic, logInfo;

import hyperswarm.connection : Connection;

import photowagon.core.ipc.events : Events, EventSink;
import photowagon.core.ipc.handler : RequestHandler;
import photowagon.core.ipc.protocol : Registry, getString;
import photowagon.core.p2p.devices : DeviceRepo, DeviceState, PairingManager;
import photowagon.core.store.partials : PartialStore;
import photowagon.core.sync.frames;

final class HsServe
{
	private Connection c;
	private string peer;             // hex(remotePublicKey)
	private Registry registry;
	private Events events;
	private string token;
	private DeviceRepo devices;
	private PairingManager pairing;
	private PartialStore partials;
	private RequestHandler handler;
	private EventSink sink;
	private FrameDecoder dec;
	private bool authed, tokenOk, gone;

	this(Connection c, Registry registry, Events events, string token, DeviceRepo devices = null,
		PairingManager pairing = null, PartialStore partials = null)
	{
		this.c = c;
		this.registry = registry;
		this.events = events;
		this.token = token;
		this.devices = devices;
		this.pairing = pairing;
		this.partials = partials;
		peer = hex(c.remotePublicKey[]);
		handler = new RequestHandler(registry, &send);
		sink = &send;
		authed = token.length == 0;
		events.attach(sink);
		c.onData(&onData);
		c.onClose = &onClose;
		logInfo("ipc/hs: %s connected", short_);
	}

	private string short_() const
	{
		return peer.length > 12 ? peer[0 .. 12] ~ "…" : peer;
	}

	// ---- inbound -------------------------------------------------------------------------

	private void onData(ubyte[] bytes) nothrow
	{
		if (gone)
			return;
		try
		{
			dec.feed(bytes);
			Frame f;
			while (dec.next(f))
			{
				switch (f.type)
				{
				case typeControl: dispatch(cast(string) f.payload.idup); break;
				case typeChunk:   onChunk(f.payload); break;
				default:
					logDiagnostic("ipc/hs: %s sent frame type %s, ignored", short_, f.type);
					break;
				}
			}
		}
		catch (Exception e)
		{
			try
				logDiagnostic("ipc/hs: %s bad frame (%s), dropping", short_, e.msg);
			catch (Exception)
			{
			}
			drop();
		}
	}

	/// `daemon.auth {token}` is answered here; everything else waits for it. Mirrors the
	/// libp2p Client in p2p/ipc.d line for line, so pairing behaves identically on both paths.
	private void dispatch(string line)
	{
		JSONValue msg;
		try
			msg = parseJSON(line);
		catch (Exception)
		{
			handler.handle(line); // the handler answers bad_json
			return;
		}
		immutable method = getString(msg, "method");
		JSONValue id = msg.type == JSONType.object && "id" in msg.object ? msg["id"] : JSONValue(null);
		if (method == "daemon.auth")
		{
			immutable given = msg.type == JSONType.object && "params" in msg.object ? getString(msg["params"], "token") : null;
			if (!(authed || given == token))
			{
				send(RequestHandler.errorLine(id, "unauthorized", "wrong token"));
				return;
			}
			tokenOk = true;
			if (devices !is null && peer.length)
			{
				immutable st = devices.stateOf(peer);
				if (st == DeviceState.revoked)
				{
					send(RequestHandler.errorLine(id, "revoked", "this device was revoked on the computer"));
					return;
				}
				if (st == DeviceState.paused)
				{
					send(RequestHandler.errorLine(id, "paused", "this device is paused on the computer"));
					return;
				}
				if (st !is null)
				{
					devices.touch(peer);
					authed = true;
					send(JSONValue(["id": id, "result": JSONValue(["ok": JSONValue(true)])]).toString());
					return;
				}
				// Unknown device: with a pairing manager it must be confirmed at the desktop;
				// without one (headless, tests) admit and record it so pairing works unattended.
				if (pairing !is null)
				{
					send(JSONValue(["id": id, "result": JSONValue(["ok": JSONValue(true),
						"needsPairing": JSONValue(true)])]).toString());
					return;
				}
				immutable name = msg.type == JSONType.object && "params" in msg.object ? getString(msg["params"], "name") : null;
				devices.add(peer, name);
				devices.touch(peer);
				emit("devices.changed", JSONValue.emptyObject);
			}
			authed = true;
			send(JSONValue(["id": id, "result": JSONValue(["ok": JSONValue(true)])]).toString());
			return;
		}
		if (method == "daemon.pair")
		{
			if (!tokenOk)
			{
				send(RequestHandler.errorLine(id, "unauthorized", "authenticate first"));
				return;
			}
			if (pairing is null || devices is null)
			{
				send(RequestHandler.errorLine(id, "unavailable", "pairing not available here"));
				return;
			}
			immutable params = msg.type == JSONType.object && "params" in msg.object ? msg["params"] : JSONValue.emptyObject;
			immutable code = getString(params, "code");
			immutable name = getString(params, "name");
			auto pid = id;
			logInfo("ipc/hs: pairing knock from %s, code %s", short_, code);
			pairing.begin(peer, code, name, (bool ok) {
				try
				{
					if (ok)
					{
						devices.add(peer, name);
						devices.touch(peer);
						authed = true;
						emit("devices.changed", JSONValue.emptyObject);
						send(JSONValue(["id": pid, "result": JSONValue(["ok": JSONValue(true)])]).toString());
					}
					else
						send(RequestHandler.errorLine(pid, "pairing_refused", "the code did not match"));
				}
				catch (Exception)
				{
				}
			});
			emit("pairing.request", JSONValue(["peer": JSONValue(peer), "name": JSONValue(name)]));
			return;   // no immediate reply: the resolve delegate answers when the operator confirms
		}
		if (authed || method == "daemon.hello")
		{
			handler.handle(line);
			return;
		}
		send(RequestHandler.errorLine(id, "unauthorized", "pair first: daemon.auth {token}"));
	}

	/// One slice of a file: append it at the stated offset, ack how far we now have. Only an
	/// admitted phone may push, and only where there is a partial store to push into.
	private void onChunk(const(ubyte)[] payload)
	{
		const(ubyte)[] data;
		auto h = decodeChunk(payload, data);
		if (!authed || partials is null)
		{
			ack(h.ticket, 0, AckStatus.offsetMismatch);   // not yours to push; the phone re-probes
			return;
		}
		immutable sha = hex(h.sha256[]);
		try
		{
			partials.append(sha, h.offset, data);
			ack(h.ticket, h.offset + cast(long) data.length, AckStatus.ok);
		}
		catch (Exception e)
		{
			// out of order / stale sender: tell the phone where the spool really is
			long have;
			try
				have = partials.have(sha);
			catch (Exception)
			{
			}
			logDiagnostic("ipc/hs: %s chunk refused (%s), spool at %s", short_, e.msg, have);
			ack(h.ticket, have, AckStatus.offsetMismatch);
		}
	}

	// ---- outbound ------------------------------------------------------------------------

	/// A reply or an event line → one control frame. RequestHandler's lines end in "\n";
	/// the frame carries the bare JSON.
	void send(string line) nothrow
	{
		if (gone)
			return;
		while (line.length && (line[$ - 1] == '\n' || line[$ - 1] == '\r'))
			line = line[0 .. $ - 1];
		if (line.length == 0)
			return;
		try
			c.write(encodeControl(line));
		catch (Exception e)
		{
			try
				logDiagnostic("ipc/hs: %s control frame dropped (%s)", short_, e.msg);
			catch (Exception)
			{
			}
		}
	}

	private void ack(long ticket, long offset, AckStatus st) nothrow
	{
		try
			c.write(encodeAck(ticket, offset, st));
		catch (Exception)
		{
		}
	}

	private void emit(string name, JSONValue data) nothrow
	{
		try
			events.emit(name, data);
		catch (Exception)
		{
		}
	}

	// ---- teardown ------------------------------------------------------------------------

	private void onClose() nothrow
	{
		cleanup();
		try
			logInfo("ipc/hs: %s left", short_);
		catch (Exception)
		{
		}
	}

	private void drop() nothrow
	{
		cleanup();
		c.closeGracefully();
	}

	private void cleanup() nothrow
	{
		if (gone)
			return;
		gone = true;
		try
		{
			events.detach(sink);
			handler.close();
			if (pairing !is null && !authed)
				pairing.cancel(peer);   // it left before the desktop authorized it
		}
		catch (Exception)
		{
		}
	}

	private static string hex(const(ubyte)[] b)
	{
		import std.digest : toHexString, LetterCase;
		return toHexString!(LetterCase.lower)(b).idup;
	}
}
