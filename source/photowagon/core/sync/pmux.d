/// The phone↔desktop link's logical streams over PROTOMUX (d-hyperswarm's hyperswarm.protomux
/// + hyperswarm.streams) instead of the legacy framing of photowagon.core.sync.muxstream:
/// one protomux per hyperswarm Connection, one ChannelStream (credit flow control, a clean
/// end = half-close) per logical stream. The same mux can carry other protocols later — the
/// mini apps' HTTP over `tcpServices` — next to the photos' own streams.
///
/// The code above it is unchanged: a stream still opens with its 1-byte tag and an accepted
/// stream still reads its tag first. Here the tag is the stream's SERVICE (the channel's
/// open handshake — `pw/control`, `pw/piece`): the dialer's first written byte picks it and
/// opens the channel; the acceptor's first read returns it.
module photowagon.core.sync.pmux;

import std.exception : enforce;

import core.time : seconds;
import vibe.core.sync : LocalManualEvent, createManualEvent, TaskMutex;

import hyperswarm.protomux : Protomux;
import hyperswarm.streams : ChannelStream, splice, parseHostPort;
import libp2p.core.stream : Stream;
import libp2p.core.ending : EndOfStream, StreamReset;
import photowagon.core.sync.muxstream : LinkMux, maxMuxPayload, muxTagControl, muxTagPiece;

enum string serviceControl = "pw/control";
enum string servicePiece = "pw/piece";
/// Streams a peer may hold open on one connection at once (control + pieces + thumbnails
/// in flight; past it opens are refused).
enum size_t maxPeerStreams = 32;
/// Each stream's receive window here. Pieces are 1 MiB and a phone on 4G has ~100 ms of
/// round trip: at the protocol's initial 1 MiB a push ran at half the legacy mux's speed
/// (48 MB in 3.5–4.5 s vs 1.8 s at 40 ms); at 8 MiB it matches it (1.1–2.1 s). Worst case
/// a peer holds maxPeerStreams × this unread — the legacy mux buffered without any bound.
enum size_t streamRecvWindow = 8 * 1024 * 1024;
/// How long a stream closed here keeps draining what the peer still sends.
enum drainLimit = 10.seconds;

/// The service of a tag, or null for none.
string serviceOf(ubyte tag) pure nothrow @safe
{
	return tag == muxTagControl ? serviceControl : tag == muxTagPiece ? servicePiece : null;
}

/// The tag of a service, or 0 for none.
ubyte tagOf(string service) pure nothrow @safe
{
	return service == serviceControl ? muxTagControl : service == servicePiece ? muxTagPiece : 0;
}

/// One end of the link over protomux.
final class PmuxSession : LinkMux
{
	private Protomux mux;
	private void delegate(Stream) nothrow onAccept;
	private void delegate() nothrow throttle;
	private bool closed;

	/// The mini apps' hook: service name → "host:port" of a local TCP server a peer may
	/// reach over this connection (plain TCP carried as a stream; HTTP needs nothing more).
	/// Empty by default; only served while `admitted()` says the peer may.
	string[string] tcpServices;
	bool delegate() nothrow admitted;

	/// `sink` writes one frame to the Connection; `destroy` tears the Connection down (the
	/// peer broke the protocol). `onAccept` (null on a side that only dials) gets each
	/// stream the peer opens; the stream lives until that side closes or resets it.
	this(void delegate(const(ubyte)[]) nothrow sink, void delegate(Stream) nothrow onAccept,
		void delegate() nothrow destroy)
	{
		this.onAccept = onAccept;
		mux = new Protomux(sink);
		mux.destroyer = (string why) nothrow {
			if (destroy !is null)
				destroy();
		};
		ChannelStream.accept(mux, &acceptOne, maxPeerStreams, streamRecvWindow);
	}

	Stream open()
	{
		enforce(!closed, "mux: session closed");
		return new PmuxStream(this, null, 0);
	}

	void feed(const(ubyte)[] bytes) nothrow
	{
		if (closed)
			return;
		try
			mux.onFrame(bytes);
		catch (Exception)
		{
		}
	}

	void closeAll() nothrow
	{
		if (closed)
			return;
		closed = true;
		try
			mux.shutdown();
		catch (Exception)
		{
		}
	}

	void setThrottle(void delegate() nothrow t) nothrow
	{
		throttle = t;
	}

	/// The protomux under the link (for more protocols on the same connection).
	Protomux protomux() nothrow
	{
		return mux;
	}

	// a stream the peer opened (runs in its own task, owned by ChannelStream.accept)
	private void acceptOne(ChannelStream cs)
	{
		immutable tag = tagOf(cs.service);
		if (tag == 0)
		{
			auto target = cs.service in tcpServices;
			string host;
			ushort port;
			if (target is null || admitted is null || !admitted() || !parseHostPort(*target, host, port))
			{
				cs.close();
				return;
			}
			import vibe.core.net : connectTCP;

			splice(connectTCP(host, port, null, 0, 10.seconds), cs);
			return;
		}
		if (onAccept is null)
		{
			cs.close();
			return;
		}
		auto s = new PmuxStream(this, cs, tag);
		onAccept(s);
		s.waitDone();   // the handler serves it in a task of its own; hold it until it is done
	}
}

/// One logical stream: libp2p's `Stream` over a ChannelStream.
final class PmuxStream : Stream
{
	private PmuxSession sess;
	private ChannelStream cs;       // null on the dialing side until the first write names it
	private ubyte tag;              // accepting side: handed out as the first byte read
	private bool tagGiven;
	private bool localClosed, wasReset;
	private TaskMutex wlock;
	private LocalManualEvent doneEv;

	private this(PmuxSession sess, ChannelStream cs, ubyte tag)
	{
		this.sess = sess;
		this.tag = tag;
		doneEv = createManualEvent();
		if (cs !is null)
			attach(cs);
	}

	private void attach(ChannelStream c)
	{
		cs = c;
		cs.onClosed = () nothrow { doneEv.emit(); };
	}

	size_t read(ubyte[] dst)
	{
		if (dst.length == 0)
			return 0;
		if (tag != 0 && !tagGiven)
		{
			tagGiven = true;
			dst[0] = tag;
			return 1;
		}
		if (wasReset)
			throw new StreamReset("mux: stream reset");
		enforce(cs !is null, "mux: read before the stream was opened (write its tag first)");
		immutable n = cs.read(dst);
		if (n > 0)
			return n;
		if (cs.ended)
			throw new EndOfStream("mux: stream closed by peer");
		throw new StreamReset("mux: stream reset");
	}

	void write(const(ubyte)[] data)
	{
		if (wlock is null)
			wlock = new TaskMutex;
		wlock.lock();   // one write at a time: a write may wait for credit, another would interleave
		scope (exit)
			wlock.unlock();
		void live()
		{
			if (wasReset)
				throw new StreamReset("mux: stream reset");
			enforce(!localClosed, "mux: write after close");
		}
		live();
		if (cs is null)
		{
			// the dialer's first byte is the tag: it names the service the channel opens for
			enforce(data.length > 0, "mux: nothing to write");
			immutable service = serviceOf(data[0]);
			enforce(service !is null, "mux: unknown stream tag");
			auto opened = ChannelStream.open(sess.mux, service, 10.seconds, streamRecvWindow);
			if (wasReset || localClosed)
			{
				opened.close();   // given up while it opened: the late channel must not linger
				live();
			}
			attach(opened);
			data = data[1 .. $];
		}
		while (data.length)
		{
			immutable n = data.length < maxMuxPayload ? data.length : maxMuxPayload;
			try
				cs.write(data[0 .. n]);
			catch (Exception e)
				throw new StreamReset("mux: stream reset (" ~ e.msg ~ ")");
			data = data[n .. $];
			if (data.length && sess.throttle !is null)
			{
				sess.throttle();
				live();
			}
		}
	}

	/// Graceful: this side sends no more, and reads no more (libp2p's contract). What the
	/// peer still sends is read and dropped — its writes must not stall for credit — until
	/// it ends too or `drainLimit` passes; then the channel is freed.
	void close() nothrow
	{
		if (localClosed || wasReset)
			return;
		localClosed = true;
		doneEv.emit();
		if (cs is null)
			return;
		try
			cs.end();
		catch (Exception)
		{
		}
		if (cs.ended || cs.isClosed)
		{
			cs.close();   // both sides done: free the channel
			return;
		}
		auto c = cs;
		try
		{
			import vibe.core.core : runTask, sleep;
			import vibe.core.task : Task;

			auto timer = runTask(() nothrow {
				try
					sleep(drainLimit);
				catch (Exception)
					return;   // the drain finished first
				c.close();   // wakes the drain below
			});
			runTask((Task t) nothrow {
				try
				{
					ubyte[64 * 1024] buf;
					while (c.read(buf[]) > 0)
					{
					}
				}
				catch (Exception)
				{
				}
				c.close();
				if (t.running)
					t.interrupt();
			}, timer);
		}
		catch (Exception)
		{
			c.close();
		}
	}

	/// Abortive: the peer drops the stream, our pending read/write fail.
	void reset() nothrow
	{
		if (wasReset)
			return;
		wasReset = true;
		if (cs !is null)
			cs.close();
		doneEv.emit();
	}

	// until the channel is really gone: reset here, or closed — which a close() here reaches
	// after its drain (the peer's end, or drainLimit), not at once
	private void waitDone()
	{
		auto c = doneEv.emitCount;
		while (!wasReset && !cs.isClosed)
			c = doneEv.wait(c);
	}
}

version (unittest)
{
	import vibe.core.core : runTask, sleep, exitEventLoop, runEventLoop;
	import core.time : msecs;
}

unittest
{
	// Two sessions cross-wired through a pump task: the dialer opens a control-style stream
	// and concurrent piece-style requests (one with a body over several windows); the
	// acceptor echoes each after its tag — the same shape as the sync's streams.
	import libp2p.core.stream : readExact;

	ubyte[][] toA, toB;
	PmuxSession a, b;
	a = new PmuxSession((const(ubyte)[] f) nothrow { toB ~= f.dup; }, null, null);
	string[] tagsSeen;
	b = new PmuxSession((const(ubyte)[] f) nothrow { toA ~= f.dup; }, (Stream s) nothrow {
		try
			runTask(() nothrow {
				scope (exit)
					s.close();
				try
				{
					ubyte[1] t;
					readExact(s, t[]);
					tagsSeen ~= [cast(char) t[0]];
					ubyte[4] lb;
					readExact(s, lb[]);
					immutable n = (cast(uint) lb[0] << 24) | (cast(uint) lb[1] << 16) | (cast(uint) lb[2] << 8) | lb[3];
					auto body_ = new ubyte[n];
					readExact(s, body_);
					s.write(body_);
					// then the peer's end: a read past it is EndOfStream, not a reset
					ubyte[1] x;
					try
					{
						readExact(s, x[]);
						assert(false, "read past the end");
					}
					catch (EndOfStream)
					{
					}
				}
				catch (Exception e)
					assert(false, e.msg);
			});
		catch (Exception)
		{
		}
	}, null);
	bool pumping = true;
	runTask(() nothrow {
		while (pumping)
		{
			try
			{
				while (toA.length || toB.length)
				{
					auto fa = toA, fb = toB;
					toA = null;
					toB = null;
					foreach (f; fb)
						b.feed(f);
					foreach (f; fa)
						a.feed(f);
				}
				sleep(1.msecs);
			}
			catch (Exception)
			{
			}
		}
	});

	bool ok;
	runTask(() nothrow {
		try
		{
			auto payloads = [cast(ubyte[])[1, 2, 3], new ubyte[3_500_000]];
			foreach (i, p; payloads)
				foreach (j, ref x; p)
					x = cast(ubyte)(i * 31 + j);
			bool[2] done;
			// one call per request: a task spawned straight from the loop body would share
			// the loop's variables (D closures capture them by reference)
			static void request(PmuxSession a, ubyte tg, ubyte[] pl, bool* flag)
			{
				runTask(() nothrow {
					try
					{
						auto s = a.open();
						s.write([tg]);
						ubyte[4] lb = [cast(ubyte)(pl.length >> 24), cast(ubyte)(pl.length >> 16), cast(ubyte)(pl.length >> 8), cast(ubyte) pl.length];
						s.write(lb[] ~ pl);
						auto got = new ubyte[pl.length];
						readExact(s, got);
						assert(got == pl, "echo mismatch");
						s.close();
						*flag = true;
					}
					catch (Exception e)
						assert(false, e.msg);
				});
			}
			request(a, muxTagControl, payloads[0], &done[0]);
			request(a, muxTagPiece, payloads[1], &done[1]);
			foreach (_; 0 .. 1000)
			{
				if (done[0] && done[1])
					break;
				sleep(10.msecs);
			}
			assert(done[0] && done[1], "requests did not both finish");
			// an unknown tag is refused on the dialing side
			try
			{
				a.open().write(['z']);
				assert(false, "unknown tag accepted");
			}
			catch (Exception)
			{
			}
			ok = true;
		}
		catch (Exception e)
			assert(false, e.msg);
		pumping = false;
		try exitEventLoop(); catch (Exception) {}
	});
	runEventLoop();
	assert(ok);
	import std.algorithm : sort;
	auto ts = tagsSeen.dup;
	ts.sort();
	assert(ts == ["i", "p"], ts.idup.to!string);
}

unittest
{
	// the discriminator against both real encoders: a legacy frame and protomux's first
	import photowagon.core.sync.muxstream : MuxSession, isLegacyMuxFrame;

	ubyte[][] legacy;
	auto m = new MuxSession((const(ubyte)[] f) nothrow { legacy ~= f.dup; }, true, null);
	m.open().write([muxTagControl]);
	assert(legacy.length == 1 && isLegacyMuxFrame(legacy[0]));

	ubyte[][] pm;
	auto p = new Protomux((const(ubyte)[] f) nothrow { pm ~= f.dup; });
	auto ch = p.createChannel("hyperswarm/stream/1", cast(ubyte[]) "0123456789abcdef", false);
	ch.open(cast(const(ubyte)[]) serviceControl);
	assert(pm.length == 1 && !isLegacyMuxFrame(pm[0]));
	// a protomux batch (cork) is not legacy either
	pm = null;
	p.cork();
	auto ch2 = p.createChannel("hyperswarm/stream/1", cast(ubyte[]) "fedcba9876543210", false);
	ch2.open(cast(const(ubyte)[]) servicePiece);
	p.uncork();
	foreach (f; pm)
		assert(!isLegacyMuxFrame(f));
	assert(!isLegacyMuxFrame(null) && !isLegacyMuxFrame([0, 0, 0, 5, 0, 0, 0, 2, 0]));   // even id
}

version (unittest) import std.conv : to;
