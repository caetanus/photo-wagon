/// Partially-received pushes, spooled to disk by sha256, so an interrupted transfer resumes
/// from where it stopped instead of restarting the whole file.
///
/// This is the transport-agnostic half of resumable push. The push handler (libp2p today,
/// udx tomorrow) calls `append` for each slice as it lands; the phone asks `have` to learn
/// the resume offset; the `library.import {complete:true}` claim calls `finish`, which
/// verifies the sha256 of the whole file before handing the bytes over. A death mid-stream
/// therefore keeps every byte that arrived — the old stash discarded them all.
module photowagon.core.store.partials;

import std.algorithm : all;
import std.ascii : isHexDigit;
import std.conv : to;
import std.file : exists, getSize, mkdirRecurse, read, remove, write, fappend = append;
import std.path : buildPath;
import std.string : toLower;

import vibe.core.sync : TaskMutex;

import photowagon.core.store.store : sha256Hex;

final class PartialStore
{
	private string dir;
	private TaskMutex m;

	/// Spools under `<dataDir>/imports/.partial/`.
	this(string dataDir)
	{
		dir = buildPath(dataDir, "imports", ".partial");
		mkdirRecurse(dir);
		m = new TaskMutex;
	}

	/// How many bytes of `sha` have already landed — the offset to resume from (0 = none).
	long have(string sha)
	{
		immutable p = pathOf(sha);
		synchronized (m)
			return p.exists ? cast(long) getSize(p) : 0;
	}

	/// Appends a slice that starts at `offset`. Refuses one that does not continue the
	/// spooled file (out of order, or a stale sender that did not re-probe): the caller
	/// should re-probe and resume from `have`.
	void append(string sha, long offset, const(ubyte)[] bytes)
	{
		immutable p = pathOf(sha);
		synchronized (m)
		{
			immutable cur = p.exists ? cast(long) getSize(p) : 0;
			if (offset != cur)
				throw new Exception("partial: offset " ~ offset.to!string ~ " does not continue the " ~ cur.to!string ~ " bytes spooled");
			if (cur == 0)
				write(p, bytes);
			else
				fappend(p, bytes);
		}
	}

	/// The whole file for `sha`, verified against its hash. The spool is removed either way:
	/// a mismatch means the bytes are garbage and the phone must send again from 0.
	ubyte[] finish(string sha)
	{
		immutable p = pathOf(sha);
		ubyte[] bytes;
		synchronized (m)
		{
			if (!p.exists)
				throw new Exception("partial: nothing received for " ~ sha);
			bytes = cast(ubyte[]) read(p);
			remove(p);
		}
		if (sha256Hex(bytes).toLower != sha.toLower)
			throw new Exception("partial: sha256 mismatch after " ~ bytes.length.to!string ~ " bytes, discarded");
		return bytes;
	}

	/// Drops whatever landed for `sha` (the phone gave up, or the user deleted the photo).
	void discard(string sha)
	{
		immutable p = pathOf(sha);
		synchronized (m)
			if (p.exists)
				remove(p);
	}

	// The sha is user-controlled input that becomes a file name: only 64 hex chars pass.
	private string pathOf(string sha)
	{
		if (sha.length != 64 || !sha.all!isHexDigit)
			throw new Exception("partial: sha256 must be 64 hex characters");
		return buildPath(dir, sha.toLower ~ ".part");
	}
}

unittest
{
	import std.file : tempDir, rmdirRecurse;
	import std.digest.sha : sha256Of;
	import std.digest : toHexString, LetterCase;

	auto d = buildPath(tempDir, "pw-partials-ut");
	scope (exit)
		if (d.exists)
			rmdirRecurse(d);
	auto st = new PartialStore(d);

	ubyte[] file = new ubyte[300_000];
	foreach (i, ref b; file)
		b = cast(ubyte)(i * 7);
	immutable sha = toHexString!(LetterCase.lower)(sha256Of(file)).idup;

	assert(st.have(sha) == 0);
	st.append(sha, 0, file[0 .. 100_000]);
	assert(st.have(sha) == 100_000);
	// a stale sender that did not re-probe is refused, nothing is lost
	bool refused;
	try
		st.append(sha, 50_000, file[50_000 .. 60_000]);
	catch (Exception)
		refused = true;
	assert(refused && st.have(sha) == 100_000);
	st.append(sha, 100_000, file[100_000 .. $]);
	auto got = st.finish(sha);
	assert(got == file);
	assert(st.have(sha) == 0);   // spool gone

	// a corrupted spool is refused on finish and discarded
	st.append(sha, 0, file[0 .. 1000]);
	bool bad;
	try
		st.finish(sha);
	catch (Exception)
		bad = true;
	assert(bad && st.have(sha) == 0);
}
