/// `phone.pairing` — turn the network listener on for a phone and hand the UI
/// what it needs to show a QR code.
module photowagon.core.api.pairing_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.pairing : lanAddresses, pairingCode, qrMatrix, qrPngDataUrl;

/// How the API reaches the listener the daemon owns.
interface ServerControl
{
	/// Starts listening on `address` (idempotent); returns the port.
	ushort startServing(string address);
	void stopServing();
	bool serving();
	ushort servingPort();
	string pairingToken();
	/// The libp2p node's listen addresses with `/p2p/<id>`, or none without a node.
	string[] p2pAddrs();
}

void registerPairingApi(Registry r, ServerControl ctl)
{
	// {enable?: bool} → {enabled, port, addrs, code, qr: {width, rows}, qrImage: data URL}
	r.add("phone.pairing", (JSONValue p) {
		auto en = p.type == JSONType.object ? "enable" in p : null;
		if (en !is null)
		{
			if (en.type == JSONType.true_)
				ctl.startServing("0.0.0.0");
			else if (en.type == JSONType.false_)
				ctl.stopServing();
		}
		if (!ctl.serving)
			return JSONValue(["enabled": JSONValue(false)]);
		auto addrs = lanAddresses();
		JSONValue[] a;
		foreach (x; addrs)
			a ~= JSONValue(x);
		// the node listens on 0.0.0.0: say it once per LAN address the phone can reach
		string[] p2p;
		foreach (m; ctl.p2pAddrs())
		{
			import std.string : replace, indexOf;
			if (m.indexOf("/ip4/0.0.0.0/") >= 0)
				foreach (ip; addrs.length ? addrs : ["127.0.0.1"])
					p2p ~= m.replace("/ip4/0.0.0.0/", "/ip4/" ~ ip ~ "/");
			else if (m.indexOf("/ip6/::/") < 0)
				p2p ~= m;
		}
		JSONValue[] pa;
		foreach (x; p2p)
			pa ~= JSONValue(x);
		immutable code = pairingCode(ctl.pairingToken, addrs.length ? addrs : ["127.0.0.1"], ctl.servingPort, p2p);
		return JSONValue([
			"enabled": JSONValue(true),
			"port": JSONValue(ctl.servingPort),
			"addrs": JSONValue(a),
			"p2p": JSONValue(pa),
			"code": JSONValue(code),
			"qr": qrMatrix(code),
			"qrImage": JSONValue(qrPngDataUrl(code)),
		]);
	});
}
