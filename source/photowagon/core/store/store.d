/// Content-addressed blob store: `store/ab/cdef…` keyed by sha256 hex.
///
/// Every function here is a free function of (root, bytes) so it can run on a
/// worker thread; `ContentStore` is the convenience wrapper over one root.
module photowagon.core.store.store;

import std.digest.sha : SHA256, toHexString, LetterCase;
import std.file : exists, mkdirRecurse, read, rename, write, remove;
import std.path : buildPath, dirName;

string sha256Hex(const(ubyte)[] bytes) pure
{
	SHA256 h;
	h.start();
	h.put(bytes);
	return toHexString!(LetterCase.lower)(h.finish()).idup;
}

/// `root/ab/cdef…` for a 64-char hex hash.
string blobPath(string root, string hash) pure
{
	assert(hash.length >= 3);
	return buildPath(root, hash[0 .. 2], hash[2 .. $]);
}

/// Writes `bytes` under its hash unless already present. Returns the hash.
/// Atomic: written to a sibling temp file and renamed into place.
string storeBytes(string root, const(ubyte)[] bytes)
{
	immutable hash = sha256Hex(bytes);
	immutable path = blobPath(root, hash);
	if (!path.exists)
	{
		mkdirRecurse(path.dirName);
		import std.conv : to;
		import core.thread : Thread;

		immutable tmp = path ~ ".tmp." ~ (cast(size_t) Thread.getThis().id).to!string;
		write(tmp, bytes);
		try
			rename(tmp, path);
		catch (Exception e)
		{
			// lost a race with another writer of the same content: fine
			if (tmp.exists)
				remove(tmp);
			if (!path.exists)
				throw e;
		}
	}
	return hash;
}

final class ContentStore
{
	immutable string root;

	this(string root)
	{
		this.root = root;
		mkdirRecurse(root);
	}

	string put(const(ubyte)[] bytes)
	{
		return storeBytes(root, bytes);
	}

	bool has(string hash) const
	{
		return blobPath(root, hash).exists;
	}

	string pathFor(string hash) const pure
	{
		return blobPath(root, hash);
	}

	/// Throws if missing.
	ubyte[] get(string hash) const
	{
		return cast(ubyte[]) read(blobPath(root, hash));
	}

	string fileUrl(string hash) const pure
	{
		return "file://" ~ blobPath(root, hash);
	}
}

unittest
{
	import std.file : tempDir, rmdirRecurse;
	import std.conv : to;
	import std.random : uniform;

	immutable dir = buildPath(tempDir, "pw-store-" ~ uniform(0, int.max).to!string);
	scope (exit)
		if (dir.exists)
			rmdirRecurse(dir);
	auto s = new ContentStore(dir);
	immutable h = s.put(cast(ubyte[]) "hello");
	assert(h == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
	assert(s.has(h));
	assert(s.get(h) == cast(ubyte[]) "hello");
	assert(s.put(cast(ubyte[]) "hello") == h);
	assert(s.pathFor(h) == buildPath(dir, "2c", h[2 .. $]));
}
