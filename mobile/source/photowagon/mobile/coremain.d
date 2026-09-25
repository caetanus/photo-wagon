// The phone's core process: what CoreService (":core") runs. QtServiceBase loads the same
// .so as the activity and calls main() again with "-service"; main.d dispatches here.
//
// A QCoreApplication, not a QGuiApplication: this process has no window and no QML. For
// now it only proves the lifecycle — it comes up, stays up with the UI gone, and logs a
// heartbeat; the indexer, faces, sync and p2p move in behind a local IPC next (see the
// phone-core-in-qtservice plan). Kept in its own module because the qtdApplication mixin
// defines createApp(), and main.d already mixes one in for QGuiApplication.
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

version (Android) {} else
{
    import photowagon.mobile.corefactory : PhoneCore;
    import photowagon.mobile.coreipc : CoreServer;

    private __gshared PhoneCore hostCore;      // kept for the life of the process
    private __gshared CoreServer hostServer;
    private __gshared QTimer dieTimer;
}

/// The core's entry. Never returns: like the UI's main it leaves with exit(), because
/// returning from D's main tears the runtime down under still-running threads.
int serviceMain()
{
    import core.stdc.stdlib : exit;
    import core.sys.posix.unistd : getpid;

    installCrashHandler();
    installQuitHandler();
    {
        // same memory discipline as the UI process: no core dumps, bounded RSS
        import photowagon.core.jobs.memguard : startMemoryGuard, disableCoreDumps;
        disableCoreDumps();
        startMemoryGuard(1536, "photo-wagon-core", false);
    }
    cast(void) createApp(CORE_ID);
    QCoreApplication.setOrganizationName("PhotoWagon");
    QCoreApplication.setApplicationName(CORE_ID);
    plog("core: service process up (pid ", getpid(), ")");

    version (Android) {} else
    {
        // Host: the core proper — index, computer link, local bridge — served to a UI over
        // <dataDir>/core.sock (stage 5). On Android the UI process still builds the core until
        // stage 7 (two cores would fight over the data directory's lock).
        import photowagon.mobile.corefactory : buildPhoneCore, CoreLockedException;
        import photowagon.mobile.coreipc : CoreServer;
        import core.time : seconds;

        try
            hostCore = buildPhoneCore();
        catch (CoreLockedException e)
        {
            plog("core: ", e.msg, " — not starting a second one");
            exit(3);
        }
        hostServer = new CoreServer(hostCore.bridge, hostCore.dataDir);
        hostServer.start();
        hostCore.bridge.start();
        QCoreApplication.instance().connectAboutToQuit({ hostCore.shutdown(2.seconds); });
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
