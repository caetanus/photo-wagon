/// The udx/hyperdht/hyperswarm FLAVOR of the phone↔desktop link, carrying the same content —
/// the JSON-lines IPC of docs/ipc.md and the piece+Merkle transfer — over a hyperswarm
/// Connection. A Connection is one encrypted byte pipe, so everything rides the request-id
/// MUX (photowagon.core.sync.muxstream): each logical stream opens with a 1-byte tag —
///   'i' the control channel: length-prefixed JSON lines (auth → device gate → pair → the
///       Registry; events pushed back on it), exactly the protocol HsServe/IpcOverP2p speak;
///   'p' a piece request: PieceService serves it (INFO/HAVE/GET+Merkle proof/MANIFEST/PUT),
///       admitted only for a paired device.
/// The peer is its hyperswarm public key (hex) — the DeviceRepo/PairingManager key, the same
/// stable ed25519 identity the libp2p path uses. Runs on the vibe thread owning the udx loop.
module photowagon.core.p2p.hsmux;

import std.json;

import vibe.core.core : runTask;
import vibe.core.log : logDiagnostic, logInfo;

import hyperswarm.connection : Connection;

import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed;

import photowagon.core.ipc.events : Events, EventSink;
import photowagon.core.ipc.handler : RequestHandler;
import photowagon.core.ipc.protocol : Registry, getString;
import photowagon.core.p2p.devices : DeviceRepo, DeviceState, PairingManager;
import photowagon.core.sync.muxstream : MuxSession, MuxStream, muxTagControl, muxTagPiece;
import photowagon.core.sync.pieces : PieceService, PieceStore;

alias tagControl = muxTagControl;
alias tagPiece = muxTagPiece;
enum maxControlLine = 16 * 1024 * 1024;   // an IPC line (a base64 fallback can be big)

/// One phone session over a hyperswarm Connection, on the mux.
final class HsMuxServe
{
	private Connection c;
	private string peer;                 // hex(remotePublicKey)
	private Registry registry;
	private Events events;
	private string token;
	private DeviceRepo devices;
	private PairingManager pairing;
	private PieceService pieces;
	private MuxSession mux;
	private MuxStream control;           // the 'i' stream we send replies/events on
	private RequestHandler handler;
	private EventSink sink;
	private bool authed, tokenOk, gone;

	this(Connection c, Registry registry, Events events, string token, DeviceRepo devices,
		PairingManager pairing, PieceService pieces)
	{
		this.c = c;
		this.registry = registry;
		this.events = events;
		this.token = token;
		this.devices = devices;
		this.pairing = pairing;
		this.pieces = pieces;
		peer = hex(c.remotePublicKey[]);
		handler = new RequestHandler(registry, &send);
		sink = &send;
		authed = token.length == 0;
		mux = new MuxSession(&write, /*initiator*/ false, &onAccept);
		c.onData((ubyte[] b) nothrow { if (!gone) mux.feed(b); });
		c.onClose = &onClose;
		events.attach(sink);
		logInfo("hs/mux: %s connected", short_);
	}

	private void write(const(ubyte)[] f) nothrow
	{
		try
			c.write(f.dup);
		catch (Exception)
		{
		}
	}

	private void onAccept(MuxStream s) nothrow
	{
		try
			runTask(() nothrow {
				try
				{
					ubyte[1] tag;
					readExactS(s, tag[]);
					if (tag[0] == tagControl)
						serveControl(s);
					else if (tag[0] == tagPiece)
						servePieces(s);
					else
						s.reset();
				}
				catch (Exception)
				{
					try s.close(); catch (Exception) {}
				}
			});
		catch (Exception)
		{
		}
	}

	// ---- control channel ('i'): the JSON-lines IPC, auth/pair, events --------------------

	private void serveControl(MuxStream s)
	{
		control = s;   // events and replies go here
		for (;;)
		{
			auto line = cast(string) readLengthPrefixed(s, maxControlLine).idup;
			dispatch(line);
		}
	}

	private void send(string line) nothrow
	{
		if (gone || control is null)
			return;
		while (line.length && (line[$ - 1] == '\n' || line[$ - 1] == '\r'))
			line = line[0 .. $ - 1];
		if (line.length == 0)
			return;
		try
			writeLengthPrefixed(control, cast(const(ubyte)[]) line);
		catch (Exception)
		{
		}
	}

	/// Verbatim from HsServe.dispatch (the agent-proven auth/pair/handler path).
	private void dispatch(string line)
	{
		JSONValue msg;
		try
			msg = parseJSON(line);
		catch (Exception)
		{
			handler.handle(line);
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
			logInfo("hs/mux: pairing knock from %s, code %s", short_, code);
			logInfo("hs/mux: pairing knock full peer %s", peer);
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
			return;
		}
		if (authed || method == "daemon.hello")
		{
			handler.handle(line);
			return;
		}
		send(RequestHandler.errorLine(id, "unauthorized", "pair first: daemon.auth {token}"));
	}

	// ---- piece channel ('p') -------------------------------------------------------------

	private void servePieces(MuxStream s)
	{
		if (!authed)   // only a paired device may pull/push pieces
		{
			s.reset();
			return;
		}
		pieces.serve(s);
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
		if (gone)
			return;
		gone = true;
		try
		{
			mux.closeAll();
			events.detach(sink);
			handler.close();
			if (pairing !is null && !authed)
				pairing.cancel(peer);
		}
		catch (Exception)
		{
		}
		try
			logInfo("hs/mux: %s left", short_);
		catch (Exception)
		{
		}
	}

	private string short_() const
	{
		return peer.length > 12 ? peer[0 .. 12] ~ "…" : peer;
	}

	private static string hex(const(ubyte)[] b)
	{
		import std.digest : toHexString, LetterCase;
		return toHexString!(LetterCase.lower)(b).idup;
	}
}

// readExact on a Stream, local so hsmux needn't import the free function under another name.
private void readExactS(Stream s, ubyte[] buf)
{
	import libp2p.core.stream : readExact;
	readExact(s, buf);
}
