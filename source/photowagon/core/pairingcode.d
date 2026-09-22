/// The pairing code both ends agree on. Pure D: the phone links this too.
///
/// `pw://<token>@<ip>:<port>[,<ip>:<port>…][#<multiaddr>[,<multiaddr>…]]`
/// The part after `#` is the computer's libp2p addresses (`/ip4/…/tcp/…/p2p/<id>`);
/// an old phone ignores it and uses the plain addresses.
module photowagon.core.pairingcode;

import std.conv : to;
import std.string : strip, startsWith, indexOf, split;

struct PairingInfo
{
	string token;
	string[] hosts; // "ip:port"
	string[] p2p;   // "/ip4/…/tcp/N/p2p/<peer id>", may be empty
}

/// Token-only: the QR carries just the shared secret. The computer's address is never
/// published in it — a phone finds the computer by the token alone (the DHT rendezvous key
/// off the LAN, mDNS on the LAN; both are `rendezvousKeyFor("pw", token)` / the same label,
/// in libp2p.discovery — the single source of the key now). No internal IP or port ever
/// leaves in the code.
string pairingCode(string token)
{
	return "pw://" ~ token;
}

/// Parses a code; throws on anything that is not one.
PairingInfo parsePairingCode(string code)
{
	code = code.strip;
	if (!code.startsWith("pw://"))
		throw new Exception("not a Photo Wagon code");
	auto rest = code[5 .. $];
	PairingInfo info;
	immutable at = rest.indexOf('@');
	if (at < 0)
	{
		// Token-only code (the current form): no address, discovery is by the token
		// (DHT rendezvous off the LAN, mDNS on it).
		info.token = rest.strip;
		if (info.token.length == 0)
			throw new Exception("code has no token");
		return info;
	}
	if (at == 0)
		throw new Exception("code has no token");
	// Legacy form `pw://token@host:port,…[#multiaddr,…]` — still parsed so an old QR
	// keeps working; the hosts are optional now (a phone falls back to token discovery).
	info.token = rest[0 .. at];
	auto tail = rest[at + 1 .. $];
	immutable hash = tail.indexOf('#');
	if (hash >= 0)
	{
		foreach (a; tail[hash + 1 .. $].split(","))
			if (a.strip.length)
				info.p2p ~= a.strip;
		tail = tail[0 .. hash];
	}
	foreach (h; tail.split(","))
		if (h.strip.length)
			info.hosts ~= h.strip;
	return info;
}

unittest
{
	// Token-only is the current form: the QR carries just the secret, no address.
	assert(pairingCode("t") == "pw://t");
	auto only = parsePairingCode("pw://abc123");
	assert(only.token == "abc123" && only.hosts.length == 0 && only.p2p.length == 0);
	// Legacy codes still parse (an old QR keeps working); hosts optional.
	auto info = parsePairingCode("pw://abc123@192.168.0.5:47111,10.0.0.2:47111");
	assert(info.token == "abc123" && info.hosts == ["192.168.0.5:47111", "10.0.0.2:47111"]);
	auto p = parsePairingCode("pw://t@1.2.3.4:5#/ip4/1.2.3.4/tcp/9/p2p/12D3KooWabc,/ip4/10.0.0.1/tcp/9/p2p/12D3KooWabc");
	assert(p.hosts == ["1.2.3.4:5"] && p.p2p.length == 2 && p.p2p[0] == "/ip4/1.2.3.4/tcp/9/p2p/12D3KooWabc");
	bool threw;
	try
		parsePairingCode("http://x");
	catch (Exception)
		threw = true;
	assert(threw);
}
