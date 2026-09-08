/// What we remember about peers between runs.
module photowagon.core.p2p.peers;

import std.json;

import photowagon.core.db.sqlite : Database;

struct KnownPeer
{
	string peerId;
	string[] addrs;
	string agent;
	long lastSeen;
}

final class PeerRepo
{
	private Database db;

	this(Database db)
	{
		this.db = db;
	}

	void seen(string peerId, string[] addrs, string agent)
	{
		import std.datetime : Clock;

		JSONValue[] a;
		foreach (x; addrs)
			a ~= JSONValue(x);
		auto s = db.prepare(`INSERT INTO peers (peer_id, addrs, agent, last_seen) VALUES (?, ?, ?, ?)
			ON CONFLICT(peer_id) DO UPDATE SET addrs = excluded.addrs,
			agent = coalesce(excluded.agent, peers.agent), last_seen = excluded.last_seen`);
		s.bind(1, peerId).bind(2, JSONValue(a).toString()).bind(3, agent).bind(4, Clock.currTime.toUnixTime);
		s.run();
	}

	KnownPeer[] list()
	{
		auto s = db.prepare("SELECT peer_id, addrs, agent, last_seen FROM peers ORDER BY last_seen DESC");
		KnownPeer[] out_;
		while (s.step())
		{
			KnownPeer k;
			k.peerId = s.getString(0);
			try
				foreach (a; parseJSON(s.getString(1)).array)
					k.addrs ~= a.str;
			catch (Exception)
			{
			}
			k.agent = s.getString(2);
			k.lastSeen = s.getLong(3);
			out_ ~= k;
		}
		return out_;
	}
}

unittest
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	auto peers = new PeerRepo(db);
	peers.seen("p1", ["/ip4/1.2.3.4/tcp/5"], "agent");
	peers.seen("p1", ["/ip4/1.2.3.4/tcp/6"], null);
	auto l = peers.list();
	assert(l.length == 1 && l[0].addrs == ["/ip4/1.2.3.4/tcp/6"] && l[0].agent == "agent");
}
