// Host builds: the UI starts the phone core as its own child process (`<this exe> -service`)
// and talks to it over <dataDir>/core.sock (docs/phone-core-service.md, "Host builds", stage 6).
//
// The UI owns that child: it restarts it after an unexpected death (backing off), never after
// the shutdown it asked for, and not when the child left because another core already holds
// the data directory's lock (exit 3) — then the UI simply uses that one, and starts its own
// again only if no core is reachable any more. It only ever stops or reaps a child it started.
module photowagon.mobile.corehost;

version (Android) {} else:

import photowagon.mobile.coreipc : CoreClient;
import photowagon.mobile.plog : plog;

import qt.quick.qprocess;
import qt.quick.qtimer;
import qt.quick.qtsignals : QtdConnection;
import cppq = qt.quick.qobject;

import core.time : MonoTime, Duration, seconds, msecs;
import std.json;

enum int exitLockHeld = 3;   // coremain.d: another core holds the lock

final class CoreHost
{
    private CoreClient client;
    private QProcess proc;
    private QTimer restart, watch;
    private bool stopping, running;
    private MonoTime startedAt;
    private Duration backoff = 500.msecs;
    private int starts;

    this(CoreClient client)
    {
        this.client = client;
    }

    /// Start the child and the supervision.
    void start()
    {
        restart = new QTimer(cast(cppq.QObject) null);
        restart.setSingleShot(true);
        cast(void) restart.connectTimeout(&spawn);
        // no core reachable and no child of ours: start one (a core we deferred to died, or
        // ours left because of the lock and the holder is gone now)
        watch = new QTimer(cast(cppq.QObject) null);
        watch.setInterval(2000);
        cast(void) watch.connectTimeout({
            // (a UI another one took over is out of the game: it must not start cores either)
            if (!stopping && !running && !client.connected() && !client.isSuperseded()
                && !restart.isActive())
            {
                plog("ui: no phone core reachable — starting one");
                spawn();
            }
        });
        watch.start();
        spawn();
    }

    private void spawn()
    {
        import std.file : thisExePath;

        if (stopping || running)
            return;
        if (client.isSuperseded())
        {
            // another UI has the core now: its supervision is that UI's business, on every
            // path here (the watch, a restart after a crash)
            plog("ui: another UI took over the phone core — not starting one");
            return;
        }
        proc = new QProcess(cast(cppq.QObject) null);
        proc.setProcessChannelMode(QProcess.ProcessChannelMode.ForwardedChannels);   // its log is ours
        proc.setProgram(thisExePath());
        proc.setArguments(["-service"]);
        cast(void) proc.connectFinished(&finished);
        cast(void) proc.connectErrorOccurred((QProcess.ProcessError e) {
            // FailedToStart comes without finished()
            if (e == QProcess.ProcessError.FailedToStart && running)
            {
                running = false;
                plog("ui: the phone core could not be started");
                again();
            }
        });
        running = true;
        startedAt = MonoTime.currTime;
        starts++;
        proc.start(3 /* ReadWrite */);
        plog("ui: phone core started (pid ", proc.processId(), ", start ", starts, ")");
    }

    private void finished(int code, QProcess.ExitStatus status)
    {
        running = false;
        immutable crashed = status == QProcess.ExitStatus.CrashExit;
        if (stopping)
        {
            plog("ui: phone core stopped (", crashed ? "crashed" : "exit " ~ code.toStr, ")");
            return;
        }
        if (!crashed && code == exitLockHeld)
        {
            plog("ui: another phone core holds this data directory — using that one");
            return;   // the watch starts ours again if that one goes away
        }
        plog("ui: phone core died unexpectedly (", crashed ? "crashed" : "exit " ~ code.toStr, ") — restarting");
        again();
    }

    private void again()
    {
        // a core that ran a while gets restarted at once; one that keeps dying, slower
        if (MonoTime.currTime - startedAt > 60.seconds)
            backoff = 500.msecs;
        restart.setInterval(cast(int) backoff.total!"msecs");
        restart.start();
        backoff = backoff * 2 > 10.seconds ? 10.seconds : backoff * 2;
    }

    /// The UI is quitting: ask our child to shut down in order (it flushes its index), wait
    /// for it, and only then insist. A core we did not start is left alone.
    void stop()
    {
        stopping = true;
        if (watch !is null)
            watch.stop();
        if (restart !is null)
            restart.stop();
        if (!running || proc is null)
            return;
        plog("ui: stopping the phone core we started (pid ", proc.processId(), ")");
        // Only a core that IS our child is asked to quit: the socket may lead to another one (a
        // survivor our child is about to defer to).
        immutable ours = client.connected() && client.corePid() == proc.processId();
        bool asked;
        if (ours)
        {
            client.request("core.quit", JSONValue(null), (JSONValue r, JSONValue e) {});
            // waitForFinished does not run our event loop: the request must be out first
            asked = client.drainOutput(1500);
            if (!asked)
                plog("ui: could not hand the quit request to the phone core in time");
        }
        if (!proc.waitForFinished(asked ? 4000 : 100))
        {
            plog("ui: the phone core did not stop in time — terminating it");
            proc.terminate();
            if (!proc.waitForFinished(1000))
            {
                proc.kill();
                cast(void) proc.waitForFinished(1000);
            }
        }
        running = false;
    }
}

private string toStr(int v)
{
    import std.conv : to;

    return v.to!string;
}
