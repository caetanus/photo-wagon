/// The libp2p node: host, identify, ping, Kademlia, and the peer table the UI sees.
module photowagon.core.p2p.node;

import core.time : seconds;
import std.json;

import vibe.core.log : logInfo, logWarn, logDiagnostic;

import libp2p.core.peer_id : PeerId;
import libp2p.crypto.keys : Keypair;
import libp2p.host.host : Host, HostConfig;
import libp2p.multiformats.multiaddr : Multiaddr;
import libp2p.protocol.identify : IdentifyService, IdentifyInfo;
import libp2p.protocol.kad.kad : Kademlia;
import libp2p.protocol.ping : Ping, PingConfig;
import libp2p.protocol.relay.service : Relay;
import libp2p.protocol.autonat.autonat : AutoNat, NatStatus;
import libp2p.swarm.connection : Connection, Notifiee, Hold;
import libp2p.transport.tcp : TcpTransport;

import photowagon.core.config : Config;
import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.protocol : ApiError;
import photowagon.core.p2p.peers : PeerRepo;

enum agentVersion = "photowagon/0.3.0";

struct LivePeer
{
	string peerId;
	string[] addrs;
	string agent;
	uint connections;
}

final class Node : Notifiee
{
	Host host;
	Kademlia kad;
	private IdentifyService identify;
	private Ping ping;
	private Relay relay;
	private AutoNat autonat;
	private string[] circuitAddrsList; // complete /p2p-circuit addresses (already end in /p2p/<self>)
	private string relayPeerId;        // the relay we currently hold a reservation on (empty = none)
	private Hold relayHold;            // keeps that relay's connection off the idle-close timer
	private PeerId[string] dhtPeers;   // currently-connected peers, candidates to reserve a relay slot on
	private Connection[string] conns;  // live connection per peer, so we can hold the relay's open
	// NAT-traversal: relay transport + AutoNat + DCUtR (hole punching). The desktop regression
	// it once caused was really the in-process UI link race, now fixed (core/ipc/link.d), so it
	// is safe on. For 4G we lean on PUBLIC libp2p relays for the DCUtR signalling (a few KB) and
	// punch a direct link for the photos — no relay of our own. Pass one or more reachable relay
	// multiaddrs with --p2p-relay-addr; the node reserves a slot and advertises its /p2p-circuit.
	private enum bool natTraversal = true;
	private Events events;
	private PeerRepo peers;
	private LivePeer[string] live;
	private Config cfg;
	private string[] learnedPublic; // public transport addrs peers reported seeing us at

	this(Keypair identity, Config cfg, Events events, PeerRepo peers)
	{
		this.cfg = cfg;
		this.events = events;
		this.peers = peers;
		HostConfig hc;
		hc.agentVersion = agentVersion;
		hc.swarm.idleTimeout = 120.seconds;
		host = new Host(identity, [new TcpTransport], hc);
		identify = new IdentifyService(host);
		identify.onIdentified = &identified;
		PingConfig pc;
		pc.interval = 30.seconds;
		ping = new Ping(host, pc);
		kad = new Kademlia(host);
		// NAT-traversal wiring (relay transport + AutoNat) is temporarily OFF: adding the relay
		// as a swarm transport stalled the in-process UI link at startup (the library came up
		// empty under p2p). Kept behind this flag until that is understood and fixed.
		if (natTraversal)
		{
			relay = new Relay(host);
			host.swarm.addTransport(relay);
			autonat = new AutoNat(host);
			autonat.onStatusChanged = (NatStatus old, NatStatus now) {
				cast(void) old;
				try
					logInfo("p2p: reachability is now %s", now.isPublic ? "public" : "private (behind NAT)");
				catch (Exception)
				{
				}
			};
		}
		host.addNotifiee(this);
	}

	void start()
	{
		import std.file : exists, readText, write;
		import std.path : buildPath;
		import std.conv : to;
		import std.string : strip;

		// Reuse the port we bound last time, so the address the phone saved from the pairing
		// code survives a restart (an ephemeral port that changed every start was why it "não
		// reconectava"). tcp/0 still picks the port the FIRST time; we persist what we got.
		immutable portFile = buildPath(cfg.dataDir, "p2p-port");
		string[] listenAddrs = cfg.p2pListen.dup;
		if (listenAddrs == ["/ip4/0.0.0.0/tcp/0"] && portFile.exists)
		{
			try
			{
				immutable saved = readText(portFile).strip.to!int;
				if (saved > 0)
					listenAddrs = ["/ip4/0.0.0.0/tcp/" ~ saved.to!string];
			}
			catch (Exception)
			{
			}
		}
		foreach (a; listenAddrs)
		{
			try
				host.listen(Multiaddr.parse(a));
			catch (Exception e)
			{
				// the saved port is taken (a second instance, or another program): fall back
				logWarn("p2p: listen on %s failed (%s) — taking an ephemeral port", a, e.msg);
				host.listen(Multiaddr.parse("/ip4/0.0.0.0/tcp/0"));
			}
		}
		logInfo("p2p: %s listening on %s", id, addrs);
		try
		{
			immutable p = boundPort();
			if (p > 0)
				write(portFile, p.to!string);
		}
		catch (Exception)
		{
		}
		if (natTraversal)
		{
			learnPublicIp();
			reserveOnRelays();
		}
	}

	/// Reserve a slot on each configured relay and remember the /p2p-circuit address it gives
	/// us, so peers anywhere (a phone on 4G, both of us behind CGNAT) can reach us through the
	/// relay. Re-reserves periodically, since a reservation expires. Off the start path.
	private void reserveOnRelays()
	{
		import vibe.core.core : runTask, sleep;
		import core.time : minutes, seconds;

		if (cfg.p2pRelays.length == 0)
			return;
		runTask(() nothrow {
			import std.algorithm : canFind;

			bool joinedDht;

			// Reserve a slot on `pe` and return this node's cleaned /p2p-circuit addresses
			// (empty if the peer refused or isn't a relay).
			string[] reserveOn(PeerId pe) nothrow
			{
				string[] got;
				try
				{
					auto info = relay.reserve(pe);
					foreach (ca; relay.circuitAddrs(pe, info))
					{
						immutable s = cleanCircuit(ca.toString);
						if (!got.canFind(s))
							got ~= s;
					}
				}
				catch (Exception)
				{
				}
				return got;
			}

			for (;;)
			{
				// Keep a live connection to the configured seeds and join the public DHT
				// through them once, so discovery works the libp2p way.
				foreach (r; cfg.p2pRelays)
				{
					try
					{
						auto pa = splitPeer(r);
						host.connect(pa.peer, [pa.addr]);
						try
							kad.addAddress(pa.peer, pa.addr);
						catch (Exception)
						{
						}
					}
					catch (Exception)
					{
					}
				}
				if (!joinedDht)
				{
					joinedDht = true;
					try
						logInfo("p2p: joined the DHT via %s seed(s)", kad.bootstrap());
					catch (Exception e)
						try
							logWarn("p2p: DHT bootstrap failed: %s", e.msg);
						catch (Exception)
						{
						}
				}

				// Refresh: if we hold a reservation and are still connected to that relay,
				// renew it — this extends the TTL and keeps the /p2p-circuit address live.
				// If the relay dropped in the DHT churn (the "bada" bug: it once kept a dead
				// circuit for 30 min), throw the stale address away so we stop advertising a
				// circuit nobody can dial, and go find a new relay below.
				if (relayPeerId.length)
				{
					if (auto pe = relayPeerId in dhtPeers)
					{
						auto fresh = reserveOn(*pe);
						if (fresh.length)
							circuitAddrsList = fresh;
						else
						{
							relayPeerId = null;
							circuitAddrsList = null;
						}
					}
					else
					{
						relayPeerId = null;
						circuitAddrsList = null;
						try
							logInfo("p2p: relay connection lost, finding another");
						catch (Exception)
						{
						}
					}
				}

				// Acquire: no live reservation — try the configured relays first, then
				// AutoRelay-lite over the public peers the DHT gave us (many go-libp2p nodes
				// run a limited relay that grants a slot). Stop at the first that sticks; that
				// relay stays ours (and gets refreshed above) until its connection drops.
				if (relayPeerId.length == 0)
				{
					try
						sleep(4.seconds); // let the DHT settle its connections
					catch (Exception)
					{
					}
					PeerId[] cands;
					foreach (r; cfg.p2pRelays)
						try
							cands ~= splitPeer(r).peer;
						catch (Exception)
						{
						}
					foreach (_, pe; dhtPeers)
						cands ~= pe;
					int tried;
					foreach (pe; cands)
					{
						if (relayPeerId.length || tried >= 40)
							break;
						tried++;
						auto got = reserveOn(pe);
						if (got.length)
						{
							circuitAddrsList = got;
							try
							{
								immutable rp = pe.toString;
								relayPeerId = rp;
								// hold this relay's connection open so the DHT's idle-close
								// churn can't drop the reservation out from under us
								relayHold.release();
								if (auto cp = rp in conns)
									relayHold = (*cp).hold();
								logInfo("p2p: reachable via public relay: %s", got[0]);
							}
							catch (Exception)
							{
							}
						}
					}
					if (relayPeerId.length == 0)
						try
							logWarn("p2p: no relay slot among %s peers tried", tried);
						catch (Exception)
						{
						}
				}

				// Wait before the next refresh/acquire, but wake early if the relay we hold
				// drops: disconnected() clears relayPeerId the instant its connection ends, so
				// a dead /p2p-circuit is dropped and replaced within seconds, not up to 5 min.
				{
					immutable held = relayPeerId.length > 0;
					// refresh every ~100s when reserved — under the 120s swarm idle timeout, so
					// the renewal traffic keeps the relay connection from idling out (which was
					// dropping the reservation mid-churn); ~2 min between retries when none yet
					immutable ticks = held ? 50 : 60;
					bool cancelled;
					foreach (_; 0 .. ticks)
					{
						try
							sleep(2.seconds);
						catch (Exception)
						{
							cancelled = true;
							break;
						}
						if (held && relayPeerId.length == 0)
							break; // the relay dropped — re-acquire immediately
					}
					if (cancelled)
						break;
				}
			}
		});
	}

	/// Best-effort: find our public IPv4 (no UPnP in the stack, so we cannot open the port,
	/// but we can advertise the right address). Pairs the public IP with our stable listen
	/// port; a phone off the LAN dials that once the router forwards the port. Skipped when
	/// an explicit announce address is configured. Runs off the start path, never blocks it.
	private void learnPublicIp()
	{
		import vibe.core.core : runTask;

		if (cfg.p2pAnnounce.length)
			return;
		runTask(() nothrow {
			try
			{
				import vibe.core.net : connectTCP;
				import std.string : indexOf, strip, split;
				import std.algorithm : canFind;
				import std.conv : to;

				auto conn = connectTCP("api.ipify.org", 80);
				scope (exit)
					conn.close();
				conn.write(cast(const(ubyte)[]) "GET / HTTP/1.0\r\nHost: api.ipify.org\r\nConnection: close\r\n\r\n");
				string resp;
				ubyte[1024] buf;
				while (!conn.empty && resp.length < 8192)
				{
					auto n = conn.leastSize;
					if (n == 0)
						break;
					immutable take = n > buf.length ? buf.length : cast(size_t) n;
					conn.read(buf[0 .. take]);
					resp ~= cast(string) buf[0 .. take].idup;
				}
				immutable sep = resp.indexOf("\r\n\r\n");
				if (sep < 0)
					return;
				immutable ip = resp[sep + 4 .. $].strip;
				immutable maddr = "/ip4/" ~ ip ~ "/tcp/" ~ boundPort().to!string;
				if (isPublicV4(maddr) && boundPort() > 0 && !learnedPublic.canFind(maddr))
				{
					learnedPublic ~= maddr;
					logInfo("p2p: public address detected: %s (forward this TCP port on your router for 4G)", maddr);
				}
			}
			catch (Exception e)
			{
				try
					logDiagnostic("p2p: public IP lookup failed: %s", e.msg);
				catch (Exception)
				{
				}
			}
		});
	}

	/// The TCP port the host actually bound (0 if none), for persisting across restarts.
	private int boundPort()
	{
		import std.conv : to;
		import std.string : split;

		foreach (a; host.addrs)
		{
			auto parts = a.toString.split("/");
			foreach (i, seg; parts)
				if (seg == "tcp" && i + 1 < parts.length)
				{
					try
					{
						immutable p = parts[i + 1].to!int;
						if (p > 0)
							return p;
					}
					catch (Exception)
					{
					}
				}
		}
		return 0;
	}

	string id()
	{
		return host.id.toString;
	}

	/// Our addresses, each with `/p2p/<id>` appended: what a peer dials. This is the LAN
	/// listen addresses PLUS a public address — the one configured to announce, and any a
	/// peer has told us it saw us at — so a phone off the LAN (on 4G) has a route to try.
	/// The port is stable across restarts (persisted), so with the router forwarding it once,
	/// the public address keeps working. Public addresses come first: off-LAN they are the
	/// only ones that can work, and on-LAN a failed public dial falls straight through to the
	/// LAN ones the phone also holds.
	string[] addrs()
	{
		import std.algorithm : canFind;

		string[] transport; // transport parts, public first, deduped
		void add(string t)
		{
			if (t.length && !transport.canFind(t))
				transport ~= t;
		}
		// configured announce: a bare host, or a full multiaddr
		if (cfg.p2pAnnounce.length)
		{
			if (cfg.p2pAnnounce[0] == '/')
				add(cfg.p2pAnnounce);
			else
			{
				immutable p = boundPort();
				if (p > 0)
					add("/ip4/" ~ cfg.p2pAnnounce ~ "/tcp/" ~ (){ import std.conv : to; return p.to!string; }());
			}
		}
		foreach (t; learnedPublic) // what peers observed (a real public address)
			add(t);
		foreach (a; host.addrs) // the LAN / listen addresses
		{
			immutable s = a.toString;
			// the wildcard listen address (/ip4/0.0.0.0/…) and loopback are not dialable by a
			// remote peer; advertising them just made the phone waste dials on 0.0.0.0
			if (s.canFind("/ip4/0.0.0.0/") || s.canFind("/ip6/::/")
				|| s.canFind("/ip4/127.") || s.canFind("/ip6/::1/"))
				continue;
			add(s);
		}

		string[] out_;
		// circuit addresses are complete (they already end in /p2p/<self>): reachable from
		// anywhere, so they go first for a peer that is off the LAN.
		foreach (c; circuitAddrsList)
			if (!out_.canFind(c))
				out_ ~= c;
		foreach (t; transport)
			out_ ~= t ~ "/p2p/" ~ id;
		return out_;
	}

	/// The relay's circuitAddrs() can emit the relay's peer id twice in a row
	/// (`…/p2p/RELAY/p2p/RELAY/p2p-circuit/…`) because the reserved address already carries it.
	/// Collapse the duplicate so a peer can actually dial the /p2p-circuit address.
	private static string cleanCircuit(string s)
	{
		import std.string : indexOf, split, join;

		immutable ix = s.indexOf("/p2p-circuit");
		if (ix <= 0)
			return s;
		auto left = s[0 .. ix];
		auto lp = left.split("/");
		if (lp.length >= 4 && lp[$ - 2] == "p2p" && lp[$ - 4] == "p2p" && lp[$ - 1] == lp[$ - 3])
			left = lp[0 .. $ - 2].join("/");
		return left ~ s[ix .. $];
	}

	/// Is this a routable public IPv4 transport address? (Not private, loopback,
	/// link-local, or carrier-grade NAT — those are useless to advertise off-LAN.)
	private static bool isPublicV4(string maddr)
	{
		import std.string : split;
		import std.conv : to;

		auto parts = maddr.split("/");
		foreach (i, seg; parts)
			if (seg == "ip4" && i + 1 < parts.length)
			{
				auto o = parts[i + 1].split(".");
				if (o.length != 4)
					return false;
				try
				{
					immutable a = o[0].to!int, b = o[1].to!int;
					if (a == 10 || a == 127 || a == 0)
						return false;
					if (a == 192 && b == 168)
						return false;
					if (a == 172 && b >= 16 && b <= 31)
						return false;
					if (a == 169 && b == 254)
						return false;
					if (a == 100 && b >= 64 && b <= 127)
						return false; // CGNAT
					return true;
				}
				catch (Exception)
					return false;
			}
		return false;
	}

	/// Dials `<transport addr>/p2p/<peer>`; returns the peer id.
	string connect(string multiaddr)
	{
		auto split = splitPeer(multiaddr);
		try
			host.connect(split.peer, [split.addr]);
		catch (Exception e)
			throw new ApiError("dial_failed", e.msg);
		return split.peer.toString;
	}

	JSONValue status()
	{
		JSONValue[] ps;
		foreach (p; live)
		{
			JSONValue[] a;
			foreach (x; p.addrs)
				a ~= JSONValue(x);
			ps ~= JSONValue([
				"peerId": JSONValue(p.peerId), "addrs": JSONValue(a),
				"agent": p.agent is null ? JSONValue(null) : JSONValue(p.agent),
				"connected": JSONValue(true)
			]);
		}
		foreach (k; peers.list())
			if (k.peerId !in live)
			{
				JSONValue[] a;
				foreach (x; k.addrs)
					a ~= JSONValue(x);
				ps ~= JSONValue([
					"peerId": JSONValue(k.peerId), "addrs": JSONValue(a),
					"agent": k.agent is null ? JSONValue(null) : JSONValue(k.agent),
					"connected": JSONValue(false), "lastSeen": JSONValue(k.lastSeen)
				]);
			}
		JSONValue[] mine;
		foreach (a; addrs)
			mine ~= JSONValue(a);
		return JSONValue(["peerId": JSONValue(id), "addrs": JSONValue(mine), "peers": JSONValue(ps)]);
	}

	// ---- Notifiee ---------------------------------------------------------------

	void connected(Connection c)
	{
		immutable pid = c.remotePeer.toString;
		dhtPeers[pid] = c.remotePeer;
		conns[pid] = c;
		auto p = pid in live;
		if (p is null)
		{
			live[pid] = LivePeer(pid, [c.remoteAddr.toString], null, 1);
			logInfo("p2p: connected %s via %s", pid, c.remoteAddr);
			try
				peers.seen(pid, [c.remoteAddr.toString], null);
			catch (Exception e)
				logWarn("p2p: cannot record peer: %s", e.msg);
			events.emit("p2p.peer", JSONValue(["peerId": JSONValue(pid), "connected": JSONValue(true)]));
		}
		else
			p.connections++;
	}

	void disconnected(Connection c)
	{
		immutable pid = c.remotePeer.toString;
		auto p = pid in live;
		if (p is null)
			return;
		if (--p.connections > 0)
			return;
		live.remove(pid);
		dhtPeers.remove(pid);
		conns.remove(pid);
		// If this was the relay holding our reservation, our /p2p-circuit address just died.
		// Drop it now so we stop handing the phone a circuit nobody can dial; the reserve
		// loop wakes on the cleared id and finds another relay within seconds.
		if (pid == relayPeerId)
		{
			relayHold.release();
			relayPeerId = null;
			circuitAddrsList = null;
		}
		logInfo("p2p: disconnected %s", pid);
		events.emit("p2p.peer", JSONValue(["peerId": JSONValue(pid), "connected": JSONValue(false)]));
	}

	private void identified(IdentifyInfo info)
	{
		immutable pid = info.peer.toString;
		// what this peer saw as our address tells us our public IP. Pair that IP with our
		// stable listen port (not the observed source port, which NAT rewrote for outbound)
		// so the result is an address a phone can actually dial in to.
		if (!info.observedAddr.isNull)
		{
			immutable seen = info.observedAddr.get.toString;
			if (isPublicV4(seen))
			{
				import std.string : split;
				import std.algorithm : canFind;
				import std.conv : to;

				auto parts = seen.split("/");
				string ip;
				foreach (i, seg; parts)
					if (seg == "ip4" && i + 1 < parts.length)
						ip = parts[i + 1];
				immutable port = boundPort();
				if (ip.length && port > 0)
				{
					immutable pub = "/ip4/" ~ ip ~ "/tcp/" ~ port.to!string;
					if (!learnedPublic.canFind(pub))
					{
						learnedPublic ~= pub;
						logInfo("p2p: public address learned: %s", pub);
					}
				}
			}
		}
		string[] addrs;
		foreach (a; info.listenAddrs)
		{
			addrs ~= a.toString;
			try
				kad.addAddress(info.peer, a);
			catch (Exception)
			{
			}
		}
		if (auto p = pid in live)
		{
			p.agent = info.agentVersion;
			if (addrs.length)
				p.addrs = addrs;
		}
		try
			peers.seen(pid, addrs.length ? addrs : (pid in live ? live[pid].addrs : null), info.agentVersion);
		catch (Exception e)
			logWarn("p2p: cannot record peer: %s", e.msg);
		events.emit("p2p.peer", JSONValue(["peerId": JSONValue(pid), "connected": JSONValue(true)]));
	}

	void close() nothrow
	{
		try
			kad.close();
		catch (Exception)
		{
		}
		try
			if (relay !is null)
				relay.close();
		catch (Exception)
		{
		}
		try
			if (autonat !is null)
				autonat.close();
		catch (Exception)
		{
		}
		host.close();
	}
}

struct PeerAddr
{
	PeerId peer;
	Multiaddr addr;
}

/// "/ip4/…/tcp/N/p2p/Qm…" → the transport part and the peer id.
PeerAddr splitPeer(string text)
{
	Multiaddr full;
	try
		full = Multiaddr.parse(text);
	catch (Exception e)
		throw new ApiError("bad_params", "not a multiaddr: " ~ e.msg);
	PeerAddr out_;
	bool havePeer;
	foreach (c; full.components)
	{
		if (c.name == "p2p")
		{
			out_.peer = PeerId.fromBytes(c.value);
			havePeer = true;
		}
		else
			out_.addr = out_.addr ~ Multiaddr.parse("/" ~ c.name ~ (c.protocol.size != 0 ? "/" ~ c.text : ""));
	}
	if (!havePeer)
		throw new ApiError("bad_params", "address needs a /p2p/<peer> component");
	return out_;
}
