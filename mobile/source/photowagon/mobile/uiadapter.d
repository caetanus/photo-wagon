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
        // before start(): the first scan can already find the permission missing
        inner.onPermissionNeeded = &permissionNeeded;
    }

    override void start()
    {
        // forward what the core tells the UI (set before start, like Library does to us)
        inner.onEvent = (string event, JSONValue data) {
            if (onEvent)
                onEvent(event, data);
        };
        inner.onConnected = (bool up) {
            if (onConnected)
                onConnected(up);
        };
        inner.start();
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
