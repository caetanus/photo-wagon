/// `p2p.*` methods of docs/ipc.md.
module photowagon.core.api.p2p_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.p2p.node : Node;
import photowagon.core.p2p.sharing : Sharing;

/// Both may be null when the node is off; every method then answers `p2p_off`.
void registerP2pApi(Registry r, Node node, Sharing sharing)
{
	void requireNode()
	{
		if (node is null)
			throw new ApiError("p2p_off", "the node is not running (--no-p2p)");
	}

	r.add("p2p.status", (JSONValue p) {
		if (node is null)
			return JSONValue(["peerId": JSONValue(null), "addrs": emptyArray(), "peers": emptyArray(), "off": JSONValue(true)]);
		return node.status();
	});

	r.add("p2p.connect", (JSONValue p) {
		requireNode();
		return JSONValue(["peerId": JSONValue(node.connect(requireString(p, "multiaddr")))]);
	});

	r.add("p2p.fetchAlbum", (JSONValue p) {
		requireNode();
		immutable id = sharing.fetch(requireString(p, "peerId"), requireString(p, "manifest"));
		return JSONValue(["albumId": JSONValue(id)]);
	});
}
