/// The pairing code both ends agree on. Pure D: the phone links this too.
///
/// `pw://<token>@<ip>:<port>[,<ip>:<port>…]`
module photowagon.core.pairingcode;

import std.conv : to;
import std.string : strip, startsWith, indexOf, split;

struct PairingInfo
{
	string token;
	string[] hosts; // "ip:port"
}

string pairingCode(string token, string[] addrs, ushort port)
{
	string code = "pw://" ~ token ~ "@";
	foreach (i, a; addrs)
		code ~= (i ? "," : "") ~ a ~ ":" ~ port.to!string;
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
	foreach (h; rest[at + 1 .. $].split(","))
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
	bool threw;
	try
		parsePairingCode("http://x");
	catch (Exception)
		threw = true;
	assert(threw);
}
