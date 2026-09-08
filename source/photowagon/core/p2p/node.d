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
import libp2p.swarm.connection : Connection, Notifiee;
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
	private Events events;
	private PeerRepo peers;
	private LivePeer[string] live;
	private Config cfg;

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
		host.addNotifiee(this);
	}

	void start()
	{
		foreach (a; cfg.p2pListen)
			host.listen(Multiaddr.parse(a));
		logInfo("p2p: %s listening on %s", id, addrs);
	}

	string id()
	{
		return host.id.toString;
	}

	/// Our listen addresses, each with `/p2p/<id>` appended: what a peer types in.
	string[] addrs()
	{
		string[] out_;
		foreach (a; host.addrs)
			out_ ~= a.toString ~ "/p2p/" ~ id;
		return out_;
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
		logInfo("p2p: disconnected %s", pid);
		events.emit("p2p.peer", JSONValue(["peerId": JSONValue(pid), "connected": JSONValue(false)]));
	}

	private void identified(IdentifyInfo info)
	{
		immutable pid = info.peer.toString;
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
