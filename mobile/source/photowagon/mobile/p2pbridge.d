// P2pBridge — the phone's link to the computer over libp2p.
//
// A pairing code carries the computer's libp2p addresses (`#/ip4/…/tcp/…/p2p/<id>`
// after the plain host:port list). A vibe event loop on its own thread runs a
// small libp2p host (TCP transport, Noise, yamux — the "lite" build, no OpenSSL
// or c-ares), dials the computer, opens `/photowagon/ipc/1.0.0` and carries the
// JSON lines of docs/ipc.md as length-prefixed frames. The Qt side talks to that
// thread through an InProcessLink, exactly as the desktop UI talks to its core.
//
// A TcpBridge stays underneath for codes without libp2p addresses and for a
// host:port typed by hand; while the libp2p stream is up it has the floor.
module photowagon.mobile.p2pbridge;

import photowagon.mobile.plog : plog;

import core.sync.mutex : Mutex;
import core.time : msecs, seconds;
import std.file : exists, readText;
import std.json;
import std.path : buildPath;
import std.string : startsWith, strip;

import qt.quick.qsocketnotifier;
import qt.quick.qtimer;
import cppq = qt.quick.qobject;
import qtmoc;

import libp2p.core.peer_id : PeerId;
import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed;
import libp2p.host.host : Host, HostConfig;
import libp2p.multiformats.multiaddr : Multiaddr;
import libp2p.transport.tcp : TcpTransport;

import photowagon.core.ipc.link : InProcessLink;
import photowagon.core.pairingcode : parsePairingCode;
import photowagon.mobile.tcpbridge : TcpBridge;
import photowagon.ui.bridge : Pump;
import photowagon.ui.transport : Bridge, ResultCb;

enum ipcProtocol = "/photowagon/ipc/1.0.0";
enum maxLine = 64 * 1024 * 1024;

final class P2pBridge : Bridge
{
    private TcpBridge tcp;
    private InProcessLink link;
    private Pump pump;
    private QSocketNotifier notifier;
    private QTimer fallback;
    private string settingsDir;
    private string identityFile;
    private bool p2pUp;
    private string p2pWith;             // "<peer id>" while up

    private static struct Target
    {
        bool valid;
        string token;
        string[] addrs;                 // "/ip4/…/tcp/N/p2p/<id>"
        uint version_;                  // bumps on every change: a running session gives way
    }
    private Mutex lock;
    private Target target;              // under lock; read by the vibe thread

    this(string settingsDir)
    {
        this.settingsDir = settingsDir;
        identityFile = buildPath(settingsDir, "identity.seed");
        lock = new Mutex;
        link = new InProcessLink;
        tcp = new TcpBridge;
        tcp.onEvent = (string ev, JSONValue data) { if (!p2pUp && onEvent) onEvent(ev, data); };
        tcp.onConnected = (bool up) { if (!p2pUp && onConnected) onConnected(up); };
        tcp.onScanned = &adoptCode;
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
            fallback = new QTimer(cast(cppq.QObject) null);
            fallback.setInterval(20);
            fallback.connectTimeout(&drain);
            fallback.start();
        }
        // the saved pairing code, if it has libp2p addresses
        immutable saved = buildPath(settingsDir, "endpoint");
        if (saved.exists)
        {
            try
                adoptCode(readText(saved).strip());
            catch (Exception e)
                plog("p2p: saved endpoint unusable: ", e.msg);
        }
        import core.thread : Thread;
        auto t = new Thread(&loop);
        t.isDaemon = true;
        t.start();
        tcp.start();
    }

    override bool connected() const { return p2pUp || tcp.connected; }
    override bool remote() const { return true; }
    override string endpoint() const { return p2pUp ? "libp2p " ~ p2pWith[0 .. 12] ~ "…" : tcp.endpoint; }

    override void setEndpoint(string host, ushort port)
    {
        tcp.setEndpoint(host, port);
        if (host.startsWith("pw://"))
            adoptCode(host);
        else
            clearTarget();
    }

    /// A pairing code: the libp2p addresses, if it has any.
    private void adoptCode(string code)
    {
        try
        {
            auto info = parsePairingCode(code);
            if (info.p2p.length == 0)
            {
                clearTarget();
                return;
            }
            synchronized (lock)
            {
                target.valid = true;
                target.token = info.token;
                target.addrs = info.p2p.dup;
                target.version_++;
            }
            plog("p2p: will dial ", info.p2p);
        }
        catch (Exception e)
            plog("p2p: bad code: ", e.msg);
    }

    private void clearTarget()
    {
        synchronized (lock)
        {
            target.valid = false;
            target.version_++;
        }
    }

    override void request(string method, JSONValue params, ResultCb cb)
    {
        if (p2pUp)
            link.submit(enqueue(method, params, cb));
        else if (tcp.connected)
            tcp.request(method, params, cb);
        else
        {
            JSONValue e = ["code": JSONValue("no_computer"), "message": JSONValue("not connected to a computer")];
            cb(JSONValue(null), e);
        }
    }

    // ---- Qt thread: what the vibe thread delivered ------------------------------------

    private void drain()
    {
        foreach (line; link.takeOutbox())
        {
            JSONValue obj;
            try
                obj = parseJSON(line);
            catch (Exception)
                continue;
            if (obj.type == JSONType.object && "event" in obj && obj["event"].str == "p2p.link")
            {
                auto d = obj["data"];
                immutable up = d["up"].type == JSONType.true_;
                if (up == p2pUp && up)
                    continue;
                p2pUp = up;
                p2pWith = up ? d["peer"].str : null;
                if (!up)
                    failAll("libp2p link lost");
                plog("p2p: ", up ? "connected to " ~ p2pWith : "disconnected" ~ (d["error"].type == JSONType.string ? ": " ~ d["error"].str : ""));
                if (onConnected)
                    onConnected(connected);
                continue;
            }
            deliverLine(line);
        }
    }

    // ---- the vibe thread --------------------------------------------------------------

    private void loop()
    {
        import vibe.core.core : runTask, runEventLoop;

        runTask(() nothrow {
            try
                client();
            catch (Exception e)
            {
                try plog("p2p: thread died: ", e.msg); catch (Exception) {}
            }
        });
        runEventLoop();
    }

    private void client()
    {
        import vibe.core.core : sleep;
        import libp2p.host.host : Host, HostConfig;
        import libp2p.transport.tcp : TcpTransport;
        import photowagon.core.p2p.identity : loadOrCreateIdentity;

        auto identity = loadOrCreateIdentity(identityFile);
        HostConfig hc;
        hc.agentVersion = "photowagon-mobile/0.5.0";
        auto host = new Host(identity, [new TcpTransport], hc);
        plog("p2p: this phone is ", host.id.toString);
        for (;;)
        {
            Target t;
            synchronized (lock)
                t = target;
            if (!t.valid)
            {
                sleep(500.msecs);
                continue;
            }
            try
                session(host, t);
            catch (Exception e)
                deliverLink(false, null, e.msg);
            // give way immediately to a new code; otherwise retry in a while
            for (int i = 0; i < 6; i++)
            {
                bool changed;
                synchronized (lock)
                    changed = target.version_ != t.version_;
                if (changed)
                    break;
                sleep(500.msecs);
            }
        }
    }

    /// One connected stream: dial, authenticate, then pump lines both ways until it drops.
    private void session(Host host, Target t)
    {
        import vibe.core.core : runTask, sleep;
        import libp2p.core.peer_id : PeerId;
        import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed;
        import libp2p.host.host : Host;
        import libp2p.multiformats.multiaddr : Multiaddr;

        PeerId peer;
        Multiaddr[] addrs;
        bool havePeer;
        foreach (text; t.addrs)
        {
            auto full = Multiaddr.parse(text);
            Multiaddr addr;
            foreach (c; full.components)
            {
                if (c.name == "p2p")
                {
                    peer = PeerId.fromBytes(c.value);
                    havePeer = true;
                }
                else
                    addr = addr ~ Multiaddr.parse("/" ~ c.name ~ (c.protocol.size != 0 ? "/" ~ c.text : ""));
            }
            addrs ~= addr;
        }
        if (!havePeer)
            throw new Exception("code has no peer id");
        host.connect(peer, addrs);
        auto s = host.newStream(peer, ipcProtocol);
        scope (exit)
            s.close();
        JSONValue auth = ["id": JSONValue(0), "method": JSONValue("daemon.auth"), "params": JSONValue(["token": JSONValue(t.token)])];
        writeLengthPrefixed(s, cast(const(ubyte)[]) auth.toString());
        auto reply = parseJSON(cast(string) readLengthPrefixed(s, maxLine).idup);
        if (!("result" in reply))
            throw new Exception("not admitted: " ~ reply.toString());
        deliverLink(true, peer.toString, null);

        bool done;
        auto reader = runTask(() nothrow {
            try
            {
                for (;;)
                {
                    auto frame = readLengthPrefixed(s, maxLine);
                    link.deliver(cast(string) frame.idup);
                }
            }
            catch (Exception) {}
            done = true;
            try link.submit(""); catch (Exception) {}   // wake the writer so it notices
        });
        cast(void) reader;
        int seen = link.emitCount;
        while (!done)
        {
            foreach (line; link.takeInbox())
                if (line.length && !done)
                    writeLengthPrefixed(s, cast(const(ubyte)[]) line);
            uint v;
            synchronized (lock)
                v = target.version_;
            if (v != t.version_)
                break;                                    // a new code: drop this session
            seen = link.waitForInput(seen);
        }
        deliverLink(false, null, "connection closed");
    }

    private void deliverLink(bool up, string peer, string error)
    {
        JSONValue d = ["up": JSONValue(up)];
        d["peer"] = peer.length ? JSONValue(peer) : JSONValue(null);
        d["error"] = error.length ? JSONValue(error) : JSONValue(null);
        link.deliver(JSONValue(["event": JSONValue("p2p.link"), "data": d]).toString());
    }
}
