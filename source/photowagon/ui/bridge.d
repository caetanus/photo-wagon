// CoreBridge — the UI's link to the core thread in this process.
//
// The core (core.daemon.CoreThread) speaks the line protocol of docs/ipc.md
// through an InProcessLink: requests go into its queue, answers and events come
// back through ours. The core wakes us through a pipe; a QSocketNotifier on
// that pipe drains the queue on the Qt thread, so callbacks always run where
// QObjects may be touched. If the notifier's signal cannot be connected (a
// binding gap), a 20 ms QTimer drains it instead.
module photowagon.ui.bridge;

import qt.quick.qsocketnotifier;
import qt.quick.qtimer;
import cppq = qt.quick.qobject;

import qtmoc;

import std.json;
import std.stdio : writeln, stdout;

import photowagon.core.ipc.link : InProcessLink;
import photowagon.ui.transport : Bridge, ResultCb;

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

final class CoreBridge : Bridge
{
    private InProcessLink link;
    private Pump pump;
    private QSocketNotifier notifier;
    private QTimer fallback;
    private bool up;

    this(InProcessLink link)
    {
        this.link = link;
    }

    override void start()
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

    override bool connected() const { return up; }

    override void request(string method, JSONValue params, ResultCb cb)
    {
        link.submit(enqueue(method, params, cb));
    }

    private void drain()
    {
        foreach (line; link.takeOutbox())
            deliverLine(line);
    }
}
