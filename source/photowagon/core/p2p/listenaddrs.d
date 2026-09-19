/// Turn bind addresses into routes another device can dial.
module photowagon.core.p2p.listenaddrs;

import std.string : startsWith;

/// A wildcard IPv4 listener accepts connections on every LAN interface. Advertise
/// those interfaces with the listener's port, even when a public address is known.
string[] dialableListenAddress(string address, string[] lan)
{
	enum wildcard = "/ip4/0.0.0.0/";
	if (address.startsWith(wildcard))
	{
		string[] out_;
		foreach (ip; lan)
			out_ ~= "/ip4/" ~ ip ~ "/" ~ address[wildcard.length .. $];
		return out_;
	}
	if (address.startsWith("/ip4/127.") || address.startsWith("/ip6/::/")
			|| address.startsWith("/ip6/::1/"))
		return null;
	return [address];
}

unittest
{
	// The default wildcard bind must still offer a local route to a paired phone.
	assert(dialableListenAddress("/ip4/0.0.0.0/tcp/35327", ["192.168.0.60", "10.0.0.2"])
		== ["/ip4/192.168.0.60/tcp/35327", "/ip4/10.0.0.2/tcp/35327"]);
	assert(dialableListenAddress("/ip4/0.0.0.0/tcp/35327", []).length == 0);
	assert(dialableListenAddress("/ip4/192.168.0.60/tcp/35327", ["10.0.0.2"])
		== ["/ip4/192.168.0.60/tcp/35327"]);
	foreach (a; ["/ip4/127.0.0.1/tcp/35327", "/ip6/::/tcp/35327", "/ip6/::1/tcp/35327"])
		assert(dialableListenAddress(a, ["192.168.0.60"]).length == 0);
}
