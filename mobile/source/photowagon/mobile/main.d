// Photo Wagon mobile: the phone's own photos in the Qt Quick UI, in D, with a
// link to a computer running `photo-wagon --serve` to send them to. On Android
// Qt's activity loads this as a shared library and calls main(); on the
// desktop it is an ordinary executable (for offscreen tests, with
// PW_PHONE_ROOTS=/dir[:/dir] standing in for DCIM/ and Pictures/).
module photowagon.mobile.main;

import photowagon.mobile.plog : plog, installCrashHandler, captureStdioToLogcat, logTls, installQuitHandler;

import qt.quick.qguiapplication;
import qt.quick.qcoreapplication;
import qt.quick.qqmlapplicationengine;
import qt.quick.qqmlcontext;
import qt.quick.qstandardpaths;
import qt.quick.qurl;
import qt.quick.qresource;          // QResource, used by the qrcRegister mixin
import cppq = qt.quick.qobject;

import qtmoc, cxxrt, qrc;

import std.path : buildPath, dirName;
import std.process : environment;
import std.stdio : writeln, stdout, stderr;
import std.string : split, indexOf;
import std.file : exists;

import photowagon.ui.backend : Library;
import photowagon.mobile.localbridge : LocalBridge;
import photowagon.mobile.phoneindex : PhoneIndex;
import photowagon.mobile.p2pbridge : P2pBridge;

// GC statistics on (read back every 100 photos in phoneindex): a stop-the-world
// collection pauses the Qt thread too, and that is what a stall looks like.
extern (C) __gshared string[] rt_options = ["gcopt=profile:1"];

enum APP_ID      = "photo-wagon-mobile";
enum APP_NAME    = "Photo Wagon";
enum APP_VERSION = "0.4.0";

mixin(qtdApplication!"QGuiApplication");
// The resource tree is assembled in CTFE from qml/mobile.qrc (-J=../qml).
mixin(qrcRegister(import("mobile.qrc"), "qt.quick"));

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

/// Under the emulator's ARM translation the environment QtLoader set (plugin and
/// QML paths) is invisible here; MainActivity writes it to settings/qt-env and we
/// take it from there. On a real device the variables are already present.
void adoptQtEnvironment()
{
    version (Android)
    {
        import core.thread : Thread;
        import core.time : msecs;
        import std.file : exists, readText;
        import std.string : splitLines, indexOf;

        if (environment.get("QT_PLUGIN_PATH", "").length)
            return;
        immutable file = buildPath(QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppDataLocation).toString(),
            "settings", "qt-env");
        foreach (i; 0 .. 60)   // MainActivity.onCreate writes it right after Qt started loading
        {
            if (file.exists)
                break;
            Thread.sleep(50.msecs);
        }
        if (!file.exists)
        {
            plog("qt-env: not found, hoping the environment is fine");
            return;
        }
        foreach (line; readText(file).splitLines)
        {
            immutable eq = line.indexOf('=');
            if (eq > 0)
                environment[line[0 .. eq]] = line[eq + 1 .. $];
        }
        plog("qt-env: adopted, plugin path ", environment.get("QT_PLUGIN_PATH", ""));
    }
}

int main()
{
    captureStdioToLogcat();
    adoptQtEnvironment();
    if ("QT_QUICK_CONTROLS_STYLE" !in environment)
        environment["QT_QUICK_CONTROLS_STYLE"] = "Material";
    version (Android)
    {
        environment["QSG_INFO"] = "1";           // scene graph setup lines in logcat (tag qt.scenegraph.general)
        environment["QSG_RENDER_TIMING"] = "1";  // per-frame polish / sync / render times: where a stall is spent
        environment["QT_LOGGING_RULES"] = "qt.qpa.window=true;qt.qpa.android=true;qt.scenegraph.general=true";   // window expose / hide
    }
    installCrashHandler();
    {
        // the user's rule: past 1.5 GB resident the app kills itself with SIGSEGV, so the
        // crash handler above writes its backtrace and the dump can be read
        import photowagon.core.jobs.memguard : startMemoryGuard;
        startMemoryGuard(1536, "photo-wagon-mobile");
    }
    installQuitHandler();
    logTls("qt thread");
    {
        import core.thread : Thread;
        auto probe = new Thread({ logTls("a new thread"); });
        probe.start();
        probe.join();
    }

    cast(void) createApp(APP_ID);
    QCoreApplication.setOrganizationName("PhotoWagon");
    QCoreApplication.setApplicationName(APP_ID);
    QCoreApplication.setApplicationVersion(APP_VERSION);
    QGuiApplication.setApplicationDisplayName(APP_NAME);

    immutable dataDir = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppDataLocation).toString();
    immutable cacheDir = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.CacheLocation).toString();
    auto roots = photoRoots();
    plog("phone: roots ", roots, " data ", dataDir, " cache ", cacheDir);

    auto lib = newQObject!Library();
    auto computer = new P2pBridge(buildPath(dataDir, "settings"));
    // PW_ENDPOINT=host:port overrides the saved computer (tests, first run).
    immutable forced = environment.get("PW_ENDPOINT", "");
    if (forced.length)
        computer.setEndpoint(forced, 0);
    auto index = new PhoneIndex(roots, dataDir, cacheDir);
    lib.start(new LocalBridge(index, computer, buildPath(dataDir, "settings")));

    auto engine = new QQmlApplicationEngine(cast(cppq.QObject) null);
    engine.rootContext().setContextProperty("library", cppq.QObject.wrap(qobjOf(lib)));

    bool failed;
    engine.connectObjectCreationFailed((const(QUrl)* u) {
        failed = true;
        plog("QML: object creation failed");
    });

    auto url = QUrl("qrc:/mobile/Main.qml", QUrl.ParsingMode.TolerantMode);
    engine.load(url);

    auto rootObjects = engine.rootObjects();
    plog("qml rootObjects = ", rootObjects.length, failed ? " (creation failed)" : "");
    if (rootObjects.length == 0 || failed)
        return 1;

    immutable rc = QCoreApplication.exec();
    // Leave without returning: returning from a D main() tears the runtime down
    // (rt_term) while the decoder, sync and libp2p threads still run, and the
    // next allocation on any of them is a SIGSEGV — what Android's Back key did
    // to the app for a while. exit() ends the process with them.
    plog("phone: exiting ", rc);
    import core.stdc.stdlib : exit;
    exit(rc);
}
