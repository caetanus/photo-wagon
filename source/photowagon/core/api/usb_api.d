/// `usb.*` methods: pulling the camera roll off a plugged-in phone over adb.
module photowagon.core.api.usb_api;

import std.json;

import photowagon.core.ipc.protocol;
import photowagon.core.usb.watcher : UsbWatcher;

/// `watcher` may be null (headless / no desktop UI); `usb.sync` then errors.
void registerUsbApi(Registry r, UsbWatcher watcher)
{
	r.add("usb.sync", (JSONValue p) {
		if (watcher is null)
			throw new ApiError("usb_off", "USB sync runs only with the desktop UI");
		watcher.syncDevice(requireString(p, "serial"));
		return JSONValue(["started": JSONValue(true)]);
	});
}
