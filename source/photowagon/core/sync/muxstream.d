/// A request-id multiplexer over one byte pipe — the hyperswarm flavor's answer to "one udx
/// stream, no streams". A hyperswarm Connection is a single bidirectional secret-stream; this
/// presents it as many logical streams, each a libp2p-compatible `Stream` (read/write/close),
/// so the SAME piece+Merkle protocol that runs on libp2p streams runs here unchanged. The two
/// ends of a connection make one MuxSession each, cross-wired by the Connection's write/onData.
///
/// Wire, big-endian, one frame:
///   u32 len            — of everything after it (id + flag + payload)
///   u32 id             — logical stream id; the opener owns parity (initiator odd, acceptor
///                        even) so ids never collide without a handshake
///   u8  flag           — 0 data · 1 fin (last frame of this stream's writes) · 2 reset
///   payload            — up to maxMuxPayload bytes; a larger write is split across frames so
///                        a 1 MiB piece body never monopolises the pipe (control interleaves)
///
/// The reader blocks on a per-stream event that onData wakes — cooperative fibers, so a woken
/// reader simply re-checks its buffer (no spurious wakeups). Not protomux-framed; phone↔desktop
/// only. Pure of any transport: `write` is a delegate, `feed` is fed from the Connection.
module photowagon.core.sync.muxstream;

import std.exception : enforce;

import vibe.core.sync : LocalManualEvent, createManualEvent;

import libp2p.core.stream : Stream;

enum size_t maxMuxPayload = 64 * 1024;   // ≤64 KiB per frame: interleave a big write with others

/// The 1-byte tag a logical stream opens with, so the accepting side knows what it carries:
/// 'i' the control channel (JSON-lines IPC, auth/pair, events), 'p' a piece request.
enum ubyte muxTagControl = 'i';
enum ubyte muxTagPiece = 'p';
enum size_t maxMuxFrame = maxMuxPayload + 16;

private enum ubyte flagData = 0, flagFin = 1, flagReset = 2;

/// One end of the mux over a byte pipe.
final class MuxSession
{
	private void delegate(const(ubyte)[]) nothrow sink;   // Connection.write
	private void delegate(MuxStream) nothrow onAccept;     // an inbound logical stream opened
	private MuxStream[uint] streams;
	private uint nextId;                                   // odd for the initiator, even for the acceptor
	private ubyte[] inbuf;                                 // reassembly across pipe deliveries
	private bool closed;

	/// `initiator` = the side that dials (the phone). `onAccept` fires on the accepting side
	/// once per logical stream the peer opens.
	this(void delegate(const(ubyte)[]) nothrow sink, bool initiator, void delegate(MuxStream) nothrow onAccept)
	{
		this.sink = sink;
		this.onAccept = onAccept;
		nextId = initiator ? 1 : 2;
	}

	/// Open a logical stream to the peer (the asking side of a request).
	MuxStream open()
	{
		enforce(!closed, "mux: session closed");
		immutable id = nextId;
		nextId += 2;
		auto s = new MuxStream(this, id);
		streams[id] = s;
		return s;
	}

	/// Feed bytes arriving on the pipe (call from Connection.onData). Whole frames are
	/// dispatched; a partial tail is held for the next call.
	void feed(const(ubyte)[] bytes) nothrow
	{
		inbuf ~= bytes;
		for (;;)
		{
			if (inbuf.length < 4)
				return;
			immutable len = (cast(uint) inbuf[0] << 24) | (cast(uint) inbuf[1] << 16) | (cast(uint) inbuf[2] << 8) | inbuf[3];
			if (len < 5 || len > maxMuxFrame)
			{
				closeAll();   // a hostile/desynced peer: tear the whole mux down
				return;
			}
			if (inbuf.length < 4 + len)
				return;
			immutable id = (cast(uint) inbuf[4] << 24) | (cast(uint) inbuf[5] << 16) | (cast(uint) inbuf[6] << 8) | inbuf[7];
			immutable flag = inbuf[8];
			auto payload = inbuf[9 .. 4 + len];
			dispatch(id, flag, payload);
			inbuf = inbuf[4 + len .. $];
		}
	}

	private void dispatch(uint id, ubyte flag, const(ubyte)[] payload) nothrow
	{
		auto sp = id in streams;
		if (sp is null)
		{
			// unknown id: the peer opened a stream (its parity, opposite to ours). Accept it.
			if ((id & 1) == (nextId & 1) || closed || onAccept is null)
				return;   // our own retired id, or nothing to accept onto
			auto s = new MuxStream(this, id);
			streams[id] = s;
			if (payload.length)
				s.deliver(payload);
			if (flag == flagFin)
				s.remoteFin();
			else if (flag == flagReset)
				s.remoteReset();
			try
				onAccept(s);
			catch (Exception)
			{
			}
			return;
		}
		if (payload.length)
			sp.deliver(payload);
		if (flag == flagFin)
			sp.remoteFin();
		else if (flag == flagReset)
			sp.remoteReset();
	}

	/// The pipe is gone: fail every open stream so blocked readers/writers return.
	void closeAll() nothrow
	{
		closed = true;
		foreach (s; streams.values)
			s.remoteReset();
		streams = null;
	}

	// --- called by MuxStream ---------------------------------------------------------------

	private void sendFrame(uint id, ubyte flag, const(ubyte)[] payload) nothrow
	{
		if (closed)
			return;
		immutable len = cast(uint)(5 + payload.length);
		ubyte[] f = new ubyte[4 + len];
		f[0 .. 4] = [cast(ubyte)(len >> 24), cast(ubyte)(len >> 16), cast(ubyte)(len >> 8), cast(ubyte) len];
		f[4 .. 8] = [cast(ubyte)(id >> 24), cast(ubyte)(id >> 16), cast(ubyte)(id >> 8), cast(ubyte) id];
		f[8] = flag;
		f[9 .. $] = payload[];
		try
			sink(f);
		catch (Exception)
		{
		}
	}

	private void forget(uint id) nothrow
	{
		streams.remove(id);
	}
}

/// One logical stream. Implements libp2p's `Stream` so the piece protocol drops onto it.
final class MuxStream : Stream
{
	private MuxSession mux;
	private uint id;
	private ubyte[] buf;              // received, not yet read
	private LocalManualEvent ev;
	private bool remoteClosed;        // peer sent fin
	private bool wasReset;            // pipe/stream torn down
	private bool localClosed;

	private this(MuxSession mux, uint id) nothrow
	{
		this.mux = mux;
		this.id = id;
		try
			ev = createManualEvent();
		catch (Exception)
		{
		}
	}

	// --- Stream ---------------------------------------------------------------------------

	size_t read(ubyte[] dst)
	{
		if (dst.length == 0)
			return 0;
		for (;;)
		{
			if (buf.length > 0)
			{
				immutable n = dst.length < buf.length ? dst.length : buf.length;
				dst[0 .. n] = buf[0 .. n];
				buf = buf[n .. $];
				return n;
			}
			enforce(!wasReset, "mux: stream reset");
			enforce(!remoteClosed, "mux: stream closed by peer");
			ev.wait();   // woken by deliver/remoteFin/remoteReset; re-check the buffer
		}
	}

	void write(const(ubyte)[] data)
	{
		enforce(!wasReset, "mux: stream reset");
		enforce(!localClosed, "mux: write after close");
		// split so one big write can't hold the pipe against other streams' frames
		while (data.length > maxMuxPayload)
		{
			mux.sendFrame(id, flagData, data[0 .. maxMuxPayload]);
			data = data[maxMuxPayload .. $];
		}
		mux.sendFrame(id, flagData, data);
	}

	void close() nothrow
	{
		if (localClosed || wasReset)
			return;
		localClosed = true;
		mux.sendFrame(id, flagFin, null);
		if (remoteClosed)
			mux.forget(id);
	}

	/// Abort: tell the peer to drop this stream and fail our own pending read/write.
	void reset() nothrow
	{
		if (wasReset)
			return;
		wasReset = true;
		mux.sendFrame(id, flagReset, null);
		mux.forget(id);
		try ev.emit(); catch (Exception) {}
	}

	// --- driven by the session ------------------------------------------------------------

	private void deliver(const(ubyte)[] payload) nothrow
	{
		buf ~= payload;
		try ev.emit(); catch (Exception) {}
	}

	private void remoteFin() nothrow
	{
		remoteClosed = true;
		try ev.emit(); catch (Exception) {}
		if (localClosed)
			mux.forget(id);
	}

	private void remoteReset() nothrow
	{
		wasReset = true;
		try ev.emit(); catch (Exception) {}
	}
}

version (unittest)
{
	import vibe.core.core : runTask, sleep, exitEventLoop, runEventLoop;
	import core.time : msecs;
}

unittest
{
	import libp2p.core.stream : readExact;

	// Two sessions cross-wired in memory: A.sink → B.feed and back. A opens streams; B echoes.
	MuxSession a, b;
	a = new MuxSession((const(ubyte)[] f) nothrow { try b.feed(f); catch (Exception) {} }, true, null);
	b = new MuxSession((const(ubyte)[] f) nothrow { try a.feed(f); catch (Exception) {} }, false,
		(MuxStream s) nothrow {
			// echo server: read a 4-byte length, then that many bytes, write them back, fin
			try
				runTask(() nothrow {
					try
					{
						ubyte[4] lb;
						readExact(s, lb[]);
						immutable n = (cast(uint) lb[0] << 24) | (cast(uint) lb[1] << 16) | (cast(uint) lb[2] << 8) | lb[3];
						auto body_ = new ubyte[n];
						readExact(s, body_);
						s.write(body_);
						s.close();
					}
					catch (Exception)
					{
					}
				});
			catch (Exception)
			{
			}
		});

	bool ok;
	runTask(() nothrow {
		try
		{
			// two concurrent requests to prove ids don't collide and frames interleave
			auto payloads = [cast(ubyte[])[1, 2, 3, 4, 5], new ubyte[200_000]];
			foreach (i, p; payloads)
				foreach (j, ref x; p)
					x = cast(ubyte)(i * 31 + j);
			shared bool[2] done;
			static void req(MuxSession a, ubyte[] pl, shared(bool)* flag) nothrow
			{
				try
				{
					auto s = a.open();
					ubyte[4] lb = [cast(ubyte)(pl.length >> 24), cast(ubyte)(pl.length >> 16), cast(ubyte)(pl.length >> 8), cast(ubyte) pl.length];
					s.write(lb[]);
					s.write(pl);
					auto got = new ubyte[pl.length];
					readExact(s, got);
					assert(got == pl, "mux echo mismatch");
					s.close();
					*flag = true;
				}
				catch (Exception e)
					assert(false, e.msg);
			}
			foreach (i, p; payloads)
			{
				auto pl = p;
				auto fp = &done[i];
				runTask(() nothrow { req(a, pl, fp); });
			}
			foreach (_; 0 .. 300)
			{
				if (done[0] && done[1])
					break;
				sleep(10.msecs);
			}
			assert(done[0] && done[1], "mux requests did not both finish");
			ok = true;
		}
		catch (Exception e)
			assert(false, e.msg);
		try exitEventLoop(); catch (Exception) {}
	});
	runEventLoop();
	assert(ok);
}
