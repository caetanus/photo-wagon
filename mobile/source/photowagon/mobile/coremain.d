// The phone's core process: what CoreService (":core") runs. QtServiceBase loads the same
// .so as the activity and calls main() again with "-service"; main.d dispatches here.
//
// A QCoreApplication, not a QGuiApplication: this process has no window and no QML. It
// builds the core (indexer, faces, sync, p2p) and serves it to the UI over <dataDir>/core.sock
// (docs/phone-core-service.md). The same entry is the host's `-service` child. Kept in its
// own module because the qtdApplication mixin defines createApp(), and main.d already mixes
// one in for QGuiApplication.
module photowagon.mobile.coremain;

import photowagon.mobile.plog : plog, installCrashHandler, installQuitHandler;

import qt.quick.qcoreapplication;
import qt.quick.qtimer;
import cppq = qt.quick.qobject;

import qtmoc, cxxrt;

version (Android)
{
    // On Android the core must be a QAndroidService, not a plain QCoreApplication: its
    // constructor completes Qt's service setup, which QtServiceBase.onCreate() blocks the
    // Java main thread on — with a plain QCoreApplication onCreate never returned and the
    // system logged "Timeout executing service" and let the process be killed as a
    // non-foreground one. The binding does not generate it (private header
    // qandroidextras_p.h), so construct it like cxxrt's qtdApplication does: call the C++
    // constructor by its mangled name and wrap the object as the QCoreApplication it is.
    pragma(mangle, "_ZN15QAndroidServiceC1ERiPPci")
    extern (C++) private void __qAndroidServiceCtor(void*, ref int, char**, int);

    private QCoreApplication createApp(string name)
    {
        // Qt keeps a reference to argc and reads argv for the process lifetime: __gshared.
        __gshared int argc = 1;
        __gshared char[64] arg0;
        __gshared char*[2] argv;
        immutable n = name.length < arg0.length ? name.length : arg0.length - 1;
        arg0[0 .. n] = name[0 .. n];
        arg0[n] = '\0';
        argv = [arg0.ptr, null];
        // QAndroidService = QCoreApplication (16 bytes here) + a unique_ptr d; 64 is ample
        auto raw = __cpp_new(64);
        __qAndroidServiceCtor(raw, argc, argv.ptr, 0);
        return QCoreApplication.wrap(raw);
    }
}
else
    mixin(qtdApplication!"QCoreApplication");   // a host run of `-service`: no Android setup

enum CORE_ID = "photo-wagon-mobile";   // same app id: the same data/settings dirs as the UI

import photowagon.mobile.corefactory : PhoneCore;
import photowagon.mobile.coreipc : CoreServer;

private __gshared PhoneCore theCore;       // kept for the life of the process
private __gshared CoreServer theServer;
version (Android) {} else
    private __gshared QTimer dieTimer;

/// The core's entry. Never returns: like the UI's main it leaves with exit(), because
/// returning from D's main tears the runtime down under still-running threads.
int serviceMain()
{
    import core.stdc.stdlib : exit;
    import core.sys.posix.unistd : getpid;

    installCrashHandler();
    installQuitHandler();
    {
        // Android: the GC does not scan TLS on its own (android-tls-gc-roots) — the core's Qt
        // thread holds the p2p / vibe objects just like the UI's did
        import photowagon.mobile.plog : pinThreadTls;
        pinThreadTls("core qt thread");
    }
    {
        // same memory discipline as the UI process: no core dumps, bounded RSS
        import photowagon.core.jobs.memguard : startMemoryGuard, disableCoreDumps, raiseOpenFilesLimit;
        disableCoreDumps();
        cast(void) raiseOpenFilesLimit();   // p2p sockets + the index's files outgrow 1024
        startMemoryGuard(1536, "photo-wagon-core", false);
    }
    cast(void) createApp(CORE_ID);
    QCoreApplication.setOrganizationName("PhotoWagon");
    QCoreApplication.setApplicationName(CORE_ID);
    plog("core: service process up (pid ", getpid(), ")");

    {
        // The core proper — index, faces, computer link, sync, local bridge — served to the UI
        // over <dataDir>/core.sock (stage 7 on Android: the ":core" CoreService process; on the
        // host the child the UI starts). QtServiceBase quitting the app (CoreService onDestroy,
        // after onTimeout's stopSelf too) runs aboutToQuit: the one orderly shutdown.
        import photowagon.mobile.corefactory : buildPhoneCore, CoreLockedException;
        import core.time : seconds;

        try
            theCore = buildPhoneCore();
        catch (CoreLockedException e)
        {
            plog("core: ", e.msg, " — not starting a second one");
            exit(3);
        }
        theServer = new CoreServer(theCore.bridge, theCore.dataDir);
        theServer.start();
        theCore.bridge.start();
        QCoreApplication.instance().connectAboutToQuit({ theCore.shutdown(2.seconds); });
    }
    version (Android) {} else
    {
        {
            // PW_TEST_CORE_DIE_AFTER=<ms>: die (exit 1) that long after starting — the UI's
            // restart supervision test (it must back off)
            import std.conv : to;
            import std.process : environment;

            immutable die = environment.get("PW_TEST_CORE_DIE_AFTER", "");
            if (die.length)
            {
                dieTimer = new QTimer(QCoreApplication.instance());
                dieTimer.setSingleShot(true);
                dieTimer.setInterval(die.to!int);
                dieTimer.connectTimeout({ plog("core: [test] dying"); exit(1); });
                dieTimer.start();
            }
        }
    }

    // Heartbeat: shows in logcat that the core keeps running after the UI is gone.
    auto beat = new QTimer(QCoreApplication.instance());
    beat.setInterval(30_000);
    beat.connectTimeout(() { plog("core: alive (pid ", getpid(), ")"); });
    beat.start();

    immutable rc = QCoreApplication.exec();
    plog("core: exiting ", rc);
    exit(rc);
}
