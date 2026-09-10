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
import photowagon.core.ipc.protocol : Registry, getString;

enum ipcProtocol = "/photowagon/ipc/1.0.0";
/// A phone photo travels as base64 inside one line: 64 MiB is a 48 MB file.
enum maxLine = 64 * 1024 * 1024;

final class IpcOverP2p
{
	private Registry registry;
	private Events events;
	private string token;

	this(Host host, Registry registry, Events events, string token)
	{
		this.registry = registry;
		this.events = events;
		this.token = token;
		host.setStreamHandler(ipcProtocol, &serve);
	}

	private void serve(Stream s, Connection c, string protocol)
	{
		auto client = new Client(s, c.remotePeer.toString, registry, events, token);
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

	this(Stream s, string peer, Registry registry, Events events, string token)
	{
		this.s = s;
		this.peer = peer;
		this.events = events;
		this.token = token;
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
			if (authed || given == token)
			{
				authed = true;
				send(JSONValue(["id": id, "result": JSONValue(["ok": JSONValue(true)])]).toString());
			}
			else
				send(RequestHandler.errorLine(id, "unauthorized", "wrong token"));
			return;
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
			gone = true;
	}
}
