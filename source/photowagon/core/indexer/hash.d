/// Hashing a file by content. Worker-safe.
module photowagon.core.indexer.hash;

import std.digest.sha : SHA256, toHexString, LetterCase;
import std.stdio : File;

string sha256File(string path)
{
	SHA256 h;
	h.start();
	auto f = File(path, "rb");
	foreach (chunk; f.byChunk(1 << 20))
		h.put(chunk);
	return toHexString!(LetterCase.lower)(h.finish()).idup;
}

unittest
{
	import std.file : tempDir, write, remove;
	import std.path : buildPath;

	immutable p = buildPath(tempDir, "pw-hash-test.bin");
	write(p, "hello");
	scope (exit)
		remove(p);
	assert(sha256File(p) == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
}
