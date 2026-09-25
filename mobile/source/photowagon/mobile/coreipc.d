// The UI ⟷ phone-core socket (docs/phone-core-service.md, "Transport" and "Failure
// semantics"): the line protocol of docs/ipc.md — one JSON object per line — over a
// QLocalSocket at <dataDir>/core.sock. CoreServer lives with the core and serves its
// LocalBridge to one UI session at a time; CoreClient is the UI's Bridge to it.
//
// Stage 5: the transport. The host core (`-service`) serves it and a UI started with
// PW_CORE_SOCKET=<path> uses it; the UI spawning and supervising the core is stage 6, the
// Android service owning the core stage 7.
module photowagon.mobile.coreipc;

import photowagon.mobile.localbridge : LocalBridge;
import photowagon.mobile.plog : plog;
import photowagon.ui.transport : Bridge, ResultCb;

import qt.quick.qcoreapplication : QCoreApplication;
import qt.quick.qlocalserver;
import qt.quick.qlocalsocket;
import qt.quick.qtimer;
import qt.quick.qtsignals : QtdConnection;
import cppq = qt.quick.qobject;

import core.time : MonoTime, Duration, msecs, seconds;
import std.conv : to;
import std.json;

enum size_t maxFrame = 32 << 20;        // one line; a remote preview used to be the largest
enum long maxQueuedOut = 64 << 20;      // unsent output per connection before it is dropped
enum size_t maxOutstanding = 1024;      // requests in flight per client
enum size_t framesPerTurn = 64;         // frames handled per event-loop turn (then a zero-timer)

/// Newline framing, incremental: bytes come in arbitrary pieces (a frame split across reads,
/// several frames in one), complete lines come out. A line longer than maxFrame is an
/// overflow — the connection is then dropped, never resynchronised.
struct LineFramer
{
    private char[] buf;
    private size_t start;      // first byte not yet returned
    private size_t scanned;    // bytes after `start` known to hold no newline
    bool overflow;

    void feed(const(char)[] data)
    {
        // compact once the consumed prefix dominates, so the buffer does not grow forever
        if (start > 0 && start * 2 > buf.length)
        {
            buf = buf[start .. $].dup;
            start = 0;
        }
        buf ~= data;
    }

    /// The next complete line (without its newline), or false.
    bool next(out string line)
    {
        import std.string : indexOf;

        if (overflow)
            return false;
        immutable from = start + scanned;
        immutable at = buf[from .. $].indexOf('\n');
        if (at < 0)
        {
            scanned = buf.length - start;
            if (scanned > maxFrame)
                overflow = true;
            return false;
        }
        immutable end = from + at;
        if (end - start > maxFrame)
        {
            overflow = true;
            return false;
        }
        line = buf[start .. end].idup;
        start = end + 1;
        scanned = 0;
        return true;
    }

    size_t pendingBytes() const { return buf.length - start; }
}

/// Read what the socket has into the framer, up to what the framer may hold (pointer API: no
/// QByteArray by value). What is not read stays in Qt's bounded buffer and the kernel's, so a
/// client that sends faster than frames are handled is slowed down, never buffered without
/// bound. True when more bytes are waiting.
private bool readInto(QLocalSocket s, ref LineFramer f)
{
    char[64 * 1024] chunk;
    enum size_t cap = maxFrame + 64 * 1024;
    for (;;)
    {
        immutable avail = s.bytesAvailable();
        if (avail <= 0)
            return false;
        if (f.pendingBytes >= cap)
            return true;
        immutable room = cap - f.pendingBytes;
        long want = avail < chunk.length ? avail : chunk.length;
        if (want > room)
            want = room;
        immutable n = s.read(chunk.ptr, want);
        if (n <= 0)
            return false;
        f.feed(chunk[0 .. cast(size_t) n]);
    }
}

private JSONValue err(string code, string message)
{
    return JSONValue(["code": JSONValue(code), "message": JSONValue(message)]);
}

// ---- the core side ------------------------------------------------------------------------

/// Serves a LocalBridge on <dataDir>/core.sock. One UI session at a time. A connection
/// becomes the session with its first frame, `core.hello {uiInstance}`: it supersedes the
/// previous session (which gets a terminal `session_superseded` event and is closed after its
/// output drains, aborted after 1 s) — unless it comes from a UI instance this core already
/// superseded in favour of a session that is still live: that one is refused, so two UIs
/// cannot evict each other in a loop even when the terminal event was lost. Background work
/// never depends on a session.
final class CoreServer
{
    private LocalBridge bridge;
    private string path;
    private QLocalServer server;
    private ServerConn session;
    private ServerConn[] conns;        // every live connection (session, joining, closing)
    private bool[string] supersededUis;
    private bool hadSession;
    private QTimer tick, soon, quitSoon;
    private enum Duration helloWithin = 5.seconds, drainWithin = 1.seconds;

    this(LocalBridge bridge, string dataDir)
    {
        import std.path : buildPath;

        this.bridge = bridge;
        path = buildPath(dataDir, "core.sock");
    }

    string socketPath() const { return path; }

    /// Listen. Only the holder of the data directory's core lock may remove a stale socket
    /// file (a dead core's), so this requires the lock.
    void start()
    {
        import photowagon.mobile.corelock : holdsCoreLock;
        import std.file : exists, remove;

        if (!holdsCoreLock())
            throw new Exception("the core socket needs the core lock");
        // sockaddr_un.sun_path: 108 bytes with the terminator. Real data dirs are well under
        // (Android's /data/user/0/<pkg>/files/... about 80), deep test dirs may not be.
        if (path.length > 107)
            throw new Exception("the core socket path is too long for a Unix socket (" ~ path.length.to!string
                ~ " > 107 bytes): " ~ path);
        if (path.exists)
            remove(path);   // stale: we hold the lock, so no live core owns it
        server = new QLocalServer(cast(cppq.QObject) null);
        server.setSocketOptions(QLocalServer.SocketOption.UserAccessOption);
        if (!server.listen(path))
            throw new Exception("cannot listen on " ~ path ~ ": " ~ server.errorString().toString());
        cast(void) server.connectNewConnection(&accept);
        // one timer for every connection's deadlines, one zero-timer for their leftover work:
        // no Qt objects per connection but its socket
        tick = new QTimer(cast(cppq.QObject) null);
        tick.setInterval(250);
        cast(void) tick.connectTimeout(&onTick);
        tick.start();
        soon = new QTimer(cast(cppq.QObject) null);
        soon.setSingleShot(true);
        soon.setInterval(0);
        cast(void) soon.connectTimeout(&onSoon);
        bridge.onEvent = (string ev, JSONValue data) {
            if (session !is null)
                session.sendEvent(ev, data);
        };
        bridge.onConnected = (bool) {};   // the core is up for a UI once a session attaches
        plog("core: serving the UI on ", path);
    }

    private void accept()
    {
        for (;;)
        {
            auto s = server.nextPendingConnection();
            if (s is null || s.ptr() is null)
                break;
            conns ~= new ServerConn(this, s);
        }
    }

    private void hello(ServerConn c, long id, JSONValue params)
    {
        string ui;
        if (params.type == JSONType.object)
            if (auto u = "uiInstance" in params)
                if (u.type == JSONType.string)
                    ui = u.str;
        if (ui.length == 0 || ui.length > 128)
            return c.answer(id, JSONValue(null), err("invalid_request", "core.hello needs a uiInstance"), false);
        if (ui in supersededUis && session !is null && session.ui != ui)
        {
            // an old UI coming back while the one that took over is still here: refuse
            plog("core: refusing UI ", ui, " (superseded; session ", session.serial, " is live)");
            c.answer(id, JSONValue(null), err("session_superseded", "another UI has the phone core"), false);
            c.closeDraining();
            return;
        }
        if (session !is null && session !is c)
        {
            // a local: sending may drop it (over the output limit), which clears `session`
            auto old = session;
            if (old.ui != ui)
                supersededUis[old.ui] = true;
            old.sendEvent("session_superseded", JSONValue.emptyObject);
            old.superseded = true;
            old.closeDraining();
            plog("core: UI session ", old.serial, " superseded");
        }
        supersededUis.remove(ui);
        session = c;
        c.ui = ui;
        c.attached = true;
        import core.sys.posix.unistd : getpid;

        // the core's pid: a UI that started a core as its child can tell whether this is it
        c.answer(id, JSONValue(["session": JSONValue(c.serial), "pid": JSONValue(cast(long) getpid())]),
            JSONValue(null), false);
        // a new session: whatever the previous one had pending is cut short, then the
        // snapshot — the UI is "up" once it has it
        bridge.beginSession();
        c.sendEvent("core.state", bridge.coreState());
        // A UI (re)attaching to a core that kept running: photos may have come and gone while
        // no UI was up — look again (the first session coincides with the start's own scan).
        if (hadSession)
            bridge.request("library.rescan", JSONValue(null), (JSONValue r, JSONValue e) {});
        hadSession = true;
        plog("core: UI session ", c.serial, " attached (ui ", ui, ")");
    }

    /// Forget a connection: out of every list, its socket scheduled for deletion.
    private void gone(ServerConn c)
    {
        import std.algorithm : remove;

        if (session is c)
        {
            session = null;
            plog("core: UI session ", c.serial, " ended (the core keeps running)");
        }
        foreach (i, x; conns)
            if (x is c)
            {
                conns = conns.remove(i);
                break;
            }
    }

    private void wantSoon()
    {
        if (!soon.isActive())
            soon.start();
    }

    private void onSoon()
    {
        foreach (c; conns.dup)
            if (c.needMore)
                c.drain();
    }

    private void onTick()
    {
        immutable now = MonoTime.currTime;
        foreach (c; conns.dup)
        {
            if (c.dead)
                continue;
            if (c.closingSince != MonoTime.init && now - c.closingSince >= drainWithin)
                c.dispose("did not drain in time", true);
            else if (!c.attached && c.closingSince == MonoTime.init && now - c.born >= helloWithin)
                c.drop("no core.hello within " ~ helloWithin.total!"seconds".to!string ~ " s");
        }
    }

    private void dispatch(ServerConn c, long id, string method, JSONValue params)
    {
        switch (method)
        {
        case "bridge.setEndpoint":   // the UI's Bridge.setEndpoint, carried over
            {
                string host;
                long port;
                if (params.type == JSONType.object)
                {
                    if (auto h = "host" in params)
                        if (h.type == JSONType.string)
                            host = h.str;
                    if (auto p = "port" in params)
                        if (p.type == JSONType.integer)
                            port = p.integer;
                }
                bridge.setEndpoint(host, cast(ushort) port);
                c.answer(id, JSONValue(["endpoint": JSONValue(bridge.endpoint())]), JSONValue(null));
                return;
            }
        case "bridge.reconnect":
            bridge.reconnect();
            c.answer(id, JSONValue.emptyObject, JSONValue(null));
            return;
        case "core.quit":   // the UI that started this core is quitting (host child mode)
            plog("core: asked to quit by UI session ", c.serial);
            c.answer(id, JSONValue.emptyObject, JSONValue(null));
            if (quitSoon is null)
            {
                quitSoon = new QTimer(cast(cppq.QObject) null);
                quitSoon.setSingleShot(true);
                quitSoon.setInterval(0);
                // the orderly path: aboutToQuit -> PhoneCore.shutdown (flushes the index)
                cast(void) quitSoon.connectTimeout({ QCoreApplication.quit(); });
            }
            quitSoon.start();
            return;
        default:
            bridge.request(method, params, (JSONValue r, JSONValue e) { c.answer(id, r, e); });
        }
    }
}

private final class ServerConn
{
    private static long serials;
    immutable long serial;
    private CoreServer owner;
    private QLocalSocket sock;
    private LineFramer framer;
    private bool[long] outstanding;
    private QtdConnection cRead, cDisc;
    string ui;
    immutable MonoTime born;
    MonoTime closingSince;
    bool dead, superseded, attached, needMore;

    this(CoreServer owner, QLocalSocket sock)
    {
        serial = ++serials;
        born = MonoTime.currTime;
        this.owner = owner;
        this.sock = sock;
        sock.setReadBufferSize(256 * 1024);   // the framer, not Qt, holds up to a frame
        cRead = sock.connectReadyRead(&drain);
        cDisc = sock.connectDisconnected(&onDisconnected);
        drain();   // bytes that came with the connection
    }

    void drain()
    {
        needMore = false;
        if (dead)
            return;
        immutable waiting = readInto(sock, framer);
        size_t n;
        string line;
        while (!dead && n < framesPerTurn && framer.next(line))
        {
            n++;
            handle(line);
        }
        if (dead)
            return;
        if (framer.overflow)
            return drop("a frame over " ~ (maxFrame >> 20).to!string ~ " MiB");
        if (n == framesPerTurn || waiting)
        {
            needMore = true;   // the rest next turn, not at the next readyRead
            owner.wantSoon();
        }
    }

    private void handle(string line)
    {
        if (superseded || closingSince != MonoTime.init)
            return;   // its replies would be discarded anyway
        JSONValue m;
        try
            m = parseJSON(line);
        catch (Exception)
            return drop("a frame that is not JSON");
        if (m.type != JSONType.object)
            return drop("a frame that is not an object");
        auto idp = "id" in m;
        if (idp is null || idp.type != JSONType.integer)
            return drop("a request without an integer id");
        immutable id = idp.integer;
        auto mp = "method" in m;
        if (mp is null || mp.type != JSONType.string)
            return answer(id, JSONValue(null), err("invalid_request", "method must be a string"), false);
        JSONValue params;
        if (auto pp = "params" in m)
        {
            if (pp.type != JSONType.object && pp.type != JSONType.null_)
                return answer(id, JSONValue(null), err("invalid_request", "params must be an object or null"), false);
            params = *pp;
        }
        if (!attached)
        {
            if (mp.str != "core.hello")
                return answer(id, JSONValue(null), err("hello_required", "the first request must be core.hello"), false);
            return owner.hello(this, id, params);
        }
        if (id in outstanding)
            return answer(id, JSONValue(null), err("duplicate_id", "that id is still outstanding"), false);
        if (outstanding.length >= maxOutstanding)
            return answer(id, JSONValue(null), err("too_many_requests", "over the outstanding-request limit"), false);
        outstanding[id] = true;
        owner.dispatch(this, id, mp.str, params);
    }

    /// Reply to request `id` — once; a reply for a connection that is gone is dropped.
    void answer(long id, JSONValue r, JSONValue e, bool tracked = true)
    {
        if (dead || superseded)
            return;
        if (tracked)
        {
            if (id !in outstanding)
                return;
            outstanding.remove(id);
        }
        JSONValue msg = JSONValue.emptyObject;
        msg["id"] = id;
        if (e.type != JSONType.null_)
            msg["error"] = e;
        else
            msg["result"] = r;
        send(msg.toString());
    }

    void sendEvent(string ev, JSONValue data)
    {
        if (dead)
            return;
        send(JSONValue(["event": JSONValue(ev), "data": data]).toString());
    }

    private void send(string line)
    {
        // Qt buffers what the kernel does not take yet; that buffer is the output queue
        if (sock.bytesToWrite() + cast(long) line.length + 1 > maxQueuedOut)
            return drop("over " ~ (maxQueuedOut >> 20).to!string ~ " MiB of unsent output");
        cast(void) sock.write(line.ptr, line.length);
        cast(void) sock.write("\n".ptr, 1);
    }

    /// Superseded or refused: let the last frames drain, then close; the server's tick aborts
    /// it after a second.
    void closeDraining()
    {
        if (dead || closingSince != MonoTime.init)
            return;
        closingSince = MonoTime.currTime;
        sock.disconnectFromServer();   // drains pending output first; disconnected() follows
    }

    /// A protocol violation or a flooding client: discard it (abort drops its output).
    void drop(string why)
    {
        dispose(why, true);
    }

    private void onDisconnected()
    {
        dispose(null, false);
    }

    /// The one way out, idempotent: sever the signal connections (they GC-root this object),
    /// release the buffers, let Qt delete the socket (the server owns it), forget it.
    void dispose(string why, bool abort)
    {
        if (dead)
            return;
        dead = true;
        if (why.length)
            plog("core: dropping UI connection ", serial, ": ", why);
        cRead.disconnect();
        cDisc.disconnect();
        if (abort)
            sock.abort();
        sock.deleteLater();
        framer = LineFramer.init;
        outstanding = null;
        owner.gone(this);
    }
}

// ---- the UI side --------------------------------------------------------------------------

/// The UI's Bridge to a core on a local socket. Requests made before the core is ready (QML
/// asks during component completion) wait in a bounded queue with a 15 s deadline; on a
/// disconnect every outstanding request fails once with core_restarting and the client
/// reconnects (every 100 ms for 2 s, then backing off to 2 s). "Up" means the core's
/// core.state snapshot arrived — delivered as an event first.
final class CoreClient : Bridge
{
    private string path;
    private QLocalSocket sock;
    private LineFramer framer;
    private bool ready, superseded, started;
    private long gen;                  // connection generation: callbacks are keyed by it
    private struct Waiting { ResultCb cb; long gen; }
    private Waiting[long] waiting;
    private long nextReq = 1;
    private struct Queued { long id; string frame; ResultCb cb; MonoTime deadline; }
    private Queued[] queue;
    private size_t queuedBytes;
    private enum size_t queueMax = 1024, queueBytesMax = 8 << 20;
    private enum Duration queueDeadline = 15.seconds;
    private QTimer retry, expire, more;
    private MonoTime downSince;
    private string cachedEndpoint;
    private bool coreLinked;
    private immutable string uiInstance;   // who this UI is, for the core's supersession rule
    private long peerPid;                  // the connected core's pid (from its hello answer)

    this(string socketPath)
    {
        import std.format : format;
        import std.random : uniform;
        import core.sys.posix.unistd : getpid;

        path = socketPath;
        uiInstance = format("%d-%016x", getpid(), uniform!ulong());
    }

    override void start()
    {
        if (started)
            return;
        started = true;
        sock = new QLocalSocket(cast(cppq.QObject) null);
        sock.setReadBufferSize(maxFrame + 64 * 1024);
        sock.connectReadyRead(&drain);
        sock.connectConnected(&sayHello);
        sock.connectDisconnected(&lost);
        sock.connectErrorOccurred((QLocalSocket.LocalSocketError) {
            // a failed connect (no core yet) also lands here, without a disconnected()
            if (!ready)
                scheduleRetry();
            else
                lost();
        });
        retry = new QTimer(cast(cppq.QObject) null);
        retry.setSingleShot(true);
        retry.connectTimeout(&dial);
        expire = new QTimer(cast(cppq.QObject) null);
        expire.setInterval(500);
        expire.connectTimeout(&expireQueued);
        more = new QTimer(cast(cppq.QObject) null);
        more.setSingleShot(true);
        more.setInterval(0);
        more.connectTimeout(&drain);
        downSince = MonoTime.currTime;
        dial();
    }

    private void dial()
    {
        if (superseded)
            return;
        sock.abort();   // a previous attempt's state, if any
        framer = LineFramer.init;
        sock.connectToServer(path, 3 /* QIODevice::ReadWrite */);
    }

    private void scheduleRetry()
    {
        if (superseded || retry.isActive())
            return;
        // the core may be starting: ask often at first; a missing socket may also be a core
        // deliberately stopped, so back off
        immutable since = MonoTime.currTime - downSince;
        long ms = since < 2.seconds ? 100 : 100 + (since - 2.seconds).total!"msecs" / 4;
        if (ms > 2000)
            ms = 2000;
        retry.setInterval(cast(int) ms);
        retry.start();
    }

    /// The first frame of every connection: which UI this is. The core answers and then
    /// sends its core.state snapshot — the moment this client is "ready".
    private void sayHello()
    {
        immutable id = nextReq++;
        JSONValue msg = ["id": JSONValue(id), "method": JSONValue("core.hello"),
            "params": JSONValue(["uiInstance": JSONValue(uiInstance)])];
        waiting[id] = Waiting((JSONValue r, JSONValue e) {
            if (e.type == JSONType.null_ && r.type == JSONType.object && "pid" in r
                && r["pid"].type == JSONType.integer)
                peerPid = r["pid"].integer;
            if (e.type == JSONType.object && "code" in e && e["code"].type == JSONType.string
                && e["code"].str == "session_superseded")
            {
                superseded = true;
                plog("ui: the core refused this UI: another one took over — not reconnecting");
            }
        }, gen);
        immutable line = msg.toString();
        cast(void) sock.write(line.ptr, line.length);
        cast(void) sock.write("\n".ptr, 1);
    }

    /// The core sent something that breaks the protocol: treat it as a lost connection.
    private void violation(string why)
    {
        plog("ui: protocol error from the core (", why, ") — reconnecting");
        sock.abort();
        lost();
    }

    private void lost()
    {
        immutable wasReady = ready;
        ready = false;
        // every ended attempt, ready or not: a new generation (drain() stops at it and late
        // answers are ignored), no frames of the old connection, nothing waiting on it —
        // detached first, so a callback that asks again lands in the (new) queue
        gen++;
        framer = LineFramer.init;
        auto failing = waiting;
        waiting = null;
        if (wasReady)
        {
            downSince = MonoTime.currTime;
            plog("ui: core link lost");
            if (onConnected)
                try
                    onConnected(false);
                catch (Exception e)
                    plog("ui: handling the core going away threw: ", e.msg);
        }
        foreach (id, w; failing)
            try
                w.cb(JSONValue(null), err("core_restarting", "the phone core went away"));
            catch (Exception e)
                plog("ui: a failed request's callback threw: ", e.msg);
        scheduleRetry();
    }

    private void drain()
    {
        immutable myGen = gen;
        immutable waitingBytes = readInto(sock, framer);
        size_t n;
        string line;
        while (n < framesPerTurn && framer.next(line))
        {
            n++;
            handle(line);
            if (gen != myGen)
                return;   // the connection was dropped while handling
        }
        if (framer.overflow)
            return violation("a frame over the limit");
        if (n == framesPerTurn || waitingBytes)
            more.start();
    }

    private void handle(string line)
    {
        JSONValue m;
        try
            m = parseJSON(line);
        catch (Exception)
            return violation("a frame that is not JSON");
        if (m.type != JSONType.object)
            return violation("a frame that is not an object");
        if (auto ev = "event" in m)
        {
            if (ev.type != JSONType.string || "id" in m)
                return violation("a malformed event");
            auto data = "data" in m ? m["data"] : JSONValue(null);
            return onCoreEvent(ev.str, data);
        }
        auto idp = "id" in m;
        if (idp is null || idp.type != JSONType.integer)
            return violation("a response without an integer id");
        auto rp = "result" in m, ep = "error" in m;
        if ((rp is null) == (ep is null))
            return violation("a response needs exactly one of result and error");
        if (ep !is null && (ep.type != JSONType.object || !("code" in *ep) || (*ep)["code"].type != JSONType.string))
            return violation("an error without a string code");
        auto w = idp.integer in waiting;
        if (w is null || w.gen != gen)
            return;   // not ours (a previous connection's) or already failed
        auto cb = w.cb;
        waiting.remove(idp.integer);
        // one failing callback must not strand the answers after it
        try
            cb(rp !is null ? *rp : JSONValue(null), ep !is null ? *ep : JSONValue(null));
        catch (Exception ex)
            plog("ui: a request's callback threw: ", ex.msg);
    }

    private static bool validState(JSONValue d)
    {
        if (d.type != JSONType.object)
            return false;
        foreach (k; ["computer", "sync", "indexing"])
            if (!(k in d) || d[k].type != JSONType.object)
                return false;
        return true;
    }

    private void onCoreEvent(string ev, JSONValue data)
    {
        switch (ev)
        {
        case "core.state":
            if (!validState(data))
                return violation("a core.state without computer/sync/indexing");
            {
                if (auto ep = "endpoint" in data)
                    if (ep.type == JSONType.string)
                        cachedEndpoint = ep.str;
                if (auto c = "computer" in data)
                    if (c.type == JSONType.object && "connected" in *c)
                        coreLinked = (*c)["connected"].type == JSONType.true_;
            }
            deliver(ev, data);
            if (!ready)
            {
                ready = true;
                retry.stop();
                plog("ui: core ready (", path, ")");
                // what waited goes out FIRST, in order; only then is the UI told the core is
                // up (Library.onLink refreshes at once — after the queued requests, not before)
                flushQueue();
                if (ready && onConnected)
                    try
                        onConnected(true);
                    catch (Exception e)
                        plog("ui: handling the core coming up threw: ", e.msg);
            }
            return;
        case "session_superseded":
            // another UI took the core: this one stops, and does not fight back
            superseded = true;
            plog("ui: the core session was taken over by another UI — not reconnecting");
            return;
        case "computer.link":
            if (data.type == JSONType.object)
            {
                if (auto ep = "endpoint" in data)
                    if (ep.type == JSONType.string)
                        cachedEndpoint = ep.str;
                coreLinked = "connected" in data && data["connected"].type == JSONType.true_;
            }
            break;
        default:
            break;
        }
        deliver(ev, data);
    }

    private void deliver(string ev, JSONValue data)
    {
        if (onEvent)
            try
                onEvent(ev, data);
            catch (Exception ex)
                plog("ui: handling the core's ", ev, " threw: ", ex.msg);
    }

    // ---- requests ---------------------------------------------------------------------

    override bool connected() const { return ready; }
    override bool remote() const { return false; }

    /// The pid of the core this client is connected to (0 before its hello answer).
    long corePid() const { return ready ? peerPid : 0; }

    /// Another UI took the core over: this client will not reconnect.
    bool isSuperseded() const { return superseded; }

    /// Write out everything buffered for the core, waiting up to `ms` (before blocking without
    /// the event loop — the core must actually receive what was asked). True when all is out.
    bool drainOutput(int ms)
    {
        if (sock is null)
            return false;
        immutable deadline = MonoTime.currTime + ms.msecs;
        while (sock.bytesToWrite() > 0)
        {
            immutable left = (deadline - MonoTime.currTime).total!"msecs";
            if (left <= 0 || !sock.waitForBytesWritten(cast(int) left))
                return sock.bytesToWrite() == 0;
        }
        return true;
    }
    override string endpoint() const { return cachedEndpoint; }

    override void setEndpoint(string host, ushort port)
    {
        import std.conv : to;

        // optimistic: Library reads endpoint() right after; core.state corrects it
        cachedEndpoint = port ? host ~ ":" ~ port.to!string : host;
        request("bridge.setEndpoint", JSONValue(["host": JSONValue(host), "port": JSONValue(cast(long) port)]),
            (JSONValue r, JSONValue e) {
                if (e.type == JSONType.null_ && r.type == JSONType.object && "endpoint" in r
                    && r["endpoint"].type == JSONType.string)
                    cachedEndpoint = r["endpoint"].str;
            });
    }

    override void reconnect()
    {
        request("bridge.reconnect", JSONValue(null), (JSONValue r, JSONValue e) {});
    }

    override void request(string method, JSONValue params, ResultCb cb)
    {
        JSONValue msg = JSONValue.emptyObject;
        immutable id = nextReq++;
        msg["id"] = id;
        msg["method"] = method;
        if (params.type != JSONType.null_)
            msg["params"] = params;
        submit(id, msg.toString(), cb);
    }

    override void requestRaw(string method, string paramsJson, ResultCb cb)
    {
        // spliced, not re-parsed: an import's base64 can be megabytes
        immutable id = nextReq++;
        JSONValue head = JSONValue(["id": JSONValue(id), "method": JSONValue(method)]);
        immutable h = head.toString();
        submit(id, h[0 .. $ - 1] ~ `,"params":` ~ (paramsJson.length ? paramsJson : "null") ~ "}", cb);
    }

    private void submit(long id, string frame, ResultCb cb)
    {
        if (frame.length > maxFrame)
        {
            cb(JSONValue(null), err("too_large", "request over the frame limit"));
            return;
        }
        if (ready)
        {
            send(id, frame, cb);
            return;
        }
        if (superseded)
        {
            cb(JSONValue(null), err("session_superseded", "another UI has the phone core"));
            return;
        }
        if (queue.length >= queueMax || queuedBytes + frame.length > queueBytesMax)
        {
            cb(JSONValue(null), err("core_unavailable", "the phone core is not up and the queue is full"));
            return;
        }
        enqueue(Queued(id, frame, cb, MonoTime.currTime + queueDeadline));
    }

    private void enqueue(Queued x)
    {
        queue ~= x;
        queuedBytes += x.frame.length;
        if (!expire.isActive())
            expire.start();
    }

    private void send(long id, string frame, ResultCb cb)
    {
        if (sock.bytesToWrite() + cast(long) frame.length + 1 > maxQueuedOut)
        {
            cb(JSONValue(null), err("core_busy", "too much unsent output to the phone core"));
            return;
        }
        waiting[id] = Waiting(cb, gen);
        cast(void) sock.write(frame.ptr, frame.length);
        cast(void) sock.write("\n".ptr, 1);
    }

    private void flushQueue()
    {
        auto q = queue;
        queue = null;
        queuedBytes = 0;
        expire.stop();
        foreach (x; q)
        {
            if (x.deadline <= MonoTime.currTime)   // its time ran out before the core came up
            {
                try
                    x.cb(JSONValue(null), err("core_unavailable", "the phone core did not come up in time"));
                catch (Exception e)
                    plog("ui: an expired request's callback threw: ", e.msg);
            }
            else if (ready)
                send(x.id, x.frame, x.cb);
            else
                enqueue(x);   // lost again meanwhile: back in the queue, same deadline
        }
    }

    private void expireQueued()
    {
        immutable now = MonoTime.currTime;
        Queued[] keep, late;
        foreach (x; queue)
            (x.deadline <= now ? late : keep) ~= x;
        queue = keep;
        queuedBytes = 0;
        foreach (x; keep)
            queuedBytes += x.frame.length;
        if (queue.length == 0)
            expire.stop();
        foreach (x; late)
            try
                x.cb(JSONValue(null), err("core_unavailable", "the phone core did not come up in time"));
            catch (Exception e)
                plog("ui: an expired request's callback threw: ", e.msg);
    }
}
