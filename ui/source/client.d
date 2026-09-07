// DaemonClient — the UI's only link to photowagond.
//
// One QTcpSocket on the loopback, JSON objects one per line (docs/ipc.md).
// Discovery: the daemon writes its port to $XDG_RUNTIME_DIR/photowagon/daemon.port
// (fallback ~/.local/share/photowagon/daemon.port). If the file is missing or
// the connection is refused, we spawn photowagond ourselves and keep retrying on
// a 500 ms timer. The same timer drives reconnection after a disconnect.
//
// Not a @QObject: it owns bound Qt objects (socket, timer, process) and talks to
// them through the typed connect* delegates the binding provides.
module client;

import qt.quick.qtcpsocket;
import qt.quick.qabstractsocket;
import qt.quick.qtimer;
import qt.quick.qprocess;
import qt.quick.qcoreapplication;
import cppq = qt.quick.qobject;

import std.json;
import std.stdio : writeln, stdout, stderr;
import std.file : exists, readText, isFile;
import std.path : buildPath, expandTilde;
import std.string : strip;
import std.conv : to;
import std.process : environment;
import std.datetime.systime : SysTime;
import core.time : seconds;

alias ResultCb = void delegate(JSONValue result, JSONValue error);
alias EventCb  = void delegate(string event, JSONValue data);

final class DaemonClient
{
    EventCb onEvent;                     /// unsolicited {"event":..,"data":..}
    void delegate(bool up) onConnected;  /// link state changes

    private QTcpSocket sock;
    private QTimer retry;
    private SysTime spawnedAt;           // last spawn attempt; throttles retries
    private bool refused;                // last connect was refused → port file is stale
    private ResultCb[long] pending;
    private string[] outbox;             // requests made while disconnected
    private long nextId = 1;
    private bool up;

    this()
    {
        sock = new QTcpSocket(cast(cppq.QObject) null);
        sock.connectReadyRead(&onReadyRead);
        sock.connectConnected(&onSockConnected);
        sock.connectDisconnected(&onSockDisconnected);
        sock.connectErrorOccurred(&onSockError);

        retry = new QTimer(cast(cppq.QObject) null);
        retry.setInterval(500);
        retry.connectTimeout(&tick);
    }

    /// Begin connecting (and spawning if needed). Idempotent.
    void start()
    {
        tick();
        retry.start();
    }

    bool connected() const { return up; }

    /// Send a request; `cb` runs once with either a result or an error object.
    void request(string method, JSONValue params, ResultCb cb)
    {
        JSONValue msg = JSONValue.emptyObject;
        immutable id = nextId++;
        msg["id"] = id;
        msg["method"] = method;
        if (params.type != JSONType.null_)
            msg["params"] = params;
        pending[id] = cb;
        immutable line = msg.toString() ~ "\n";
        if (up)
            sock.write(line);
        else
            outbox ~= line;
    }

    /// Convenience for parameterless calls.
    void request(string method, ResultCb cb)
    {
        request(method, JSONValue(null), cb);
    }

    // ---- connection lifecycle -------------------------------------------------

    private void tick()
    {
        if (sock.state() != QAbstractSocket.SocketState.UnconnectedState)
            return;
        immutable port = readPort();
        if (port == 0 || refused)
        {
            refused = false;
            spawnDaemon();
            if (port == 0)
                return;
        }
        sock.connectToHost("127.0.0.1", port, 3 /* ReadWrite */,
                           QAbstractSocket.NetworkLayerProtocol.IPv4Protocol);
    }

    private void onSockConnected()
    {
        up = true;
        refused = false;
        writeln("daemon: connected on port ", sock.peerPort()); stdout.flush();
        foreach (line; outbox)
            sock.write(line);
        outbox.length = 0;
        if (onConnected)
            onConnected(true);
    }

    private void onSockDisconnected()
    {
        if (!up)
            return;
        up = false;
        writeln("daemon: disconnected"); stdout.flush();
        failAll("disconnected");
        if (onConnected)
            onConnected(false);
    }

    private void onSockError(QAbstractSocket.SocketError err)
    {
        if (err == QAbstractSocket.SocketError.ConnectionRefusedError)
            refused = true;
        if (up)
            onSockDisconnected();
    }

    private void failAll(string why)
    {
        auto cbs = pending;
        pending = null;
        JSONValue e = JSONValue.emptyObject;
        e["code"] = "disconnected";
        e["message"] = why;
        foreach (id, cb; cbs)
            cb(JSONValue(null), e);
    }

    // ---- inbound --------------------------------------------------------------

    private void onReadyRead()
    {
        while (sock.canReadLine())
        {
            immutable line = sock.readLine(0).toString().strip();
            if (line.length == 0)
                continue;
            JSONValue obj;
            try
                obj = parseJSON(line);
            catch (JSONException e)
            {
                stderr.writeln("daemon: bad line: ", line);
                continue;
            }
            if (obj.type != JSONType.object)
                continue;
            if (auto ev = "event" in obj)
            {
                if (onEvent)
                    onEvent(ev.str, "data" in obj ? obj["data"] : JSONValue(null));
                continue;
            }
            if (auto idp = "id" in obj)
            {
                immutable id = idp.integer;
                if (auto cb = id in pending)
                {
                    auto f = *cb;
                    pending.remove(id);
                    f("result" in obj ? obj["result"] : JSONValue(null),
                      "error" in obj ? obj["error"] : JSONValue(null));
                }
            }
        }
    }

    // ---- discovery + spawn ------------------------------------------------------

    static string portFile()
    {
        immutable rt = environment.get("XDG_RUNTIME_DIR", "");
        if (rt.length)
            return buildPath(rt, "photowagon", "daemon.port");
        return expandTilde("~/.local/share/photowagon/daemon.port");
    }

    private static ushort readPort()
    {
        immutable f = portFile();
        if (!exists(f) || !isFile(f))
            return 0;
        try
            return readText(f).strip().to!ushort;
        catch (Exception)
            return 0;
    }

    /// Where photowagond might be: beside us, in ../daemon/, then PATH.
    private static string findDaemon()
    {
        immutable dir = QCoreApplication.applicationDirPath().toString();
        foreach (cand; [buildPath(dir, "photowagond"), buildPath(dir, "..", "daemon", "photowagond")])
            if (exists(cand) && isFile(cand))
                return cand;
        return "photowagond"; // QProcess resolves PATH
    }

    private void spawnDaemon()
    {
        // A daemon is a service: start it detached so it outlives this UI and the
        // next launch finds it through the port file. Its output goes to a log
        // file, not our stdout — a forwarded pipe would keep our parent shell
        // waiting after we exit. Do not retry more often than every 5 s.
        import std.datetime.systime : Clock, SysTime;
        import std.file : mkdirRecurse;
        import std.path : dirName;
        immutable now = Clock.currTime();
        if (spawnedAt != SysTime.init && now - spawnedAt < 5.seconds)
            return;
        spawnedAt = now;
        immutable exe = findDaemon();
        immutable log = logFile();
        writeln("daemon: spawning ", exe, " (log: ", log, ")"); stdout.flush();
        try
            mkdirRecurse(dirName(log));
        catch (Exception) {}
        auto proc = new QProcess(cast(cppq.QObject) null);
        proc.setProgram(exe);
        proc.setArguments(cast(string[]) []);
        proc.setStandardOutputFile(log, 2 /* WriteOnly */ | 4 /* Append */);
        proc.setStandardErrorFile(log, 2 | 4);
        long pid;
        if (!proc.startDetached(&pid))
        {
            writeln("daemon: could not start ", exe); stdout.flush();
        }
    }

    static string logFile()
    {
        immutable st = environment.get("XDG_STATE_HOME", "");
        if (st.length)
            return buildPath(st, "photowagon", "daemon.log");
        return expandTilde("~/.local/state/photowagon/daemon.log");
    }
}
