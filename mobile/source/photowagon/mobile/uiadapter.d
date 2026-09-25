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

final class UiBridge : Bridge
{
    private LocalBridge inner;
    private QTimer askPermission;
    private bool permissionAsked;

    this(LocalBridge inner)
    {
        this.inner = inner;
    }

    override void start()
    {
        // forward what the core tells the UI (set before start, like Library does to us)
        inner.onEvent = (string event, JSONValue data) {
            if (testDown)   // a dropped link loses what the core says meanwhile
                return;
            if (event == "core.permission" && data.type == JSONType.object && "needed" in data
                && data["needed"].type == JSONType.true_)
                permissionNeeded();
            if (onEvent)
                onEvent(event, data);
        };
        inner.onConnected = &coreUp;
        inner.start();
        testRelink();
    }

    // The core is (again) reachable: the UI gets its state snapshot FIRST, then "up" — so a
    // UI (re)connecting to a core that is already linked, indexing or waiting for a pairing
    // code shows that at once (and a stale "indexing" spinner is reset).
    private void coreUp(bool up)
    {
        if (up)
        {
            immutable st = inner.coreState();
            if (st["permissionNeeded"].type == JSONType.true_)
                permissionNeeded();
            if (onEvent)
                onEvent("core.state", st);
        }
        if (onConnected)
            onConnected(up);
    }

    // PW_TEST_RELINK=<seconds>[:<gap>]: once, after that long, act as if the core went away
    // (its events are lost) and came back <gap> seconds later (default 1) — the recovery path
    // a separate core process will need, testable now.
    private QTimer relinkDown, relinkUp;
    private bool testDown;

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
            plog("ui: [test] core link up: ", inner.coreState().toString());
            coreUp(true);
        });
        relinkDown.start();
    }

    override bool connected() const { return inner.connected(); }
    override bool remote() const { return inner.remote(); }
    override string endpoint() const { return inner.endpoint(); }
    override void setEndpoint(string host, ushort port) { inner.setEndpoint(host, port); }
    override void reconnect() { inner.reconnect(); }

    override void request(string method, JSONValue params, ResultCb cb)
    {
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
        inner.request(method, params, cb);
    }

    override void requestRaw(string method, string paramsJson, ResultCb cb)
    {
        if (method == "photo.share")   // the share sheet is ours whichever way it is asked for
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
