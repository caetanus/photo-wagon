/// A standalone libp2p circuit-relay v2 node (`photo-wagon --p2p-relay`).
///
/// Run this on any host with a public address. Two Photo Wagon peers that are both behind
/// NAT — a phone on 4G and a desktop behind CGNAT, where neither can be dialed directly —
/// each reserve a slot here and reach each other over a /p2p-circuit address; DCUtR then
/// tries to punch a direct connection, and only falls back to relaying the bytes when it
/// cannot. Because this is your own relay, its per-circuit limits are generous, so a photo
/// sync goes through even when the hole punch fails. It holds no library and no database.
module photowagon.core.p2p.relaynode;

import core.time : seconds, hours;

import vibe.core.core : runEventLoop;
import vibe.core.log : logInfo;

import libp2p.host.host : Host, HostConfig;
import libp2p.multiformats.multiaddr : Multiaddr;
import libp2p.protocol.identify : IdentifyService;
import libp2p.protocol.ping : Ping, PingConfig;
import libp2p.protocol.relay.service : Relay, RelayLimits;
import libp2p.transport.tcp : TcpTransport;

import photowagon.core.config : Config;
import photowagon.core.p2p.identity : loadOrCreateIdentity;

int runRelay(Config cfg)
{
	auto identity = loadOrCreateIdentity(cfg.identityPath);
	HostConfig hc;
	hc.agentVersion = "photowagon-relay/0.1";
	hc.swarm.idleTimeout = 300.seconds;
	auto host = new Host(identity, [new TcpTransport], hc);
	auto identify = new IdentifyService(host);
	PingConfig pc;
	pc.interval = 30.seconds;
	auto ping = new Ping(host, pc);
	cast(void) identify;   // kept alive for the life of the host (they registered handlers)
	cast(void) ping;

	// Your own relay: no stingy caps. The public relays refuse anything past ~128 KB / 2 min
	// per circuit, which is why a photo sync through them dies; here it flows.
	RelayLimits lim;
	lim.maxReservations = 1024;
	lim.maxReservationsPerPeer = 8;
	lim.reservationDuration = 12.hours;
	lim.maxCircuits = 256;
	lim.maxCircuitsPerPeer = 16;
	lim.maxCircuitDuration = 12.hours;
	lim.maxCircuitBytes = ulong.max;
	auto relay = new Relay(host, lim);
	host.swarm.addTransport(relay);

	auto listen = cfg.p2pListen.length ? cfg.p2pListen : ["/ip4/0.0.0.0/tcp/4001"];
	foreach (a; listen)
		host.listen(Multiaddr.parse(a));

	logInfo("relay: peer id %s", host.id.toString);
	foreach (a; host.addrs)
		logInfo("relay: reachable at %s/p2p/%s", a.toString, host.id.toString);
	logInfo("relay: put that address (with your host's PUBLIC ip) on each device: --p2p-relay-addr <addr>");

	scope (exit)
		host.close();
	runEventLoop();
	return 0;
}
