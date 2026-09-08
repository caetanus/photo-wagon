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
		immutable code = pairingCode(ctl.pairingToken, addrs.length ? addrs : ["127.0.0.1"], ctl.servingPort);
		return JSONValue([
			"enabled": JSONValue(true),
			"port": JSONValue(ctl.servingPort),
			"addrs": JSONValue(a),
			"code": JSONValue(code),
			"qr": qrMatrix(code),
			"qrImage": JSONValue(qrPngDataUrl(code)),
		]);
	});
}
