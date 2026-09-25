// UiBridge — the phone UI's Bridge, wrapping the core's.
//
// Two things the core cannot do for the UI once it runs in its own process
// (docs/phone-core-service.md): open the Android share sheet and ask for the photo
// permission. Both need the Activity, and the Activity lives in the UI process. So the core
// only resolves what to share / reports that the permission is missing, and this adapter —
// always in the UI process — does the Activity part. Everything else passes straight through.
//
// Step 1: it wraps the in-process LocalBridge, so behaviour is unchanged; later the same
// adapter wraps the socket client to the core service.
module photowagon.mobile.uiadapter;

import photowagon.mobile.localbridge : LocalBridge;
import photowagon.ui.transport : Bridge, ResultCb;

import qt.quick.qtimer;
import cppq = qt.quick.qobject;

import std.json;

version (Android)
{
    // mobile/jni/videothumb.c: ACTION_SEND through MainActivity.shareImage
    private extern (C) int pw_share_image(void* env, const char* path, const char* mime);
}

/// The UI's application object, as the QGuiApplication it is (set by main.d; holding it
/// here also keeps DSide's wrapper alive).
__gshared QGuiApplicationRef uiApp;

import qt.quick.qguiapplication : QGuiApplicationRef = QGuiApplication;

final class UiBridge : Bridge
{
    private Bridge inner;        // the core: in this process (local) or over its socket (CoreClient)
    private LocalBridge local;   // set when the core runs in this process
    private QTimer askPermission;
    private bool permissionAsked;

    this(LocalBridge local)
    {
        this.inner = local;
        this.local = local;
    }

    /// The core in another process (docs/phone-core-service.md, stage 5): the client delivers
    /// the core.state snapshot itself before reporting it is up.
    this(Bridge client)
    {
        this.inner = client;
    }

    override void start()
    {
        // forward what the core tells the UI (set before start, like Library does to us)
        inner.onEvent = &deliver;
        inner.onConnected = &coreUp;
        version (Android) {} else
        {
            import std.process : environment;
            import photowagon.mobile.pagingtest : PagingTest;

            immutable mode = environment.get("PW_TEST_PAGING", "");
            if (mode.length && local !is null)
                pagingTest = new PagingTest(local, mode);
        }
        inner.start();
        if (local !is null)
            testRelink();
        version (Android)
        {
            watchCore(false);   // armed from the start: a core that never comes up counts too
            if (local is null)
            {
                // back in front: photos taken meanwhile show up (the core lives on while the
                // UI is in the background, so no start-up scan covers them)
                import qt.quick.applicationstate : ApplicationState;

                if (uiApp !is null)
                    cast(void) uiApp.connectApplicationStateChanged(
                    (ApplicationState st) {
                        if (st == ApplicationState.ApplicationActive && inner.connected())
                            inner.request("library.rescan", JSONValue(null), (JSONValue r, JSONValue e) {});
                    });
            }
        }
    }

    private void deliver(string event, JSONValue data)
    {
        {
            if (testDown)   // a dropped link loses what the core says meanwhile
                return;
            version (Android) {} else
                if (pagingTest !is null && event == "computer.link" && data.type == JSONType.object)
                    pagingTest.onLink("connected" in data && data["connected"].type == JSONType.true_);
            version (Android) {} else
                if (pagingTest !is null && event == "index.done")
                    pagingTest.onIndexed();
            if (event == "core.permission" && data.type == JSONType.object && "needed" in data
                && data["needed"].type == JSONType.true_)
                permissionNeeded();
            if (event == "core.state" && data.type == JSONType.object && "permissionNeeded" in data
                && data["permissionNeeded"].type == JSONType.true_)
                permissionNeeded();
            if (onEvent)
                onEvent(event, data);
        }
    }

    // The core is (again) reachable: the UI gets its state snapshot FIRST, then "up" — so a
    // UI (re)connecting to a core that is already linked, indexing or waiting for a pairing
    // code shows that at once (and a stale "indexing" spinner is reset).
    private void coreUp(bool up)
    {
        version (Android)
            watchCore(up);
        if (up && local !is null)
        {
            local.beginSession();   // what the previous session had pending is cut short
            deliver("core.state", local.coreState());
        }
        if (onConnected)
            onConnected(up);
    }

    // PW_TEST_RELINK=<seconds>[:<gap>]: once, after that long, act as if the core went away
    // (its events are lost) and came back <gap> seconds later (default 1) — the recovery path
    // a separate core process will need, testable now.
    private QTimer relinkDown, relinkUp;
    private bool testDown;
    version (Android) {} else
        private import photowagon.mobile.pagingtest : PagingTest;
    version (Android) {} else
        private PagingTest pagingTest;

    private void testRelink()
    {
        import std.conv : to;
        import std.process : environment;
        import photowagon.mobile.plog : plog;

        import std.string : split;

        immutable spec = environment.get("PW_TEST_RELINK", "").split(":");
        if (spec.length == 0 || spec[0].length == 0)
            return;
        immutable s = spec[0];
        immutable gap = spec.length > 1 ? spec[1].to!int : 1;
        relinkDown = new QTimer(cast(cppq.QObject) null);
        relinkDown.setSingleShot(true);
        relinkDown.setInterval(s.to!int * 1000);
        relinkDown.connectTimeout({
            plog("ui: [test] core link down");
            testDown = true;
            if (onConnected)
                onConnected(false);
            relinkUp.start();
        });
        relinkUp = new QTimer(cast(cppq.QObject) null);
        relinkUp.setSingleShot(true);
        relinkUp.setInterval(gap * 1000);
        relinkUp.connectTimeout({
            testDown = false;
            plog("ui: [test] core link up: ", local.coreState().toString());
            coreUp(true);
        });
        relinkDown.start();
    }

    // Android: the core is the ":core" service. Android restarts it after a crash — but not
    // after crashes in quick succession, and a stopped one only at the next activity start.
    // While the UI is up and the core stays gone, ask MainActivity to start it (pwcore://),
    // backing off 2 s → 30 s.
    version (Android)
    {
        private QTimer coreWatch;
        private int coreWatchMs = 2000;

        private void watchCore(bool up)
        {
            if (local !is null)
                return;
            if (coreWatch is null)
            {
                coreWatch = new QTimer(cast(cppq.QObject) null);
                coreWatch.setSingleShot(true);
                coreWatch.connectTimeout({
                    if (inner.connected())
                        return;
                    {
                        // only while our activity is in front: starting it (and the service)
                        // from the background would pull it over another app or be refused;
                        // MainActivity.onStart starts the core when it comes back anyway
                        import qt.quick.qguiapplication : QGuiApplication;
                        import qt.quick.applicationstate : ApplicationState;

                        if (QGuiApplication.applicationState() != ApplicationState.ApplicationActive)
                        {
                            coreWatch.setInterval(coreWatchMs);
                            coreWatch.start();
                            return;
                        }
                    }
                    import qt.quick.qdesktopservices : QDesktopServices;
                    import qt.quick.qurl : QUrl;
                    import photowagon.mobile.plog : plog;

                    plog("ui: the phone core is still gone — asking for it to be started");
                    auto u = QUrl("pwcore://start", QUrl.ParsingMode.TolerantMode);
                    QDesktopServices.openUrl(u);
                    coreWatchMs = coreWatchMs * 2 > 30_000 ? 30_000 : coreWatchMs * 2;
                    coreWatch.setInterval(coreWatchMs);
                    coreWatch.start();
                });
            }
            if (up)
            {
                coreWatch.stop();
                coreWatchMs = 2000;
            }
            else if (!coreWatch.isActive())
            {
                coreWatch.setInterval(coreWatchMs);
                coreWatch.start();
            }
        }
    }

    override bool connected() const { return inner.connected(); }
    override bool remote() const { return inner.remote(); }
    override string endpoint() const { return inner.endpoint(); }
    override void setEndpoint(string host, ushort port) { inner.setEndpoint(host, port); }
    override void reconnect() { inner.reconnect(); }

    override void request(string method, JSONValue params, ResultCb cb)
    {
        version (Android) {} else
            if (pagingTest !is null && (method == "library.page" || method == "photo.neighbours"))
            {
                // the paging test owns the core's one listing; the UI's own would supersede it
                cb(JSONValue(null), JSONValue(["code": JSONValue("test"), "message": JSONValue("paging test running")]));
                return;
            }
        if (method == "photo.share")
        {
            inner.request(method, params, (JSONValue r, JSONValue e) {
                if (e.type != JSONType.null_)
                {
                    cb(r, e);
                    return;
                }
                immutable path = r.type == JSONType.object && "path" in r && r["path"].type == JSONType.string ? r["path"].str : "";
                immutable mime = r.type == JSONType.object && "mime" in r && r["mime"].type == JSONType.string ? r["mime"].str : "image/*";
                shareSheet(path, mime);
                // the same answer the UI always got: the sheet is up (its outcome is Android's)
                cb(JSONValue(["shared": JSONValue(true), "path": JSONValue(path)]), JSONValue(null));
            });
            return;
        }
        if (method == "photo.shareMany")
        {
            inner.request(method, params, (JSONValue r, JSONValue e) {
                if (e.type != JSONType.null_)
                {
                    cb(r, e);
                    return;
                }
                string joined;
                if (r.type == JSONType.object && "paths" in r && r["paths"].type == JSONType.array)
                    foreach (pth; r["paths"].array)
                        if (pth.type == JSONType.string)
                            joined ~= (joined.length ? "\n" : "") ~ pth.str;
                immutable mime = r.type == JSONType.object && "mime" in r && r["mime"].type == JSONType.string ? r["mime"].str : "*/*";
                // MainActivity.shareImage takes several paths one per line (ACTION_SEND_MULTIPLE)
                shareSheet(joined, mime);
                cb(r, e);
            });
            return;
        }
        inner.request(method, params, cb);
    }

    override void requestRaw(string method, string paramsJson, ResultCb cb)
    {
        // the share sheet is ours whichever way it is asked for (and the paging test's guard)
        if (method == "photo.share" || method == "photo.shareMany" || method == "library.page" || method == "photo.neighbours")
        {
            request(method, parseJSON(paramsJson), cb);
            return;
        }
        inner.requestRaw(method, paramsJson, cb);
    }

    /// Hand a local file to the OS share sheet (WhatsApp, e-mail, …).
    private static void shareSheet(string path, string mime)
    {
        version (Android)
        {
            import std.string : toStringz;
            import qt.quick.qjnienvironment : QJniEnvironment;

            if (path.length == 0)
                return;
            auto env = QJniEnvironment.getJniEnv();
            cast(void) pw_share_image(cast(void*) env, path.toStringz, mime.toStringz);
        }
    }

    /// The core found nothing readable: the photo permission is missing. Ask once, after the
    /// window has had its first frames (asking during Qt's startup left the window black).
    private void permissionNeeded()
    {
        if (permissionAsked)
            return;
        permissionAsked = true;
        askPermission = new QTimer(cast(cppq.QObject) null);
        askPermission.setSingleShot(true);
        askPermission.setInterval(900);
        askPermission.connectTimeout({
            import qt.quick.qdesktopservices : QDesktopServices;
            import qt.quick.qurl : QUrl;

            auto u = QUrl("pwperm://request", QUrl.ParsingMode.TolerantMode);
            QDesktopServices.openUrl(u);
        });
        askPermission.start();
    }
}
