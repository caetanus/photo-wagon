/// The node's Ed25519 identity, persisted as a 32-byte seed with mode 0600.
module photowagon.core.p2p.identity;

import std.file : exists, read, write, setAttributes, mkdirRecurse;
import std.path : dirName;

import libp2p.crypto.keys : Keypair;

Keypair loadOrCreateIdentity(string path)
{
	ubyte[] seed;
	if (path.exists)
	{
		seed = cast(ubyte[]) read(path);
		if (seed.length != 32)
			throw new Exception("identity seed at " ~ path ~ " is not 32 bytes; refusing to guess");
	}
	else
	{
		seed = randomSeed();
		mkdirRecurse(path.dirName);
		write(path, seed);
		{ import std.conv : octal; setAttributes(path, octal!600); }
	}
	return Keypair.fromSeed(seed);
}

private ubyte[] randomSeed()
{
	import std.stdio : File;

	auto seed = new ubyte[32];
	auto f = File("/dev/urandom", "rb");
	auto got = f.rawRead(seed);
	if (got.length != 32)
		throw new Exception("short read from /dev/urandom");
	return seed;
}

unittest
{
	import std.file : tempDir, remove;
	import std.path : buildPath;

	immutable p = buildPath(tempDir, "pw-identity-ut.seed");
	if (p.exists)
		remove(p);
	scope (exit)
		remove(p);
	auto a = loadOrCreateIdentity(p);
	auto b = loadOrCreateIdentity(p);
	assert(a.publicKey.toProtobuf == b.publicKey.toProtobuf);
}
