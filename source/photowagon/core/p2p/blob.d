/// `/photowagon/blob/1.0.0` — ask a peer for content by hash.
///
/// Wire: the requester writes a length-prefixed hex hash; the responder answers
/// with the length-prefixed bytes, or an empty payload for "don't have it".
/// Many requests may follow on one stream. The requester verifies every blob
/// against the hash it asked for before believing it.
module photowagon.core.p2p.blob;

import vibe.core.log : logDiagnostic, logWarn;

import libp2p.core.ending : Ending, EndOfStream;
import libp2p.core.peer_id : PeerId;
import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed;
import libp2p.host.host : Host;
import libp2p.swarm.connection : Connection;

import photowagon.core.store.store : ContentStore, sha256Hex;

enum blobProtocol = "/photowagon/blob/1.0.0";

/// 256 MiB: an original from a modern camera fits, nothing pathological does.
enum maxBlob = 256 * 1024 * 1024;

/// Serves our store to peers. Registered on the host at construction.
final class BlobServer
{
	private ContentStore store;

	this(Host host, ContentStore store)
	{
		this.store = store;
		host.setStreamHandler(blobProtocol, &serve);
	}

	private void serve(Stream s, Connection c, string protocol)
	{
		scope (exit)
			s.close();
		while (true)
		{
			ubyte[] req;
			try
				req = readLengthPrefixed(s, 128);
			catch (EndOfStream)
				return; // the peer is done asking
			immutable hash = cast(string) req.idup;
			if (!validHash(hash) || !store.has(hash))
			{
				writeLengthPrefixed(s, []);
				continue;
			}
			writeLengthPrefixed(s, store.get(hash));
		}
	}
}

class BlobMissing : Exception
{
	this(string hash)
	{
		super("peer does not have " ~ hash);
	}
}

/// One stream to one peer, reused across requests. Close when done.
struct BlobFetcher
{
	private Stream stream;

	@disable this(this);

	this(Host host, PeerId peer)
	{
		stream = host.newStream(peer, blobProtocol);
	}

	~this()
	{
		close();
	}

	/// The verified bytes of `hash`, or throws (`BlobMissing`, an `Ending`, or a hash mismatch).
	ubyte[] get(string hash)
	{
		writeLengthPrefixed(stream, cast(const(ubyte)[]) hash);
		auto data = readLengthPrefixed(stream, maxBlob);
		if (data.length == 0)
			throw new BlobMissing(hash);
		if (sha256Hex(data) != hash)
			throw new Exception("blob " ~ hash ~ " failed verification");
		return data;
	}

	void close() nothrow
	{
		if (stream !is null)
			stream.close();
		stream = null;
	}
}

bool validHash(string h) pure nothrow
{
	if (h.length != 64)
		return false;
	foreach (c; h)
		if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')))
			return false;
	return true;
}

unittest
{
	assert(validHash("2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"));
	assert(!validHash("2CF2"));
	assert(!validHash("../etc/passwd"));
}
