/// The other computers this one mirrors (the user's own machines, paired once): each is
/// known by its hyperswarm public key (hex) and the pairing token of ITS library — the
/// token its topic is derived from and that its server wants in daemon.auth. Kept in
/// <data>/settings/computers.json, written atomically.
///
/// A computer is added in two steps: the code the other computer shows (`pw://<token>`) is
/// entered here — a PENDING entry, token known, key not yet — and this node dials that
/// token's topic; once the other side has accepted us, the entry gets its key and alias.
/// The other side learns us from our `mirror.hello` (key, token, alias) and keeps us too.
///
/// Which side dials after that: only the one with the smaller key (both sides announce
/// their own topic, so the other still finds the connection) — two computers dialing each
/// other at once would race two connections over the same address.
module photowagon.core.sync.computers;

import std.json;

struct Computer
{
	string key;      // hex public key; empty while pending
	string token;    // ITS pairing token
	string alias_;   // its name, as it gave it
	long addedAt;    // unix seconds
}

final class ComputerPeers
{
	private string path;
	private Computer[] items;

	this(string path)
	{
		this.path = path;
		load();
	}

	Computer[] list()
	{
		return items.dup;
	}

	Computer* byKey(string key)
	{
		if (!key.length)
			return null;
		foreach (ref c; items)
			if (c.key == key)
				return &c;
		return null;
	}

	/// Tokens entered whose computer has not answered yet.
	string[] pendingTokens()
	{
		string[] t;
		foreach (c; items)
			if (!c.key.length)
				t ~= c.token;
		return t;
	}

	/// A code entered by the user: remembered (pending) until that computer accepts us.
	void addPending(string token)
	{
		foreach (c; items)
			if (c.token == token)
				return;
		items ~= Computer(null, token, null, now());
		save();
	}

	/// We know this computer now (it accepted our token, or it greeted us with its own):
	/// its key, token and alias — a pending entry with the same token becomes this one.
	void remember(string key, string token, string alias_)
	{
		Computer[] kept;
		foreach (c; items)
			if (c.key != key && !(c.key.length == 0 && c.token == token))
				kept ~= c;
		kept ~= Computer(key, token, alias_, now());
		items = kept;
		save();
	}

	void remove(string keyOrToken)
	{
		Computer[] kept;
		foreach (c; items)
			if (c.key != keyOrToken && c.token != keyOrToken)
				kept ~= c;
		items = kept;
		save();
	}

	/// Whether this node dials `peerKey` (see the module comment): pending entries, or the
	/// smaller key of the two.
	static bool weDial(string ownKey, string peerKey) pure nothrow @safe
	{
		return peerKey.length == 0 || ownKey < peerKey;
	}

	private static long now()
	{
		import std.datetime.systime : Clock;

		return Clock.currTime.toUnixTime;
	}

	private void load()
	{
		import std.file : exists, readText;

		items = null;
		if (!path.length || !path.exists)
			return;
		try
		{
			foreach (v; parseJSON(readText(path)).array)
			{
				Computer c;
				c.key = v["key"].str;
				c.token = v["token"].str;
				c.alias_ = "alias" in v && v["alias"].type == JSONType.string ? v["alias"].str : null;
				c.addedAt = "addedAt" in v && v["addedAt"].type == JSONType.integer ? v["addedAt"].integer : 0;
				if (c.token.length)
					items ~= c;
			}
		}
		catch (Exception)
		{
			items = null;   // unreadable: start empty rather than refuse to run
		}
	}

	private void save()
	{
		import std.file : write, rename, mkdirRecurse;
		import std.path : dirName;

		if (!path.length)
			return;
		JSONValue[] arr;
		foreach (c; items)
			arr ~= JSONValue(["key": JSONValue(c.key), "token": JSONValue(c.token), "alias": JSONValue(c.alias_),
				"addedAt": JSONValue(c.addedAt)]);
		mkdirRecurse(path.dirName);
		immutable tmp = path ~ ".tmp";
		write(tmp, JSONValue(arr).toPrettyString());
		rename(tmp, path);
	}
}

unittest
{
	import std.file : tempDir, exists, remove;
	import std.path : buildPath;

	immutable p = buildPath(tempDir, "pw-computers-test.json");
	if (p.exists)
		remove(p);
	scope (exit)
		if (p.exists)
			remove(p);
	auto peers = new ComputerPeers(p);
	peers.addPending("tokA");
	peers.addPending("tokA");   // once
	assert(peers.pendingTokens == ["tokA"]);
	peers.remember("bb", "tokA", "novigrad");   // the pending one becomes it
	assert(peers.pendingTokens.length == 0 && peers.byKey("bb").alias_ == "novigrad");
	peers.remember("bb", "tokA2", "novigrad");  // same key, new token: replaced
	auto again = new ComputerPeers(p);           // persisted
	assert(again.list.length == 1 && again.byKey("bb").token == "tokA2");
	again.remove("bb");
	assert(new ComputerPeers(p).list.length == 0);
	assert(ComputerPeers.weDial("aa", "bb") && !ComputerPeers.weDial("bb", "aa") && ComputerPeers.weDial("bb", ""));
}
