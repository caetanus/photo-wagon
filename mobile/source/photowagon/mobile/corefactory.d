// The phone's core, built in one place: where its files live, the photo index, the link to
// the computer and the local bridge that serves the UI's line protocol from them.
//
// Step 1 of moving the core into its own process (docs/phone-core-service.md): today the UI
// process still builds it (main.d), exactly as before; the service process (coremain.d) will
// call the same function once the core moves there.
module photowagon.mobile.corefactory;

import photowagon.mobile.plog : plog;
import photowagon.mobile.localbridge : LocalBridge;
import photowagon.mobile.phoneindex : PhoneIndex;
import photowagon.mobile.p2pbridge : P2pBridge;

import qt.quick.qstandardpaths;

import std.file : exists;
import std.path : buildPath, dirName;
import std.process : environment;
import std.string : indexOf, split;

/// DCIM/ and Pictures/ of the device (or PW_PHONE_ROOTS on a desktop test).
string[] photoRoots()
{
    immutable forced = environment.get("PW_PHONE_ROOTS", "");
    if (forced.length)
        return forced.split(":");
    // On Android Qt's writable PicturesLocation is the app's own
    // Android/data/<pkg>/files/Pictures — empty, and the DCIM next to it does not
    // exist. The camera roll is under the shared storage that folder lives in.
    immutable pictures = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.PicturesLocation).toString();
    string base = pictures.dirName;
    immutable at = pictures.indexOf("/Android/data/");
    if (at > 0)
        base = pictures[0 .. at];
    else if (!buildPath(base, "DCIM").exists && environment.get("EXTERNAL_STORAGE", "").length)
        base = environment["EXTERNAL_STORAGE"];
    return [buildPath(base, "DCIM"), buildPath(base, "Pictures")];
}

/// The core's parts. Whoever builds it keeps this alive for the life of the process.
final class PhoneCore
{
    string dataDir, cacheDir;
    P2pBridge computer;   // the link to the computer (libp2p or hyperswarm flavor)
    PhoneIndex index;     // the phone's own photos
    LocalBridge bridge;   // the line protocol the UI talks, served from the two above
}

/// Build the core. Needs the Qt application object (QStandardPaths) and runs on the Qt thread,
/// where the index and the bridge live. No scan and no network yet — the bridge's start()
/// begins those — but PhoneIndex's constructor already brings up the on-device face worker
/// (its thread and model extraction) on Android.
PhoneCore buildPhoneCore()
{
    auto core = new PhoneCore;
    core.dataDir = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppDataLocation).toString();
    core.cacheDir = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.CacheLocation).toString();
    auto roots = photoRoots();
    plog("phone: roots ", roots, " data ", core.dataDir, " cache ", core.cacheDir);

    immutable settings = buildPath(core.dataDir, "settings");
    core.computer = new P2pBridge(settings);
    // PW_ENDPOINT=host:port overrides the saved computer (tests, first run).
    immutable forced = environment.get("PW_ENDPOINT", "");
    if (forced.length)
        core.computer.setEndpoint(forced, 0);
    core.index = new PhoneIndex(roots, core.dataDir, core.cacheDir);
    core.bridge = new LocalBridge(core.index, core.computer, settings);
    return core;
}
