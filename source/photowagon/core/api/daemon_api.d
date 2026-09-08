/// `daemon.*` methods of docs/ipc.md.
module photowagon.core.api.daemon_api;

import std.json;

import photowagon.core.config : Config;
import photowagon.core.ipc.protocol;
import photowagon.core.p2p.node : Node;

enum daemonVersion = "0.4.0";

void registerDaemonApi(Registry r, Config cfg, Node node, void delegate() shutdown)
{
	r.add("daemon.hello", (JSONValue p) {
		JSONValue[] addrs;
		if (node !is null)
			foreach (a; node.addrs)
				addrs ~= JSONValue(a);
		return JSONValue([
			"version": JSONValue(daemonVersion),
			"dataDir": JSONValue(cfg.dataDir),
			"peerId": node is null ? JSONValue(null) : JSONValue(node.id),
			"addrs": JSONValue(addrs),
			"methods": JSONValue(r.names().length),
		]);
	});

	r.add("daemon.shutdown", (JSONValue p) {
		import vibe.core.core : runTask, sleep;
		import core.time : msecs;

		// answer first, then go
		runTask(() nothrow {
			try
			{
				sleep(50.msecs);
				shutdown();
			}
			catch (Exception)
			{
			}
		});
		return obj();
	});
}
