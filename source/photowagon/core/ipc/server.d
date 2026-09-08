/// JSON-lines over loopback TCP, for a headless instance (`--headless` /
/// `--serve`): a remote front-end, a test driver. One fiber reads each
/// connection and hands lines to a `RequestHandler`. See docs/ipc.md.
module photowagon.core.ipc.server;

import std.string : indexOf;

import vibe.core.log : logInfo, logWarn, logDiagnostic;
import vibe.core.net : listenTCP, TCPConnection, TCPListener;
import vibe.core.stream : IOMode;
import vibe.core.sync : TaskMutex;
import vibe.core.task : InterruptException;

import photowagon.core.ipc.events : Events, EventSink;
import photowagon.core.ipc.handler : RequestHandler;
import photowagon.core.ipc.protocol : Registry;

final class IpcServer
{
	private Registry registry;
	private Events events;
	private TCPListener listener;
	private Client[] clients;
	private bool closed;

	this(Registry registry, Events events)
	{
		this.registry = registry;
		this.events = events;
	}

	/// Binds and returns the port actually in use.
	ushort listen(string address, ushort port)
	{
		listener = listenTCP(port, &accept, address);
		return listener.bindAddress.port;
	}

	private void accept(TCPConnection conn) @safe nothrow
	{
		try
			serve(conn);
		catch (Exception e)
		{
			try
				logWarn("ipc: connection ended abnormally: %s", e.msg);
			catch (Exception)
			{
			}
		}
	}

	private void serve(TCPConnection conn) @trusted
	{
		if (closed)
		{
			conn.close();
			return;
		}
		auto c = new Client(conn, registry, events);
		clients ~= c;
		scope (exit)
		{
			import std.algorithm : remove;

			clients = clients.remove!(x => x is c);
		}
		c.run();
	}

	void close() nothrow
	{
		if (closed)
			return;
		closed = true;
		try
			listener.stopListening();
		catch (Exception)
		{
		}
		foreach (c; clients.dup)
			c.close();
	}
}

private final class Client
{
	private TCPConnection conn;
	private Events events;
	private TaskMutex writeLock;
	private RequestHandler handler;
	private EventSink sink;
	private bool gone;

	this(TCPConnection conn, Registry registry, Events events)
	{
		this.conn = conn;
		this.events = events;
		writeLock = new TaskMutex;
		handler = new RequestHandler(registry, &send);
		sink = &send;
	}

	void run()
	{
		events.attach(sink);
		scope (exit)
		{
			events.detach(sink);
			handler.close();
			gone = true;
			conn.close();
		}
		logInfo("ipc: client connected from %s", conn.peerAddress);

		ubyte[] pending;
		ubyte[8192] chunk;
		while (true)
		{
			size_t n;
			try
			{
				if (!conn.waitForData())
					break;
				n = conn.read(chunk[], IOMode.once);
			}
			catch (InterruptException)
				throw new InterruptException;
			catch (Exception e)
			{
				logDiagnostic("ipc: read ended: %s", e.msg);
				break;
			}
			if (n == 0)
				break;
			pending ~= chunk[0 .. n];
			ptrdiff_t nl;
			while ((nl = (cast(const(char)[]) pending).indexOf('\n')) >= 0)
			{
				auto line = cast(string) pending[0 .. nl].idup;
				pending = pending[nl + 1 .. $];
				handler.handle(line);
			}
			if (pending.length > 16 * 1024 * 1024)
			{
				logWarn("ipc: line too long, dropping client");
				break;
			}
		}
		logInfo("ipc: client left");
	}

	/// Serialised writes: handlers and the event fan-out share one socket.
	void send(string line) nothrow
	{
		if (gone)
			return;
		try
		{
			writeLock.lock();
			scope (exit)
				writeLock.unlock();
			conn.write(line);
		}
		catch (Exception e)
			gone = true;
	}

	void close() nothrow
	{
		gone = true;
		try
			conn.close();
		catch (Exception)
		{
		}
	}
}
