/// `devices.*` — the phones paired with this desktop: list them, rename one, pause it
/// (turned away until resumed) or revoke it (turned away for good). Keyed by the phone's
/// libp2p peer id. The auth handshake (core/p2p/ipc.d) reads the state set here.
module photowagon.core.api.device_api;

import std.json;

import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.protocol;
import photowagon.core.p2p.devices : DeviceRepo, DeviceState, PairingManager;

void registerDeviceApi(Registry r, DeviceRepo devices, Events events, PairingManager pairing = null)
{
    // The operator typed the 4-digit code a knocking phone shows: admit it (or refuse).
    r.add("devices.confirm", (JSONValue p) {
        import vibe.core.log : logInfo;

        immutable peer = requireString(p, "peerId");
        immutable code = requireString(p, "code");
        immutable pend = pairing !is null && pairing.isPending(peer);
        immutable ok = pairing !is null && pairing.confirm(peer, code);
        logInfo("ipc: devices.confirm peer %s code %s pending=%s -> %s", peer, code, pend, ok);
        if (ok)
            events.emit("devices.changed", JSONValue.emptyObject);
        return JSONValue(["ok": JSONValue(ok)]);
    });

    r.add("devices.list", (JSONValue p) {
        JSONValue[] arr;
        foreach (d; devices.list())
            arr ~= devices.toJson(d);
        return JSONValue(["devices": JSONValue(arr)]);
    });

    r.add("devices.rename", (JSONValue p) {
        immutable peer = requireString(p, "peerId");
        immutable name = requireString(p, "name");
        devices.rename(peer, name);
        events.emit("devices.changed", JSONValue.emptyObject);
        return JSONValue(["ok": JSONValue(true)]);
    });

    r.add("devices.pause", (JSONValue p) {
        immutable peer = requireString(p, "peerId");
        devices.setState(peer, DeviceState.paused);
        events.emit("devices.changed", JSONValue.emptyObject);
        return JSONValue(["ok": JSONValue(true)]);
    });

    r.add("devices.resume", (JSONValue p) {
        immutable peer = requireString(p, "peerId");
        devices.setState(peer, DeviceState.active);
        events.emit("devices.changed", JSONValue.emptyObject);
        return JSONValue(["ok": JSONValue(true)]);
    });

    // Revoke: remembered as revoked and turned away at auth (so it cannot just re-register).
    r.add("devices.revoke", (JSONValue p) {
        immutable peer = requireString(p, "peerId");
        devices.setState(peer, DeviceState.revoked);
        events.emit("devices.changed", JSONValue.emptyObject);
        return JSONValue(["ok": JSONValue(true)]);
    });

    // Forget: drop the row entirely, so the device may pair again as new.
    r.add("devices.forget", (JSONValue p) {
        immutable peer = requireString(p, "peerId");
        devices.remove(peer);
        events.emit("devices.changed", JSONValue.emptyObject);
        return JSONValue(["ok": JSONValue(true)]);
    });
}
