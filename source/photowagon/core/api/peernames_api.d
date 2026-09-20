/// `peer.*` nicknames: a user-given name per libp2p peer id, so the Peers panel can show
/// a friendly label instead of 12D3Koo…. App-side only — a small table (peer_names), never
/// the p2p node. The UI overlays these onto the live peer list from p2p.status by peer id.
module photowagon.core.api.peernames_api;

import std.json;
import std.string : strip;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.protocol;

void registerPeerNamesApi(Registry r, Database db)
{
	r.add("peer.names", (JSONValue p) {
		auto s = db.prepare("SELECT peer_id, name FROM peer_names");
		JSONValue[string] names;
		while (s.step())
			names[s.getString(0)] = JSONValue(s.getString(1));
		return JSONValue(["names": JSONValue(names)]);
	});

	r.add("peer.setName", (JSONValue p) {
		immutable id = requireString(p, "peerId");
		immutable name = getString(p, "name", "").strip;
		if (name.length == 0)
		{
			auto d = db.prepare("DELETE FROM peer_names WHERE peer_id = ?");
			d.bind(1, id);
			d.run();
		}
		else
		{
			auto s = db.prepare(
				"INSERT INTO peer_names (peer_id, name) VALUES (?, ?) ON CONFLICT(peer_id) DO UPDATE SET name = excluded.name");
			s.bind(1, id).bind(2, name);
			s.run();
		}
		return obj();
	});
}
