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

import core.time : MonoTime, Duration, minutes, seconds;

import vibe.core.core : runTask, sleep;
import vibe.core.task : Task;
import vibe.core.sync : LocalManualEvent, createManualEvent;
import vibe.core.log : logDiagnostic, logInfo;

import hyperswarm.connection : Connection;
import photowagon.core.p2p.hswarm : hsWaitWritable;

import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed;

import photowagon.core.ipc.events : Events, EventSink;
import photowagon.core.ipc.handler : RequestHandler;
import photowagon.core.ipc.protocol : Registry, getString;
import photowagon.core.p2p.devices : DeviceRepo, DeviceState, PairingManager;
import photowagon.core.sync.muxstream : LinkMux, MuxSession, MuxStream, muxTagControl, muxTagPiece, isLegacyMuxFrame;
import photowagon.core.sync.pmux : PmuxSession;
import photowagon.core.sync.pieces : PieceService, PieceStore;

alias tagControl = muxTagControl;
alias tagPiece = muxTagPiece;
enum maxControlLine = 16 * 1024 * 1024;   // an IPC line (a base64 fallback can be big)
/// Liveness: the phone writes on the control channel at least every 3 s (its daemon.hello
/// ping) and drops the link itself after 15 s of silence; the desktop mirrors that. A phone
/// that roams away or is killed sends no udx close, so without this deadline its session —
/// the Connection, the mux buffers, and the Events sink that holds it — lived forever.
enum deadAfter = 15.seconds;
/// Before the pairing token is accepted the bar is lower: an unauthenticated peer must not
/// pin a session.
enum deadAfterPreAuth = 10.seconds;
/// Token accepted, pairing code waiting for the operator: the phone sends nothing while it
/// waits (its pings start after auth), so silence is expected — but a pairing nobody
/// confirms must not hold the session forever either.
enum deadAfterPairing = 5.minutes;
/// Replies/events queued for a phone that is not reading: past this it is dropped.
enum size_t maxOutQueued = 64 * 1024 * 1024;

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
	private LinkMux mux;                 // made on the phone's first message: protomux, or the legacy mux
	private Stream control;              // the 'i' stream we send replies/events on
	private RequestHandler handler;
	private EventSink sink;
	private bool authed, tokenOk, gone, pairPending;
	private uint pairGen; // which daemon.pair is current: a superseded resolver must not clear it
	private MonoTime lastRecv;
	private Task watchdog;
	// replies and events leave through a queue a task of its own writes: an event producer
	// (Events.emit is synchronous) must never block on this peer's flow control
	private string[] outq;
	private size_t outBytes;
	private LocalManualEvent outEv;
	private Task writer;

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
		outEv = createManualEvent();
		sink = &send;
		authed = token.length == 0;
		lastRecv = MonoTime.currTime;
		c.onData((ubyte[] b) nothrow {
			if (gone)
				return;
			lastRecv = MonoTime.currTime;
			if (mux is null)
				mux = makeMux(b);
			if (mux !is null)
				mux.feed(b);
		});
		c.onClose = &onClose;
		events.attach(sink);
		try
			watchdog = runTask(&watch);
		catch (Exception)
		{
		}
		logInfo("hs/mux: %s connected", short_);
	}

	/// The phone speaks first; its first message says which mux it runs: protomux (this
	/// version) or the legacy framing of an older phone.
	private LinkMux makeMux(const(ubyte)[] first) nothrow
	{
		LinkMux m;
		immutable legacy = isLegacyMuxFrame(first);
		try
		{
			if (legacy)
				m = new MuxSession(&write, /*initiator*/ false, (MuxStream s) nothrow { onAccept(s); });
			else
			{
				auto pm = new PmuxSession(&write, &onAccept, () nothrow { c.destroy(); });
				pm.admitted = () nothrow { return authed; };   // the mini apps' TCP services: paired peers only
				m = pm;
			}
			m.setThrottle(() nothrow { hsWaitWritable(c); });
			logInfo("hs/mux: %s speaks %s", short_, legacy ? "the legacy mux" : "protomux");
		}
		catch (Exception)
		{
		}
		return m;
	}

	/// Drop a peer that has gone silent past its deadline: a hard destroy (nothing to
	/// flush to a peer that is gone), then the same teardown a udx close would run.
	private void watch() nothrow
	{
		while (!gone)
		{
			try
				sleep(1.seconds);
			catch (Exception)
				return; // interrupted: the session is closing
			if (gone)
				return;
			immutable limit = authed ? deadAfter : pairPending ? deadAfterPairing : deadAfterPreAuth;
			if (MonoTime.currTime - lastRecv <= limit)
				continue;
			try
				logInfo("hs/mux: %s silent for %ss — dropping", short_, limit.total!"seconds");
			catch (Exception)
			{
			}
			c.destroy();
			onClose(); // idempotent; guarantees the sink detaches even if no close arrives
			return;
		}
	}

	private void write(const(ubyte)[] f) nothrow
	{
		try
			c.write(f);   // (Connection.write encrypts into a buffer of its own: no copy needed)
		catch (Exception)
		{
		}
	}

	private void onAccept(Stream s) nothrow
	{
		try
			runTask(() nothrow {
				scope (exit)
					s.close();   // served (or failed): this side is done with it
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

	private void serveControl(Stream s)
	{
		control = s;   // events and replies go here
		if (writer == Task.init)
			writer = runTask(&writeOut);
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
		if (outBytes + line.length > maxOutQueued)
		{
			// the peer takes nothing (withheld flow credit, a stuck phone): cut it loose
			try
				logInfo("hs/mux: %s is not reading — dropping", short_);
			catch (Exception)
			{
			}
			c.destroy();
			onClose();
			return;
		}
		outq ~= line;
		outBytes += line.length;
		outEv.emit();
	}

	// the control channel's writer: one line at a time, in order
	private void writeOut() nothrow
	{
		auto seen = outEv.emitCount;
		while (!gone)
		{
			if (outq.length == 0)
			{
				try
					seen = outEv.wait(seen);
				catch (Exception)
					return;
				continue;
			}
			auto line = outq[0];
			outq = outq[1 .. $];
			outBytes -= line.length;
			try
				writeLengthPrefixed(control, cast(const(ubyte)[]) line);
			catch (Exception)
			{
				// the control stream is gone: without it nothing reaches the phone — end the
				// session (it reconnects) rather than queue replies nobody will read
				c.destroy();
				onClose();
				return;
			}
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
			// begin() resolves a previous request for this peer with false, synchronously —
			// so mark the new one current first, and let only the current one's resolver
			// clear the pending state.
			immutable gen = ++pairGen;
			pairPending = true;
			pairing.begin(peer, code, name, (bool ok) {
				if (gen == pairGen)
				{
					pairPending = false;
					lastRecv = MonoTime.currTime; // the wait was the operator's, not the phone's silence
				}
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
			}, this);   // this connection owns the knock (see PairingManager.cancel)
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

	private void servePieces(Stream s)
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
		outq = null;
		outEv.emit();   // the writer leaves
		// stop the watchdog, unless this teardown is running on it (no self-interrupt)
		if (watchdog != Task.init && watchdog.running && Task.getThis() != watchdog)
			watchdog.interrupt();
		try
		{
			if (mux !is null)
				mux.closeAll();
			events.detach(sink);
			handler.close();
			if (pairing !is null && !authed)
				pairing.cancel(peer, this);
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
