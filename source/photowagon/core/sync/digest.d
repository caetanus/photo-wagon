/// What a node keeps about a file's content, computed once and remembered, so nothing is
/// read again to know it:
///   - sha256: the file's identity on the wire (offers, dedup, imports);
///   - pieces: the per-piece hashes (the piece protocol's manifest; the Merkle root is over
///     them), so a push never re-reads the file just to announce it;
///   - fingerprint: a cheap check that a file is still the same one — its size and the
///     sha256 of eight 4 KiB samples (two at the start, four in the middle, two at the end).
///     A rescan that sees a new mtime compares it (eight small reads) instead of re-hashing
///     the whole file; equal means "almost certainly unchanged", and the full check happens
///     the next time the file is shown or sent (a piece that does not match its manifest
///     while sending cancels the send and the digest is computed again).
module photowagon.core.sync.digest;

import std.base64 : Base64;
import std.digest : toHexString, LetterCase;
import photowagon.core.util.fastsha : SHA256, sha256Of;
import std.file : getSize;
import std.stdio : File;

import photowagon.core.sync.pieces : pieceSize;

struct FileDigest
{
	long size;
	string sha;              /// sha256 of the whole file, lower-case hex
	ubyte[32][] pieces;      /// sha256 of each pieceSize piece (the last may be short)
	string fingerprint;      /// see fingerprintOf
}

enum size_t sampleBlock = 4096;

/// The byte ranges a fingerprint samples in a file of `size`: eight 4 KiB blocks, or every
/// 4 KiB block of a file under 64 KiB (reading it whole costs no more than the samples).
private long[2][] sampleRanges(long size)
{
	immutable long b = sampleBlock;
	long[2][] r;
	if (size < 16 * b)
	{
		for (long off = 0; off < size; off += b)
			r ~= [off, off + b < size ? off + b : size];
		return r;
	}
	immutable long mid = (size / 2) / b * b;
	foreach (off; [0L, b, mid - 2 * b, mid - b, mid, mid + b, size - 2 * b, size - b])
		r ~= [off, off + b];
	return r;
}

private string fingerprintFrom(long size, const(ubyte[])[] samples)
{
	SHA256 h;
	h.start();
	ubyte[8] sz;
	foreach (i; 0 .. 8)
		sz[i] = cast(ubyte)((size >> (8 * i)) & 0xff);
	h.put(sz[]);
	foreach (s; samples)
		h.put(sha256Of(s)[]);
	return toHexString!(LetterCase.lower)(h.finish()).idup;
}

/// The size plus eight sampled 4 KiB blocks, as one hex digest (eight small reads).
string fingerprintOf(string path)
{
	immutable size = cast(long) getSize(path);
	auto f = File(path, "rb");
	const(ubyte)[][] samples;
	foreach (r; sampleRanges(size))
	{
		auto buf = new ubyte[cast(size_t)(r[1] - r[0])];
		f.seek(r[0]);
		samples ~= f.rawRead(buf);
	}
	return fingerprintFrom(size, samples);
}

/// sha256, piece hashes and fingerprint of a file, from ONE streaming pass over the same
/// bytes (one piece of memory whatever the file's size): the samples are taken from the
/// pieces as they go by, so all three describe the same content. A file whose size changes
/// while it is read throws — its digest would describe nothing.
FileDigest digestFile(string path)
{
	FileDigest d;
	d.size = cast(long) getSize(path);
	auto ranges = sampleRanges(d.size);
	auto samples = new ubyte[][ranges.length];
	foreach (i, r; ranges)
		samples[i] = new ubyte[cast(size_t)(r[1] - r[0])];
	SHA256 whole;
	whole.start();
	auto f = File(path, "rb");
	long pos;
	foreach (chunk; f.byChunk(pieceSize))
	{
		whole.put(chunk);
		d.pieces ~= sha256Of(chunk);
		immutable long end = pos + cast(long) chunk.length;
		foreach (i, r; ranges)   // copy whatever part of each sample lies in this chunk
		{
			immutable long lo = r[0] > pos ? r[0] : pos;
			immutable long hi = r[1] < end ? r[1] : end;
			if (lo < hi)
				samples[i][cast(size_t)(lo - r[0]) .. cast(size_t)(hi - r[0])] = chunk[cast(size_t)(lo - pos) .. cast(size_t)(hi - pos)];
		}
		pos = end;
	}
	if (pos != d.size || cast(long) getSize(path) != d.size)
		throw new Exception("digest: " ~ path ~ " changed while it was read");
	d.sha = toHexString!(LetterCase.lower)(whole.finish()).idup;
	d.fingerprint = fingerprintFrom(d.size, cast(const(ubyte[])[]) samples);
	return d;
}

/// digestFile's result in a form a worker thread can hand back (immutable), and the call
/// that computes it — for vibe's async(), so a big file is read off the event loop.
struct SharedDigest
{
	string sha;
	string fingerprint;
	immutable(ubyte)[] pieces;   // raw, 32 bytes each
	long size;
}

SharedDigest digestShared(string path)
{
	auto d = digestFile(path);
	return SharedDigest(d.sha, d.fingerprint, rawPieces(d.pieces).idup, d.size);
}

/// The piece hashes as raw bytes (32 each) — the database form — and back.
ubyte[] rawPieces(const(ubyte[32])[] pieces)
{
	ubyte[] raw;
	raw.reserve(pieces.length * 32);
	foreach (ref p; pieces)
		raw ~= p[];
	return raw;
}

/// ditto
ubyte[32][] piecesFromRaw(const(ubyte)[] raw)
{
	ubyte[32][] out_;
	if (raw.length % 32 != 0)
		return out_;
	foreach (i; 0 .. raw.length / 32)
	{
		ubyte[32] p = raw[i * 32 .. i * 32 + 32];
		out_ ~= p;
	}
	return out_;
}

/// The piece hashes as one base64 string (32 bytes each), for storing beside the photo.
string encodePieces(const(ubyte[32])[] pieces)
{
	ubyte[] raw;
	raw.reserve(pieces.length * 32);
	foreach (ref p; pieces)
		raw ~= p[];
	return cast(string) Base64.encode(raw);
}

/// The reverse of encodePieces; empty for an empty or malformed string.
ubyte[32][] decodePieces(string b64)
{
	ubyte[32][] out_;
	if (b64.length == 0)
		return out_;
	ubyte[] raw;
	try
		raw = Base64.decode(b64);
	catch (Exception)
		return out_;
	if (raw.length % 32 != 0)
		return out_;
	foreach (i; 0 .. raw.length / 32)
	{
		ubyte[32] p = raw[i * 32 .. i * 32 + 32];
		out_ ~= p;
	}
	return out_;
}

unittest
{
	import std.file : write, remove, tempDir;
	import std.path : buildPath;
	import std.conv : to;

	immutable p = buildPath(tempDir, "pw-digest-test-" ~ (cast(size_t)&fingerprintOf).to!string);
	scope (exit)
		remove(p);
	// small: fingerprinted whole; the streamed fingerprint equals the sampled one
	write(p, "hello");
	auto d = digestFile(p);
	assert(d.sha == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
	assert(d.pieces.length == 1 && d.size == 5);
	assert(d.fingerprint == fingerprintOf(p));
	assert(decodePieces(encodePieces(d.pieces)) == d.pieces);
	write(p, "hellp");
	assert(fingerprintOf(p) != d.fingerprint);

	// big, with a size that is not a multiple of 4 KiB (the end samples straddle nothing
	// aligned): the streamed and the sampled fingerprints agree; a change inside a sampled
	// block is seen; restoring the bytes restores the fingerprint
	auto data = new ubyte[3 * pieceSize + 123];
	foreach (i, ref x; data)
		x = cast(ubyte)(i * 31 + 7);
	write(p, data);
	auto a = digestFile(p);
	assert(a.pieces.length == 4);
	assert(a.fingerprint == fingerprintOf(p));
	data[$ - 10] ^= 0xff; // in the last sampled block
	write(p, data);
	assert(fingerprintOf(p) != a.fingerprint);
	data[$ - 10] ^= 0xff;
	write(p, data);
	assert(fingerprintOf(p) == a.fingerprint);
}
