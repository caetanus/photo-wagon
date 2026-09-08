// CoreBridge — the UI's only link to the core.
//
// The core runs on its own thread in this process (core.daemon.CoreThread) and
// speaks the line protocol of docs/ipc.md through an InProcessLink: requests go
// into its queue, answers and events come back through ours. The core wakes us
// through a pipe; a QSocketNotifier on that pipe drains the queue on the Qt
// thread, so callbacks always run where QObjects may be touched. If the
// notifier's signal cannot be connected (a binding gap), a 20 ms QTimer drains
// it instead.
//
// Not a @QObject itself: it owns bound Qt objects and one small @QObject slot
// holder for the notifier connection.
module photowagon.ui.bridge;

import qt.quick.qsocketnotifier;
import qt.quick.qtimer;
import cppq = qt.quick.qobject;

import qtmoc;

import std.json;
import std.stdio : writeln, stdout, stderr;
import std.string : strip;

import photowagon.core.ipc.link : InProcessLink;

alias ResultCb = void delegate(JSONValue result, JSONValue error);
alias EventCb  = void delegate(string event, JSONValue data);

/// The receiving end of `QSocketNotifier::activated`: a slot that forwards to D.
@QObject class Pump
{
    void delegate() target;

    @Slot void fire()
    {
        if (target)
            target();
    }
}

final class CoreBridge
{
    EventCb onEvent;                     /// unsolicited {"event":..,"data":..}
    void delegate(bool up) onConnected;  /// link state changes

    private InProcessLink link;
    private Pump pump;
    private QSocketNotifier notifier;
    private QTimer fallback;
    private ResultCb[long] pending;
    private long nextId = 1;
    private bool up;

    this(InProcessLink link)
    {
        this.link = link;
    }

    /// Wires the wake-up. Call after the application object exists.
    void start()
    {
        pump = newQObject!Pump();
        pump.target = &drain;

        notifier = new QSocketNotifier(link.wakeFd, QSocketNotifier.Type.Read, cast(cppq.QObject) null);
        bool wired;
        foreach (sig; ["activated(QSocketDescriptor,QSocketNotifier::Type)", "activated(int)"])
            if (tryConnectMeta(notifier.ptr(), sig, pump, "fire()"))
            {
                wired = true;
                break;
            }
        if (wired)
            notifier.setEnabled(true);
        else
        {
            writeln("bridge: QSocketNotifier signal not connectable; polling every 20 ms");
            stdout.flush();
            fallback = new QTimer(cast(cppq.QObject) null);
            fallback.setInterval(20);
            fallback.connectTimeout(&drain);
            fallback.start();
        }

        up = true;
        if (onConnected)
            onConnected(true);
    }

    bool connected() const { return up; }

    /// Send a request; `cb` runs once, on the Qt thread, with a result or an error object.
    void request(string method, JSONValue params, ResultCb cb)
    {
        JSONValue msg = JSONValue.emptyObject;
        immutable id = nextId++;
        msg["id"] = id;
        msg["method"] = method;
        if (params.type != JSONType.null_)
            msg["params"] = params;
        pending[id] = cb;
        link.submit(msg.toString() ~ "\n");
    }

    /// Convenience for parameterless calls.
    void request(string method, ResultCb cb)
    {
        request(method, JSONValue(null), cb);
    }

    // ---- inbound (Qt thread) ----------------------------------------------------

    private void drain()
    {
        foreach (raw; link.takeOutbox())
        {
            immutable line = raw.strip();
            if (line.length == 0)
                continue;
            JSONValue obj;
            try
                obj = parseJSON(line);
            catch (JSONException e)
            {
                stderr.writeln("bridge: bad line: ", line);
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
                if (idp.type != JSONType.integer)
                    continue;
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
}
