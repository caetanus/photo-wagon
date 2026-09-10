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

string pairingCode(string token, string[] addrs, ushort port, string[] p2p = null)
{
	string code = "pw://" ~ token ~ "@";
	foreach (i, a; addrs)
		code ~= (i ? "," : "") ~ a ~ ":" ~ port.to!string;
	if (p2p.length)
	{
		code ~= "#";
		foreach (i, a; p2p)
			code ~= (i ? "," : "") ~ a;
	}
	return code;
}

/// Parses a code; throws on anything that is not one.
PairingInfo parsePairingCode(string code)
{
	code = code.strip;
	if (!code.startsWith("pw://"))
		throw new Exception("not a Photo Wagon code");
	auto rest = code[5 .. $];
	immutable at = rest.indexOf('@');
	if (at <= 0)
		throw new Exception("code has no token");
	PairingInfo info;
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
	if (info.hosts.length == 0)
		throw new Exception("code has no address");
	return info;
}

unittest
{
	auto info = parsePairingCode("pw://abc123@192.168.0.5:47111,10.0.0.2:47111");
	assert(info.token == "abc123" && info.hosts == ["192.168.0.5:47111", "10.0.0.2:47111"]);
	assert(pairingCode("t", ["1.2.3.4"], 5) == "pw://t@1.2.3.4:5");
	auto p = parsePairingCode("pw://t@1.2.3.4:5#/ip4/1.2.3.4/tcp/9/p2p/12D3KooWabc,/ip4/10.0.0.1/tcp/9/p2p/12D3KooWabc");
	assert(p.hosts == ["1.2.3.4:5"] && p.p2p.length == 2 && p.p2p[0] == "/ip4/1.2.3.4/tcp/9/p2p/12D3KooWabc");
	assert(pairingCode("t", ["1.2.3.4"], 5, ["/ip4/1.2.3.4/tcp/9/p2p/x"]) == "pw://t@1.2.3.4:5#/ip4/1.2.3.4/tcp/9/p2p/x");
	bool threw;
	try
		parsePairingCode("http://x");
	catch (Exception)
		threw = true;
	assert(threw);
}
