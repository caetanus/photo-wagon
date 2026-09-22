/// Frames for the single phone↔desktop sync stream (udx/hyperswarm gives ONE bidirectional
/// byte stream per peer — no multiplexing). Control (the JSON-lines IPC), file chunks and
/// their acks all ride the same stream, so a chunk is capped small enough that a control or
/// keepalive frame always gets a turn between chunks: a 31 MB video no longer sits in front
/// of the keepalive.
///
/// Wire, big-endian:
///   u32 length            — of everything after it (type + payload)
///   u8  type              — 0 control · 1 chunk · 2 ack
///   payload:
///     control: the UTF-8 JSON message (one IPC line, without the newline)
///     chunk:   i64 ticket · 32 B raw sha256 · i64 offset · i64 size · `size` file bytes
///              (size ≤ maxChunk; a resume is just a chunk with offset > 0 — see
///              photowagon.core.store.partials)
///     ack:     i64 ticket · i64 offset (bytes confirmed appended so far) · u8 status
///              (0 ok · 1 offset mismatch, re-probe · 2 hash mismatch, restart from 0)
///
/// Pure data: no transport, no vibe. Both ends use this module; the phone build lists it
/// in build-android.sh.
module photowagon.core.sync.frames;

import std.exception : enforce;

enum ubyte typeControl = 0;
enum ubyte typeChunk = 1;
enum ubyte typeAck = 2;

/// Largest file slice per chunk frame. Small enough to interleave with control on one stream.
enum size_t maxChunk = 64 * 1024;
/// Largest frame we accept from the wire (a control message can carry a page of JSON).
enum size_t maxFrame = 1024 * 1024;

enum chunkHeader = 8 + 32 + 8 + 8;   // ticket, sha256, offset, size
enum ackSize = 8 + 8 + 1;

enum AckStatus : ubyte
{
	ok = 0,
	offsetMismatch = 1,
	hashMismatch = 2,
}

struct Frame
{
	ubyte type;
	const(ubyte)[] payload;
}

struct ChunkHead
{
	long ticket;
	ubyte[32] sha256;
	long offset;
	long size;
}

struct Ack
{
	long ticket;
	long offset;
	AckStatus status;
}

// ---- encoding -------------------------------------------------------------------------

ubyte[] encodeControl(const(char)[] json) pure @safe
{
	return frame(typeControl, cast(const(ubyte)[]) json);
}

/// One slice of a file starting at `offset`. `data.length` must be ≤ maxChunk.
ubyte[] encodeChunk(long ticket, const ref ubyte[32] sha256, long offset, const(ubyte)[] data) pure @safe
{
	enforce(data.length <= maxChunk, "chunk larger than maxChunk");
	auto p = new ubyte[chunkHeader + data.length];
	putLong(p[0 .. 8], ticket);
	p[8 .. 40] = sha256[];
	putLong(p[40 .. 48], offset);
	putLong(p[48 .. 56], cast(long) data.length);
	p[56 .. $] = data[];
	return frame(typeChunk, p);
}

ubyte[] encodeAck(long ticket, long offset, AckStatus status) pure @safe
{
	ubyte[ackSize] p;
	putLong(p[0 .. 8], ticket);
	putLong(p[8 .. 16], offset);
	p[16] = status;
	return frame(typeAck, p[]);
}

private ubyte[] frame(ubyte type, const(ubyte)[] payload) pure @safe
{
	enforce(payload.length + 1 <= maxFrame, "frame larger than maxFrame");
	auto f = new ubyte[4 + 1 + payload.length];
	putUint(f[0 .. 4], cast(uint)(1 + payload.length));
	f[4] = type;
	f[5 .. $] = payload[];
	return f;
}

// ---- decoding -------------------------------------------------------------------------

/// Feed it whatever arrives on the stream, in any slicing; pop complete frames.
struct FrameDecoder
{
	private ubyte[] buf;

	void feed(const(ubyte)[] bytes) pure @safe
	{
		buf ~= bytes;
	}

	/// The next complete frame, or false when more bytes are needed. Throws on a frame
	/// that exceeds maxFrame (a corrupt or hostile stream — drop the connection).
	bool next(out Frame f) pure @safe
	{
		if (buf.length < 4)
			return false;
		immutable len = getUint(buf[0 .. 4]);
		enforce(len >= 1 && len <= maxFrame, "bad frame length");
		if (buf.length < 4 + len)
			return false;
		f.type = buf[4];
		f.payload = buf[5 .. 4 + len];
		buf = buf[4 + len .. $];
		return true;
	}

	/// Bytes buffered but not yet forming a frame (for diagnostics / backpressure).
	size_t pending() const pure @safe nothrow @nogc
	{
		return buf.length;
	}
}

/// Splits a chunk frame's payload into its header and the file bytes. Validates size.
ChunkHead decodeChunk(const(ubyte)[] payload, out const(ubyte)[] data) pure @safe
{
	enforce(payload.length >= chunkHeader, "short chunk");
	ChunkHead h;
	h.ticket = getLong(payload[0 .. 8]);
	h.sha256[] = payload[8 .. 40];
	h.offset = getLong(payload[40 .. 48]);
	h.size = getLong(payload[48 .. 56]);
	enforce(h.size >= 0 && h.size <= maxChunk && payload.length == chunkHeader + h.size, "chunk size mismatch");
	data = payload[56 .. $];
	return h;
}

Ack decodeAck(const(ubyte)[] payload) pure @safe
{
	enforce(payload.length == ackSize, "bad ack");
	Ack a;
	a.ticket = getLong(payload[0 .. 8]);
	a.offset = getLong(payload[8 .. 16]);
	enforce(payload[16] <= AckStatus.max, "bad ack status");
	a.status = cast(AckStatus) payload[16];
	return a;
}

// ---- big-endian helpers ---------------------------------------------------------------

private void putUint(ubyte[] b, uint v) pure @safe nothrow @nogc
in (b.length == 4)
{
	foreach_reverse (i; 0 .. 4)
	{
		b[i] = cast(ubyte)(v & 0xff);
		v >>= 8;
	}
}

private uint getUint(const(ubyte)[] b) pure @safe nothrow @nogc
in (b.length == 4)
{
	uint v;
	foreach (x; b)
		v = (v << 8) | x;
	return v;
}

private void putLong(ubyte[] b, long v) pure @safe nothrow @nogc
in (b.length == 8)
{
	foreach_reverse (i; 0 .. 8)
	{
		b[i] = cast(ubyte)(v & 0xff);
		v >>= 8;
	}
}

private long getLong(const(ubyte)[] b) pure @safe nothrow @nogc
in (b.length == 8)
{
	long v;
	foreach (x; b)
		v = (v << 8) | x;
	return v;
}

// ---- tests ----------------------------------------------------------------------------

unittest
{
	// a control, a chunk and an ack, delivered in awkward slices, come back intact and in order
	ubyte[32] sha;
	foreach (i, ref x; sha)
		x = cast(ubyte) i;
	auto data = new ubyte[maxChunk];
	foreach (i, ref x; data)
		x = cast(ubyte)(i * 3);

	ubyte[] wire = encodeControl(`{"m":"library.import","probe":true}`)
		~ encodeChunk(7, sha, 131_072, data)
		~ encodeAck(7, 131_072 + maxChunk, AckStatus.ok);

	FrameDecoder d;
	Frame f;
	// slice 1: a few header bytes only
	d.feed(wire[0 .. 3]);
	assert(!d.next(f));
	// slice 2: through the middle of the chunk
	d.feed(wire[3 .. 5000]);
	assert(d.next(f) && f.type == typeControl && cast(string) f.payload == `{"m":"library.import","probe":true}`);
	assert(!d.next(f));
	// slice 3: the rest
	d.feed(wire[5000 .. $]);
	assert(d.next(f) && f.type == typeChunk);
	const(ubyte)[] got;
	auto h = decodeChunk(f.payload, got);
	assert(h.ticket == 7 && h.offset == 131_072 && h.size == maxChunk && h.sha256 == sha && got == data);
	assert(d.next(f) && f.type == typeAck);
	auto a = decodeAck(f.payload);
	assert(a.ticket == 7 && a.offset == 131_072 + maxChunk && a.status == AckStatus.ok);
	assert(!d.next(f) && d.pending() == 0);
}

unittest
{
	// limits: an oversized chunk is refused at encode; a hostile length is refused at decode
	import std.exception : assertThrown;

	ubyte[32] sha;
	assertThrown(encodeChunk(1, sha, 0, new ubyte[maxChunk + 1]));

	FrameDecoder d;
	ubyte[4] bad;
	putUint(bad[], cast(uint)(maxFrame + 1));
	d.feed(bad[]);
	Frame f;
	assertThrown(d.next(f));

	// a chunk whose declared size disagrees with its bytes is refused
	auto ok = encodeChunk(1, sha, 0, new ubyte[10]);
	FrameDecoder d2;
	d2.feed(ok);
	assert(d2.next(f));
	const(ubyte)[] data;
	assertThrown(decodeChunk(f.payload[0 .. $ - 1], data));
}
