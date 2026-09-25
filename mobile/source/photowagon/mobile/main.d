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
import photowagon.ui.transport : Bridge;
import photowagon.mobile.corefactory : buildPhoneCore, PhoneCore, CoreLockedException;
import photowagon.mobile.uiadapter : UiBridge;
// static: coremain mixes in its own createApp (QCoreApplication); keep it out of this scope
static import photowagon.mobile.coremain;

// GC statistics on (read back every 100 photos in phoneindex): a stop-the-world
// collection pauses the Qt thread too, and that is what a stall looks like.
extern (C) __gshared string[] rt_options = ["gcopt=profile:1"];

enum APP_ID      = "photo-wagon-mobile";
enum APP_NAME    = "Photo Wagon";
enum APP_VERSION = "0.4.0";

mixin(qtdApplication!"QGuiApplication");

// Kept for the life of the process (main never returns: it leaves with exit()).
private __gshared PhoneCore phoneCore;
version (Android) {} else
{
    import photowagon.mobile.corehost : CoreHost;

    private __gshared CoreHost coreHost;   // host: the core child this UI started
}
// The resource tree is assembled in CTFE from qml/mobile.qrc (-J=../qml).
mixin(qrcRegister(import("mobile.qrc"), "qt.quick"));

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
    {
        // CoreService (":core") loads this same .so and calls main() with "-service"
        // (android.app.arguments in the manifest): run the core, not the UI.
        import core.runtime : Runtime;
        import std.algorithm : canFind;
        if (Runtime.args.canFind("-service"))
            return photowagon.mobile.coremain.serviceMain();
    }
    if ("QT_QUICK_CONTROLS_STYLE" !in environment)
        environment["QT_QUICK_CONTROLS_STYLE"] = "Material";
    version (Android)
    {
        // Diagnostics OFF by default: QSG_RENDER_TIMING logs the polish/sync/render/swap of
        // EVERY frame to logcat — at 60 fps that per-frame logging is itself a drag on the
        // scrolling it is meant to measure. Turn them on only when chasing a stall, by setting
        // PW_QT_DEBUG=1 in the environment.
        if ("PW_QT_DEBUG" in environment)
        {
            environment["QSG_INFO"] = "1";
            environment["QSG_RENDER_TIMING"] = "1";
            environment["QT_LOGGING_RULES"] = "qt.qpa.window=true;qt.qpa.android=true;qt.scenegraph.general=true";
        }
    }
    installCrashHandler();
    {
        // Bound memory, but NEVER dump a core on the phone: a SIGSEGV core dump here is
        // multi-GB, fills /data, makes Android evict the thumbnail cache, and spirals into
        // a re-decode + OOM loop. Disable cores outright and, at the limit, exit cleanly —
        // Android restarts us and the index resumes from its last save.
        import photowagon.core.jobs.memguard : startMemoryGuard, disableCoreDumps;
        disableCoreDumps();
        startMemoryGuard(1536, "photo-wagon-mobile", false);
    }
    installQuitHandler();
    logTls("qt thread");
    {
        import photowagon.mobile.plog : pinThreadTls;
        pinThreadTls("qt thread");
    }
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
    // Survive backgrounding. The root QML object is an ApplicationWindow; when Android sends the
    // app to the background the surface is destroyed and Qt treats that as the last window closing,
    // which quit the event loop and ended the whole process (main did exit(rc)) — the app "died"
    // the moment the user switched away (e.g. to toggle Wi-Fi). Sync is meant to keep running in
    // the background, so do not quit on window close; Android reclaims the process under pressure
    // and the sync service restarts it.
    QGuiApplication.setQuitOnLastWindowClosed(false);

    auto lib = newQObject!Library();
    // The core (index, computer link, local bridge) — built here in the UI process for now;
    // the UI talks to it only through UiBridge, which also does the Activity-bound parts
    // (share sheet, permission prompt). See docs/phone-core-service.md.
    // Host builds run the core in its own process by default: the UI starts it as a child
    // (`-service`) and is its client over <dataDir>/core.sock (stage 6). PW_CORE_SOCKET=<path>
    // uses a core someone else started; PW_CORE_INPROC=1 keeps the old single-process wiring
    // (and the in-process test hooks). Android: the UI process still builds the core until
    // stage 7.
    string coreSocket = environment.get("PW_CORE_SOCKET", "");
    bool childCore;
    version (Android) {} else
        if (coreSocket.length == 0 && environment.get("PW_CORE_INPROC", "") != "1")
        {
            import std.path : buildPath;

            coreSocket = buildPath(QStandardPaths.writableLocation(
                QStandardPaths.StandardLocation.AppDataLocation).toString(), "core.sock");
            childCore = true;
        }
    if (coreSocket.length)
    {
        import photowagon.mobile.coreipc : CoreClient;

        plog("ui: using the core at ", coreSocket, childCore ? " (our child)" : "");
        auto client = new CoreClient(coreSocket);
        lib.start(new UiBridge(cast(Bridge) client));
        version (Android) {} else
            if (childCore)
            {
                import photowagon.mobile.corehost : CoreHost;

                coreHost = new CoreHost(client);
                coreHost.start();
                QCoreApplication.instance().connectAboutToQuit({ coreHost.stop(); });
            }
    }
    else
    {
        try
            phoneCore = buildPhoneCore();
        catch (CoreLockedException e)
        {
            // Two cores on one data directory would interleave their writes. Stage 7 turns
            // this into "connect to the running one"; until then, say so and leave.
            import core.stdc.stdlib : exit;

            plog("phone: ", e.msg, " — not starting a second one");
            exit(3);
        }
        lib.start(new UiBridge(phoneCore.bridge));
        // an orderly quit (the desktop window closed, QCoreApplication.quit) flushes the
        // index; SIGTERM/SIGINT keep their immediate exit (the atomic checkpoints are the
        // fallback)
        QCoreApplication.instance().connectAboutToQuit({
            import core.time : seconds;

            phoneCore.shutdown(2.seconds);
        });
    }
    version (Android) {} else
    {
        testViewer(lib);
        testQuit();
    }

    // The binding collects unparented D-owned QObjects. Keep the engine owned by
    // the application throughout exec(), after this local's last use: collecting
    // it also destroys the QML window, even while the indexer keeps running.
    auto engine = new QQmlApplicationEngine(QCoreApplication.instance());
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

version (Android) {} else
{
    import qt.quick.qtimer : QTimer;

    private __gshared QTimer viewerOpen, viewerReport, viewerRelist, quitTimer;

    // PW_TEST_QUIT=<seconds>: quit through the orderly path after that long (the shutdown
    // test: the index on disk must hold what was indexed until then).
    private void testQuit()
    {
        import std.conv : to;

        immutable s = environment.get("PW_TEST_QUIT", "");
        if (s.length == 0)
            return;
        quitTimer = new QTimer(cast(cppq.QObject) null);
        quitTimer.setSingleShot(true);
        quitTimer.setInterval(s.to!int * 1000);
        quitTimer.connectTimeout({
            if (phoneCore !is null)
                plog("ui: [test] quitting: ", phoneCore.index.length, " photos indexed");
            else
                plog("ui: [test] quitting");
            QCoreApplication.quit();
        });
        quitTimer.start();
    }

    // PW_TEST_VIEWER=<photo id>:<seconds>[:<ms>]: open that photo in the viewer after
    // <seconds>, and log what the viewer shows 20 s later (its prev/next) — with
    // PW_TEST_RELINK, the viewer's recovery across a core reconnect. <ms>: start a new
    // listing that long after opening, cutting its neighbours search short.
    private void testViewer(Library lib)
    {
        import std.conv : to;

        auto spec = environment.get("PW_TEST_VIEWER", "").split(":");
        if (spec.length < 2)
            return;
        if (spec.length > 2)
        {
            viewerRelist = new QTimer(cast(cppq.QObject) null);
            viewerRelist.setSingleShot(true);
            viewerRelist.setInterval(spec[2].to!int);
            viewerRelist.connectTimeout({
                plog("ui: [test] new listing while the viewer looks for neighbours");
                lib.loadPage(0, 60, 0, 0, 0);
            });
        }
        immutable id = spec[0].to!int;
        viewerOpen = new QTimer(cast(cppq.QObject) null);
        viewerOpen.setSingleShot(true);
        viewerOpen.setInterval(spec[1].to!int * 1000);
        viewerOpen.connectTimeout({
            plog("ui: [test] open photo ", id);
            lib.openPhoto(id);
            viewerReport.start();
            if (viewerRelist !is null)
                viewerRelist.start();
        });
        viewerReport = new QTimer(cast(cppq.QObject) null);
        viewerReport.setSingleShot(true);
        viewerReport.setInterval(20_000);
        viewerReport.connectTimeout({
            import std.json : parseJSON, JSONType;

            auto cur = lib.current.length ? parseJSON(lib.current) : parseJSON("{}");
            plog("ui: [test] viewer shows ", "id" in cur ? cur["id"].toString() : "nothing",
                " prev ", "prev" in cur ? cur["prev"].toString() : "-",
                " next ", "next" in cur ? cur["next"].toString() : "-",
                " file ", "fileUrl" in cur && cur["fileUrl"].type == JSONType.string
                    ? cur["fileUrl"].str[0 .. cur["fileUrl"].str.length < 48 ? $ : 48] : "-");
        });
        viewerOpen.start();
    }
}
