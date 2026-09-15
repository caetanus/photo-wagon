/// `/photowagon/ipc/1.0.0` — the JSON-lines protocol of docs/ipc.md over a
/// libp2p stream, for the phone.
///
/// Each frame is one length-prefixed line; requests, answers and events are
/// exactly what the TCP listener speaks. The peer must present the pairing
/// token first (`daemon.auth {token}`), as a LAN client would: libp2p tells us
/// who the peer is, not that it is allowed in. One stream per client, events
/// attached for as long as it stays open.
module photowagon.core.p2p.ipc;

import std.json;

import vibe.core.log : logInfo, logWarn, logDiagnostic;
import vibe.core.sync : TaskMutex;

import libp2p.core.ending : EndOfStream;
import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed;
import libp2p.host.host : Host;
import libp2p.swarm.connection : Connection;

import photowagon.core.ipc.events : Events, EventSink;
import photowagon.core.ipc.handler : RequestHandler;
import photowagon.core.p2p.devices : DeviceRepo, DeviceState, PairingManager;
import photowagon.core.ipc.protocol : Registry, getString;

enum ipcProtocol = "/photowagon/ipc/1.0.0";
/// A phone photo travels as base64 inside one line: 64 MiB is a 48 MB file.
enum maxLine = 64 * 1024 * 1024;

final class IpcOverP2p
{
	private Registry registry;
	private Events events;
	private string token;
	private DeviceRepo devices;
	private PairingManager pairing;

	this(Host host, Registry registry, Events events, string token, DeviceRepo devices = null,
		PairingManager pairing = null)
	{
		this.registry = registry;
		this.events = events;
		this.token = token;
		this.devices = devices;
		this.pairing = pairing;
		host.setStreamHandler(ipcProtocol, &serve);
	}

	private void serve(Stream s, Connection c, string protocol)
	{
		auto client = new Client(s, c.remotePeer.toString, registry, events, token, devices, pairing);
		client.run();
	}
}

private final class Client
{
	private Stream s;
	private string peer;
	private Events events;
	private TaskMutex writeLock;
	private RequestHandler handler;
	private EventSink sink;
	private string token;
	private bool authed;
	private bool gone;
	private DeviceRepo devices;
	private PairingManager pairing;
	private bool tokenOk;

	this(Stream s, string peer, Registry registry, Events events, string token, DeviceRepo devices = null,
		PairingManager pairing = null)
	{
		this.s = s;
		this.peer = peer;
		this.events = events;
		this.token = token;
		this.devices = devices;
		this.pairing = pairing;
		writeLock = new TaskMutex;
		handler = new RequestHandler(registry, &send);
		sink = &send;
		authed = token.length == 0;
	}

	void run()
	{
		events.attach(sink);
		scope (exit)
		{
			events.detach(sink);
			handler.close();
			gone = true;
			if (pairing !is null && !authed)
				pairing.cancel(peer);   // it left before the desktop authorized it
			s.close();
			logInfo("ipc/p2p: %s left", peer);
		}
		logInfo("ipc/p2p: %s connected", peer);
		while (true)
		{
			ubyte[] frame;
			try
				frame = readLengthPrefixed(s, maxLine);
			catch (EndOfStream)
				return;
			catch (Exception e)
			{
				logDiagnostic("ipc/p2p: read ended: %s", e.msg);
				return;
			}
			dispatch(cast(string) frame.idup);
		}
	}

	/// `daemon.auth {token}` is answered here; everything else waits for it.
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
			// The token is right; now the per-device gate. libp2p tells us the peer id, a
			// stable fingerprint for this phone. A revoked or paused device is turned away; a
			// known one is admitted; an unknown one must be authorized by the person at the
			// desktop, who types the 4-digit code the phone shows (daemon.pair, below).
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
				// Unknown device. With a pairing manager it must be confirmed at the desktop;
				// without one (a headless setup, a test), fall back to admitting it and
				// recording it, so pairing still works where there is no operator.
				if (pairing !is null)
				{
					send(JSONValue(["id": id, "result": JSONValue(["ok": JSONValue(true),
						"needsPairing": JSONValue(true)])]).toString());
					return;
				}
				immutable name = msg.type == JSONType.object && "params" in msg.object ? getString(msg["params"], "name") : null;
				devices.add(peer, name);
				devices.touch(peer);
				try
					events.emit("devices.changed", JSONValue.emptyObject);
				catch (Exception)
				{
				}
			}
			authed = true;
			send(JSONValue(["id": id, "result": JSONValue(["ok": JSONValue(true)])]).toString());
			return;
		}
		if (method == "daemon.pair")
		{
			// The phone shows a 4-digit code and sends it here; the connection is held until
			// the person at the desktop types the same code (devices.confirm → pairing.confirm).
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
			logInfo("ipc/p2p: pairing knock from %s, code %s", peer, code);
			pairing.begin(peer, code, name, (bool ok) {
				try
				{
					if (ok)
					{
						devices.add(peer, name);
						devices.touch(peer);
						authed = true;
						events.emit("devices.changed", JSONValue.emptyObject);
						send(JSONValue(["id": pid, "result": JSONValue(["ok": JSONValue(true)])]).toString());
					}
					else
						send(RequestHandler.errorLine(pid, "pairing_refused", "the code did not match"));
				}
				catch (Exception)
				{
				}
			});
			try
				events.emit("pairing.request", JSONValue(["peer": JSONValue(peer), "name": JSONValue(name)]));
			catch (Exception)
			{
			}
			return;   // no immediate reply: the resolve delegate answers when the operator confirms
		}
		if (authed || method == "daemon.hello")
		{
			handler.handle(line);
			return;
		}
		send(RequestHandler.errorLine(id, "unauthorized", "pair first: daemon.auth {token}"));
	}

	void send(string line) nothrow
	{
		if (gone)
			return;
		try
		{
			writeLock.lock();
			scope (exit)
				writeLock.unlock();
			writeLengthPrefixed(s, cast(const(ubyte)[]) line);
		}
		catch (Exception e)
		{
			gone = true;
			try
				logDiagnostic("ipc/p2p: %s write failed (%s), dropping stream", peer[0 .. peer.length > 12 ? 12 : peer.length], e.msg);
			catch (Exception)
			{
			}
		}
	}
}
