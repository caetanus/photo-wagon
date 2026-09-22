/// Pieces — the transfer layer that a shared album will run on: every file is addressed by
/// its sha256, cut into fixed 1 MiB pieces each with its own sha256, and a node keeps, per
/// file, the pieces it HAS (a bitfield) — so bytes can come from any peer, in any order,
/// and be verified piece by piece. Phone→computer sync and computer→phone downloads are the
/// two-node case of the same protocol; the desktop is just the seeder that has everything.
///
/// Requests ride a stream on `/photowagon/piece/1.0.0`, as many as the asker likes, one after
/// another (a transfer keeps one stream open for its whole run); both directions, big-endian:
///   op 1 INFO     → (32 sha)                       ← status, (long size), (32 × n piece hashes)
///   op 2 HAVE     → (32 sha)                       ← status, (long size), (bitfield ⌈n/8⌉ bytes)
///   op 3 GET      → (32 sha)(u32 index)            ← status, (u8 proofLen)(32 × proofLen)(piece bytes)
///   op 4 MANIFEST → (32 sha)(long size)(32 × n)    ← status          (tell the peer the pieces)
///   op 5 PUT      → (32 sha)(u32 index)(u32 len)(bytes) ← status     (the peer verifies it)
/// status: 0 ok · 1 unknown file · 2 refused · 3 bad piece · 4 have nothing yet (HAVE only)
/// A PUT is accepted only for a file whose manifest the peer already holds (MANIFEST first).
///
/// On disk, a PieceStore keeps `<dir>/<sha>.data` (the file, written piece by piece),
/// `<sha>.manifest` (size + piece hashes) and `<sha>.have` (the bitfield); `finish` verifies
/// the whole-file sha256 and hands the bytes/path over. Complete files a node serves come
/// from a `Source` (the library on the desktop, the camera roll on the phone).
module photowagon.core.sync.pieces;

import std.algorithm : all, min;
import std.ascii : isHexDigit;
import std.conv : to;
import std.digest : toHexString, LetterCase;
import std.digest.sha : SHA256, sha256Of;
import std.exception : enforce;
import std.file : exists, getSize, mkdirRecurse, read, remove, rename, write;
import std.path : buildPath;
import std.string : toLower;

import vibe.core.file : openFile, FileMode, FileStream;
import vibe.core.sync : TaskMutex;

import libp2p.core.stream : Stream, readExact;

enum pieceProtocol = "/photowagon/piece/1.0.0";
enum pieceSize = 1024 * 1024;
enum maxPiecesPerFile = 4096;   // 4 GiB per file, plenty for a camera video

enum PieceOp : ubyte { info = 1, have = 2, get = 3, manifest = 4, put = 5, thumb = 6 }
enum PieceStatus : ubyte { ok = 0, unknown = 1, refused = 2, badPiece = 3, nothingYet = 4 }

/// What a file is, for transfer purposes: its size and the sha256 of each piece.
struct Manifest
{
	long size;
	ubyte[32][] pieces;

	uint count() const pure @safe nothrow @nogc { return cast(uint) pieces.length; }

	/// Bytes in piece `i` (the last one may be short).
	uint lengthOf(uint i) const pure @safe nothrow @nogc
	{
		immutable start = cast(long) i * pieceSize;
		immutable rest = size - start;
		return cast(uint)(rest < pieceSize ? rest : pieceSize);
	}

	static uint countFor(long size) pure @safe nothrow @nogc
	{
		return cast(uint)((size + pieceSize - 1) / pieceSize);
	}

	/// The Merkle root over the pieces — the file's authenticator in a swarm: a peer that
	/// trusts this one hash can verify any piece from anyone (with its proof) without
	/// trusting whoever sent the piece list. Empty file → all-zero root.
	ubyte[32] merkleRoot() const
	{
		return MerkleTree(pieces).root;
	}
}

/// A Merkle tree over the pieces, kept as a HEAP-indexed array — a complete binary tree needs
/// no pointers: leaves padded up to a power of two, `nodes[0]` the root, children of `k` at
/// `2k+1`/`2k+2`. Each parent is `sha256(left ~ right)`; a leaf is a piece's own sha256. A
/// proof for piece `i` is the sibling hash at each level up to the root — `log2(n)` hashes —
/// and `verify` recomputes the root from a piece and its proof. Building is O(n) hashes.
struct MerkleTree
{
	ubyte[32][] nodes;   // heap layout: root at 0, internal in [0 .. leafBase-1], leaves from leafBase
	uint leaves;         // real piece count (before padding)
	uint leafBase;       // index of the first leaf = (padded count) - 1

	this(const ubyte[32][] pieceHashes)
	{
		leaves = cast(uint) pieceHashes.length;
		if (leaves == 0)
			return;
		uint padded = 1;
		while (padded < leaves)
			padded <<= 1;
		leafBase = padded - 1;
		nodes = new ubyte[32][](2 * padded - 1);
		// leaves: the real ones, then zero-hash padding (BitTorrent-v2 style)
		foreach (i; 0 .. leaves)
			nodes[leafBase + i] = pieceHashes[i];
		// internal nodes, bottom-up
		if (leafBase > 0)
			foreach_reverse (k; 0 .. leafBase)
				nodes[k] = hashPair(nodes[2 * k + 1], nodes[2 * k + 2]);
	}

	ubyte[32] root() const pure @safe nothrow @nogc
	{
		return nodes.length ? nodes[0] : ubyte[32].init;
	}

	/// The sibling hashes from piece `i`'s leaf up to (not including) the root.
	ubyte[32][] proof(uint i) const
	{
		ubyte[32][] out_;
		uint k = leafBase + i;
		while (k > 0)
		{
			immutable sib = (k % 2 == 1) ? k + 1 : k - 1;   // odd = left child, sibling is right
			out_ ~= nodes[sib];
			k = (k - 1) / 2;
		}
		return out_;
	}

	/// Recompute the root from piece `i` (of `total` pieces) given its hash and proof.
	static ubyte[32] rootFrom(uint i, uint total, const ubyte[32] leafHash, const ubyte[32][] proof) pure @safe nothrow
	{
		uint padded = 1;
		while (padded < total)
			padded <<= 1;
		uint k = (padded - 1) + i;
		ubyte[32] acc = leafHash;
		foreach (sib; proof)
		{
			acc = (k % 2 == 1) ? hashPair(acc, sib) : hashPair(sib, acc);   // odd = we are the left child
			k = (k - 1) / 2;
		}
		return acc;
	}
}

private ubyte[32] hashPair(const ubyte[32] a, const ubyte[32] b) pure @safe nothrow @nogc
{
	SHA256 h;
	h.start();
	h.put(a[]);
	h.put(b[]);
	return h.finish();
}

/// The manifest of a complete local file: hashes every piece (streaming, 1 MiB at a time).
Manifest manifestOf(string path)
{
	Manifest m;
	m.size = cast(long) getSize(path);
	auto fh = openFile(path, FileMode.read);
	scope (exit)
		fh.close();
	auto buf = new ubyte[pieceSize];
	long left = m.size;
	while (left > 0)
	{
		immutable n = cast(size_t)(left < pieceSize ? left : pieceSize);
		fh.read(buf[0 .. n]);
		m.pieces ~= sha256Of(buf[0 .. n]);
		left -= n;
	}
	return m;
}

/// Which pieces of a file a node has: one bit per piece.
struct Bitfield
{
	ubyte[] bits;
	uint count;

	this(uint count)
	{
		this.count = count;
		bits = new ubyte[(count + 7) / 8];
	}

	bool has(uint i) const pure @safe nothrow @nogc
	{
		return i < count && (bits[i / 8] & (0x80 >> (i % 8))) != 0;
	}

	void set(uint i) pure @safe nothrow @nogc
	{
		if (i < count)
			bits[i / 8] |= cast(ubyte)(0x80 >> (i % 8));
	}

	uint haveCount() const pure @safe nothrow @nogc
	{
		uint n;
		foreach (i; 0 .. count)
			if (has(i))
				n++;
		return n;
	}

	bool complete() const pure @safe nothrow @nogc { return count > 0 && haveCount == count; }

	/// The first piece the peer has that we lack, or count when there is none.
	uint firstMissing(const Bitfield theirs) const pure @safe nothrow @nogc
	{
		foreach (i; 0 .. count)
			if (!has(i) && theirs.has(i))
				return i;
		return count;
	}
}

/// Where a node keeps files that are still arriving, piece by piece, across connections and
/// restarts. Thread: vibe tasks only (a TaskMutex serialises the metadata).
final class PieceStore
{
	private string dir;
	private TaskMutex m;

	this(string dir)
	{
		this.dir = dir;
		mkdirRecurse(dir);
		m = new TaskMutex;
	}

	/// The manifest we hold for `sha` (empty size 0 when none).
	Manifest manifest(string sha)
	{
		synchronized (m)
			return manifestLocked(sha);
	}

	// under the lock: the TaskMutex is not recursive, so the public methods lock once and
	// call these
	private Manifest manifestLocked(string sha)
	{
		immutable p = pathOf(sha, "manifest");
		return p.exists ? decodeManifest(cast(ubyte[]) read(p)) : Manifest.init;
	}

	private Bitfield haveLocked(string sha)
	{
		immutable p = pathOf(sha, "have");
		if (!p.exists)
			return Bitfield.init;
		auto man = manifestLocked(sha);
		Bitfield b = Bitfield(man.count);
		auto raw = cast(ubyte[]) read(p);
		if (raw.length == b.bits.length)
			b.bits = raw;
		return b;
	}

	/// Record the peer's manifest for `sha` (idempotent; a different one for the same sha
	/// means garbage on the wire and is refused).
	void adopt(string sha, const Manifest man)
	{
		enforce(man.size >= 0 && man.count == Manifest.countFor(man.size) && man.count <= maxPiecesPerFile,
			"pieces: manifest does not fit its size");
		immutable p = pathOf(sha, "manifest");
		synchronized (m)
		{
			if (p.exists)
			{
				auto cur = decodeManifest(cast(ubyte[]) read(p));
				enforce(cur.size == man.size && cur.pieces == man.pieces, "pieces: a different manifest for the same file");
				return;
			}
			write(p, encodeManifest(man));
			write(pathOf(sha, "have"), Bitfield(man.count).bits);
			// the data file is created at full size so pieces can land in any order
			auto fh = openFile(pathOf(sha, "data"), FileMode.createTrunc);
			if (man.size > 0)
			{
				fh.seek(man.size - 1);
				fh.write([cast(ubyte) 0]);
			}
			fh.close();
		}
	}

	Bitfield have(string sha)
	{
		synchronized (m)
			return haveLocked(sha);
	}

	/// Store piece `i` if it hashes right; true when it was new.
	bool store(string sha, uint i, const(ubyte)[] bytes)
	{
		auto man = manifest(sha);
		enforce(man.count > 0, "pieces: no manifest for " ~ sha);
		enforce(i < man.count && bytes.length == man.lengthOf(i), "pieces: piece " ~ i.to!string ~ " has the wrong length");
		enforce(sha256Of(bytes) == man.pieces[i], "pieces: piece " ~ i.to!string ~ " does not match its hash");
		synchronized (m)
		{
			auto b = haveLocked(sha);
			if (b.has(i))
				return false;
			auto fh = openFile(pathOf(sha, "data"), FileMode.readWrite);
			fh.seek(cast(long) i * pieceSize);
			fh.write(bytes);
			fh.close();
			b.set(i);
			write(pathOf(sha, "have"), b.bits);
			return true;
		}
	}

	/// Piece `i` of a file we hold (complete or not; the caller checked `have`).
	ubyte[] piece(string sha, uint i)
	{
		auto man = manifest(sha);
		enforce(man.count > i, "pieces: no such piece");
		auto out_ = new ubyte[man.lengthOf(i)];
		synchronized (m)
		{
			auto fh = openFile(pathOf(sha, "data"), FileMode.read);
			scope (exit)
				fh.close();
			fh.seek(cast(long) i * pieceSize);
			fh.read(out_);
		}
		return out_;
	}

	bool complete(string sha) { return have(sha).complete; }

	/// The finished file: verified against `sha` as a whole and moved to `dest` (or kept in
	/// the store and its path returned when `dest` is null); metadata is dropped. A mismatch
	/// discards everything — the pieces were consistent with a wrong manifest.
	string finish(string sha, string dest = null)
	{
		enforce(complete(sha), "pieces: file is not complete");
		immutable data = pathOf(sha, "data");
		SHA256 h;
		h.start();
		{
			auto fh = openFile(data, FileMode.read);
			scope (exit)
				fh.close();
			auto buf = new ubyte[pieceSize];
			long left = cast(long) fh.size;
			while (left > 0)
			{
				immutable n = cast(size_t)(left < pieceSize ? left : pieceSize);
				fh.read(buf[0 .. n]);
				h.put(buf[0 .. n]);
				left -= n;
			}
		}
		immutable got = toHexString!(LetterCase.lower)(h.finish()[]).idup;
		if (got != sha.toLower)
		{
			discard(sha);
			throw new Exception("pieces: whole-file sha256 mismatch, discarded");
		}
		synchronized (m)
		{
			if (dest !is null)
			{
				import std.path : dirName;

				mkdirRecurse(dest.dirName);   // the move must not fail after we drop the metadata
				if (dest.exists)
					remove(dest);
				rename(data, dest);
			}
			remove(pathOf(sha, "manifest"));
			remove(pathOf(sha, "have"));
			return dest is null ? data : dest;
		}
	}

	void discard(string sha)
	{
		synchronized (m)
			foreach (kind; ["data", "manifest", "have"])
			{
				immutable p = pathOf(sha, kind);
				if (p.exists)
					remove(p);
			}
	}

	private string pathOf(string sha, string kind)
	{
		enforce(sha.length == 64 && sha.all!isHexDigit, "pieces: sha256 must be 64 hex characters");
		return buildPath(dir, sha.toLower ~ "." ~ kind);
	}
}

// ---- wire ---------------------------------------------------------------------------

ubyte[] encodeManifest(const Manifest m)
{
	ubyte[] out_ = longToBe(m.size)[].dup;
	foreach (p; m.pieces)
		out_ ~= p[];
	return out_;
}

Manifest decodeManifest(const(ubyte)[] raw)
{
	enforce(raw.length >= 8 && (raw.length - 8) % 32 == 0, "pieces: bad manifest");
	Manifest m;
	m.size = beToLong(raw[0 .. 8]);
	foreach (i; 0 .. (raw.length - 8) / 32)
	{
		ubyte[32] p = raw[8 + i * 32 .. 8 + (i + 1) * 32];
		m.pieces ~= p;
	}
	enforce(m.count == Manifest.countFor(m.size), "pieces: manifest does not fit its size");
	return m;
}

ubyte[8] longToBe(long v) @safe @nogc nothrow pure
{
	ubyte[8] b;
	foreach_reverse (i; 0 .. 8)
	{
		b[i] = cast(ubyte)(v & 0xff);
		v >>= 8;
	}
	return b;
}

long beToLong(const(ubyte)[] b) @safe @nogc nothrow pure
{
	long v = 0;
	foreach (x; b[0 .. 8])
		v = (v << 8) | x;
	return v;
}

ubyte[4] uintToBe(uint v) @safe @nogc nothrow pure
{
	return [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
}

uint beToUint(const(ubyte)[] b) @safe @nogc nothrow pure
{
	return (cast(uint) b[0] << 24) | (cast(uint) b[1] << 16) | (cast(uint) b[2] << 8) | b[3];
}

ubyte[32] shaBytes(string hex)
{
	enforce(hex.length == 64, "pieces: sha256 must be 64 hex characters");
	ubyte[32] out_;
	foreach (i; 0 .. 32)
		out_[i] = cast(ubyte) hex[2 * i .. 2 * i + 2].to!int(16);
	return out_;
}

string shaHex(const ubyte[32] raw)
{
	return toHexString!(LetterCase.lower)(raw[]).idup;
}

// ---- the serving side ------------------------------------------------------------------

/// Where a node's COMPLETE files come from: the path of the file with that sha256, or null.
alias Source = string delegate(string sha);
/// Thumbnail bytes (JPEG) for a photo id, or null when there is none. Served by the
/// THUMB op as raw bytes on the piece stream — never base64 inside JSON.
alias ThumbSource = const(ubyte)[] delegate(long photoId);
/// Largest THUMB batch one request may carry (matches library.thumbs).
enum maxThumbBatch = 200;

/// Serves one `/photowagon/piece/1.0.0` request. `source` answers for complete files,
/// `store` for the ones still arriving (and receives PUTs). `admitted` is the caller's say
/// on who may ask at all. Cheap manifests of complete files are cached by sha.
final class PieceService
{
	private Source source;
	private PieceStore store;
	private ThumbSource thumbs;   // photo id → thumbnail JPEG (null: THUMB answers "none")

	/// Serve thumbnails over this service: `t` maps a photo id to its JPEG bytes.
	void serveThumbsFrom(ThumbSource t) { thumbs = t; }
	private Manifest[string] cache;   // complete files' manifests (vibe thread)
	private enum size_t cacheMax = 64;

	this(Source source, PieceStore store)
	{
		this.source = source;
		this.store = store;
	}

	private Manifest manifestFor(string sha, string path)
	{
		if (auto c = sha in cache)
			return *c;
		auto m = manifestOf(path);
		if (cache.length >= cacheMax)
			cache.clear();
		cache[sha] = m;
		return m;
	}

	/// Requests on one stream, one after another, until the peer closes it.
	void serve(Stream s)
	{
		while (true)
		{
			ubyte[1] opb;
			try
				s.readExact(opb[]);
			catch (Exception)
				return;   // the peer is done with this stream
			if (opb[0] == PieceOp.thumb)
				serveThumbs(s);   // keyed by photo id, not by sha: its own framing
			else
				serveOne(s, opb[0]);
		}
	}

	/// THUMB: `u32 count, count × u64 photoId` in; for each id, in order, `u32 len` then
	/// `len` raw JPEG bytes out (len 0 = no thumbnail). Raw bytes on the wire: no base64,
	/// no JSON frame to hold a whole page of images at once.
	private void serveThumbs(Stream s)
	{
		ubyte[4] cb;
		s.readExact(cb[]);
		immutable count = beToUint(cb);
		if (count > maxThumbBatch)
			throw new Exception("pieces: thumb batch too large");
		long[] ids;
		foreach (_; 0 .. count)
		{
			ubyte[8] ib;
			s.readExact(ib[]);
			ids ~= beToLong(ib[]);
		}
		size_t served, bytes;
		foreach (id; ids)
		{
			const(ubyte)[] jpeg;
			if (thumbs !is null)
				try
					jpeg = thumbs(id);
				catch (Exception)
					jpeg = null;
			s.write(uintToBe(cast(uint) jpeg.length)[] ~ jpeg);
			if (jpeg.length)
			{
				served++;
				bytes += jpeg.length;
			}
		}
		import vibe.core.log : logInfo;
		logInfo("pieces: THUMB served %s/%s thumbnails, %s bytes raw (no base64)", served, ids.length, bytes);
	}

	private void serveOne(Stream s, ubyte op)
	{
		ubyte[1] opb = [op];
		ubyte[32] shaRaw;
		s.readExact(shaRaw[]);
		immutable sha = shaHex(shaRaw);
		immutable complete = source !is null ? source(sha) : null;
		final switch (cast(PieceOp) opb[0])
		{
		case PieceOp.thumb:
			// never reached: serve() hands THUMB to serveThumbs before the sha read above;
			// listed only because a final switch must name every PieceOp member.
			return;
		case PieceOp.info:
			Manifest m;
			if (complete !is null)
				m = manifestFor(sha, complete);
			else if (store !is null)
				m = store.manifest(sha);
			if (m.count == 0)
			{
				s.write([PieceStatus.unknown]);
				return;
			}
			s.write(cast(ubyte[])[PieceStatus.ok] ~ encodeManifest(m));
			return;
		case PieceOp.have:
			if (complete !is null)
			{
				auto m = manifestFor(sha, complete);
				Bitfield b = Bitfield(m.count);
				foreach (i; 0 .. m.count)
					b.set(i);
				s.write(cast(ubyte[])[PieceStatus.ok] ~ longToBe(m.size)[] ~ b.bits);
				return;
			}
			if (store is null || store.manifest(sha).count == 0)
			{
				s.write([PieceStatus.nothingYet]);
				return;
			}
			auto m = store.manifest(sha);
			s.write(cast(ubyte[])[PieceStatus.ok] ~ longToBe(m.size)[] ~ store.have(sha).bits);
			return;
		case PieceOp.get:
			ubyte[4] ib;
			s.readExact(ib[]);
			immutable i = beToUint(ib);
			Manifest gman;
			ubyte[] bytes;
			if (complete !is null)
			{
				gman = manifestFor(sha, complete);
				if (i >= gman.count)
				{
					s.write([PieceStatus.badPiece]);
					return;
				}
				auto fh = openFile(complete, FileMode.read);
				scope (exit)
					fh.close();
				bytes = new ubyte[gman.lengthOf(i)];
				fh.seek(cast(long) i * pieceSize);
				fh.read(bytes);
			}
			else if (store !is null && store.have(sha).has(i))
			{
				gman = store.manifest(sha);
				bytes = store.piece(sha, i);
			}
			else
			{
				s.write([PieceStatus.unknown]);
				return;
			}
			auto proof = MerkleTree(gman.pieces).proof(i);   // the sibling hashes up to the root
			ubyte[] hdr = [cast(ubyte) PieceStatus.ok, cast(ubyte) proof.length];
			foreach (h; proof)
				hdr ~= h[];
			s.write(hdr ~ bytes);
			return;
		case PieceOp.manifest:
			ubyte[8] sz;
			s.readExact(sz[]);
			immutable size = beToLong(sz);
			immutable n = Manifest.countFor(size);
			if (store is null || size < 0 || n > maxPiecesPerFile)
			{
				s.write([PieceStatus.refused]);
				return;
			}
			auto raw = new ubyte[8 + 32 * n];
			raw[0 .. 8] = sz[];
			s.readExact(raw[8 .. $]);
			if (complete !is null)
			{
				s.write([PieceStatus.ok]);   // we have the whole file already; nothing to receive
				return;
			}
			try
				store.adopt(sha, decodeManifest(raw));
			catch (Exception)
			{
				s.write([PieceStatus.refused]);
				return;
			}
			s.write([PieceStatus.ok]);
			return;
		case PieceOp.put:
			ubyte[4] ib, lb;
			s.readExact(ib[]);
			s.readExact(lb[]);
			immutable i = beToUint(ib), len = beToUint(lb);
			if (store is null || len > pieceSize)
			{
				s.write([PieceStatus.refused]);
				return;
			}
			auto bytes = new ubyte[len];
			s.readExact(bytes);
			if (complete !is null)
			{
				s.write([PieceStatus.ok]);
				return;
			}
			try
				store.store(sha, i, bytes);
			catch (Exception)
			{
				s.write([PieceStatus.badPiece]);
				return;
			}
			s.write([PieceStatus.ok]);
			return;
		}
	}
}

// ---- the asking side --------------------------------------------------------------------

private ubyte readStatus(Stream s)
{
	ubyte[1] st;
	s.readExact(st[]);
	return st[0];
}

/// THUMB: the peer's thumbnails for `ids`, as raw JPEG bytes. `onThumb` fires once per id
/// that has one (ids without a thumbnail are skipped). Never base64.
void askThumbs(Stream s, const long[] ids, void delegate(long id, const(ubyte)[] jpeg) onThumb)
{
	enforce(ids.length <= maxThumbBatch, "pieces: thumb batch too large");
	ubyte[] req = cast(ubyte[])[PieceOp.thumb] ~ uintToBe(cast(uint) ids.length)[];
	foreach (id; ids)
		req ~= longToBe(id)[];
	s.write(req);
	// A thumbnail is small; cap what a peer can make us allocate per id (peer-controlled
	// length, Codex review #3) — anything larger is a bad/hostile reply, so give up.
	enum maxThumbBytes = 4 * 1024 * 1024;
	foreach (id; ids)
	{
		ubyte[4] lb;
		s.readExact(lb[]);
		immutable len = beToUint(lb);
		if (len == 0)
			continue;
		enforce(len <= maxThumbBytes, "pieces: thumbnail too large (" ~ len.to!string ~ " bytes)");
		auto bytes = new ubyte[len];
		s.readExact(bytes);
		if (onThumb !is null)
			onThumb(id, bytes);
	}
}

/// INFO: the peer's manifest for `sha` (count 0 when it does not know the file).
Manifest askInfo(Stream s, string sha)
{
	s.write(cast(ubyte[])[PieceOp.info] ~ shaBytes(sha)[]);
	if (readStatus(s) != PieceStatus.ok)
		return Manifest.init;
	ubyte[8] sz;
	s.readExact(sz[]);
	immutable size = beToLong(sz);
	auto raw = new ubyte[8 + 32 * Manifest.countFor(size)];
	raw[0 .. 8] = sz[];
	s.readExact(raw[8 .. $]);
	return decodeManifest(raw);
}

/// HAVE: which pieces the peer has (count 0 when it has nothing / knows nothing).
Bitfield askHave(Stream s, string sha, uint count)
{
	s.write(cast(ubyte[])[PieceOp.have] ~ shaBytes(sha)[]);
	if (readStatus(s) != PieceStatus.ok)
		return Bitfield.init;
	ubyte[8] sz;
	s.readExact(sz[]);
	Bitfield b = Bitfield(count);
	s.readExact(b.bits);
	return b;
}

/// GET: piece `i` of `sha`. Verified two ways: its bytes hash to a leaf, and that leaf +
/// the proof rebuild the manifest's Merkle root — so bytes from ANY peer are trusted against
/// the one root we hold, not against whoever sent them.
ubyte[] askPiece(Stream s, string sha, const Manifest man, uint i)
{
	s.write(cast(ubyte[])[PieceOp.get] ~ shaBytes(sha)[] ~ uintToBe(i)[]);
	enforce(readStatus(s) == PieceStatus.ok, "pieces: peer has no piece " ~ i.to!string);
	ubyte[1] plen;
	s.readExact(plen[]);
	ubyte[32][] proof;
	foreach (_; 0 .. plen[0])
	{
		ubyte[32] h;
		s.readExact(h[]);
		proof ~= h;
	}
	auto bytes = new ubyte[man.lengthOf(i)];
	s.readExact(bytes);
	immutable leaf = sha256Of(bytes);
	enforce(leaf == man.pieces[i], "pieces: piece " ~ i.to!string ~ " does not hash to the manifest leaf");
	enforce(MerkleTree.rootFrom(i, man.count, leaf, proof) == man.merkleRoot,
		"pieces: piece " ~ i.to!string ~ " proof does not rebuild the Merkle root");
	return bytes;
}

/// MANIFEST: tell the peer what `sha` is, so it can take PUTs. True when accepted.
bool tellManifest(Stream s, string sha, const Manifest man)
{
	s.write(cast(ubyte[])[PieceOp.manifest] ~ shaBytes(sha)[] ~ encodeManifest(man));
	return readStatus(s) == PieceStatus.ok;
}

/// PUT: hand piece `i` to the peer. True when it took it.
bool givePiece(Stream s, string sha, uint i, const(ubyte)[] bytes)
{
	s.write(cast(ubyte[])[PieceOp.put] ~ shaBytes(sha)[] ~ uintToBe(i)[] ~ uintToBe(cast(uint) bytes.length)[] ~ bytes);
	return readStatus(s) == PieceStatus.ok;
}

unittest
{
	// THUMB round-trip over the mux, in memory: the serving side hands out thumbnails by
	// photo id as raw bytes; the asking side wants three ids, only one of which has one.
	import photowagon.core.sync.muxstream : MuxSession, MuxStream;
	import vibe.core.core : runTask, runEventLoop, exitEventLoop;

	auto jpeg = new ubyte[300];
	foreach (i, ref b; jpeg)
		b = cast(ubyte)(i * 13 + 5);
	const(ubyte)[] src(long id) { return id == 7 ? jpeg : null; }
	auto svc = new PieceService(null, null);
	svc.serveThumbsFrom(&src);

	MuxSession a, b;
	a = new MuxSession((const(ubyte)[] f) nothrow { try b.feed(f); catch (Exception) {} }, true, null);
	b = new MuxSession((const(ubyte)[] f) nothrow { try a.feed(f); catch (Exception) {} }, false,
		(MuxStream s) nothrow {
			try runTask(() nothrow { try svc.serve(s); catch (Exception) {} });
			catch (Exception) {}
		});

	bool ok;
	runTask(() nothrow {
		try
		{
			ubyte[][long] got;
			auto s = a.open();
			askThumbs(s, [7L, 8L, 9L], (long id, const(ubyte)[] bytes) { got[id] = bytes.dup; });
			s.close();
			assert(got.length == 1 && 7 in got && got[7] == jpeg, "THUMB: expected exactly id 7 with its bytes");
			assert(8 !in got && 9 !in got, "THUMB: ids without a thumbnail must be skipped");
			ok = true;
		}
		catch (Exception e)
			assert(false, e.msg);
		try exitEventLoop(); catch (Exception) {}
	});
	runEventLoop();
	assert(ok, "THUMB round-trip did not complete");
}

unittest
{
	import std.file : tempDir, rmdirRecurse;

	immutable dir = buildPath(tempDir, "pw-pieces-test");
	if (dir.exists)
		rmdirRecurse(dir);
	auto data = new ubyte[pieceSize * 2 + 1234];
	foreach (i, ref b; data)
		b = cast(ubyte)(i * 7 + 3);
	immutable src = buildPath(dir, "src.bin");
	mkdirRecurse(dir);
	write(src, data);
	write(buildPath(dir, "one.bin"), data[0 .. 100]);
	immutable sha = toHexString!(LetterCase.lower)(sha256Of(data)).idup;
	auto man = manifestOf(src);
	assert(man.count == 3 && man.lengthOf(2) == 1234);
	auto st = new PieceStore(buildPath(dir, "store"));
	st.adopt(sha, man);
	assert(!st.complete(sha));
	assert(st.store(sha, 2, data[2 * pieceSize .. $]));
	assert(!st.store(sha, 2, data[2 * pieceSize .. $]));   // already there
	assert(st.store(sha, 0, data[0 .. pieceSize]));
	assert(st.have(sha).haveCount == 2 && st.have(sha).firstMissing(Bitfield.init) == 3);
	assert(st.store(sha, 1, data[pieceSize .. 2 * pieceSize]));
	assert(st.complete(sha));
	immutable out_ = st.finish(sha, buildPath(dir, "out.bin"));
	assert(cast(ubyte[]) read(out_) == data);

	// Merkle: every piece + its proof must rebuild the same root, a forged piece must not.
	auto tree = MerkleTree(man.pieces);
	immutable root = man.merkleRoot;
	assert(root == tree.root);
	foreach (i; 0 .. man.count)
	{
		auto pf = tree.proof(i);
		assert(MerkleTree.rootFrom(i, man.count, man.pieces[i], pf) == root);
		ubyte[32] bad = man.pieces[i];
		bad[0] ^= 0xff;
		assert(MerkleTree.rootFrom(i, man.count, bad, pf) != root);
	}
	// a single-piece file: root == the only leaf, empty proof
	auto one = manifestOf(buildPath(dir, "one.bin"));
	assert(one.count == 1 && one.merkleRoot == one.pieces[0] && MerkleTree(one.pieces).proof(0).length == 0);
	rmdirRecurse(dir);
}
