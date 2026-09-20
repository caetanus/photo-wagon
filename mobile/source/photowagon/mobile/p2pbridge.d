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

import photowagon.mobile.plog : plog, useCrashStack;

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
import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed, readExact;
import libp2p.host.host : Host, HostConfig;
import libp2p.multiformats.multiaddr : Multiaddr;
import libp2p.transport.tcp : TcpTransport;
import libp2p.protocol.relay.service : Relay;

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
    private string pairCode;            // the 4-digit code for the current pairing; stable across dial retries
    private static struct PushJob { long ticket; string path; }
    private PushJob[] pushJobs;          // under lock: files queued to push on the blob pipe
    private ResultCb[long] pushCbs;      // Qt thread only: ticket -> callback for a push

    this(string settingsDir)
    {
        this.settingsDir = settingsDir;
        identityFile = buildPath(settingsDir, "identity.seed");
        lock = new Mutex;
        link = new InProcessLink(false);   // the session polls; no vibe event from the Qt thread
        tcp = new TcpBridge;
        tcp.onEvent = (string ev, JSONValue data) { if (!p2pUp && onEvent) onEvent(ev, data); };
        tcp.onConnected = (bool up) { if (!p2pUp && onConnected) onConnected(up); };
        tcp.onScanned = (string c) { adoptCode(c); };
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
        // the last pairing code with libp2p addresses (TcpBridge's "endpoint" file keeps
        // only the host:port part of a code, so we keep our own copy)
        immutable saved = buildPath(settingsDir, "p2p-code");
        if (saved.exists)
        {
            try
                adoptCode(readText(saved).strip(), false);
            catch (Exception e)
                plog("p2p: saved code unusable: ", e.msg);
        }
        // extra addresses learned in earlier sessions (e.g. the computer's public address,
        // for dialing in over 4G) — merged onto whatever the saved pairing code carried
        try
        {
            import std.string : splitLines, strip;
            import std.algorithm : canFind;

            immutable extra = buildPath(settingsDir, "p2p-addrs");
            if (extra.exists)
                foreach (ln; readText(extra).splitLines)
                {
                    auto a = ln.strip;
                    if (a.length)
                        synchronized (lock)
                            if (target.valid && !target.addrs.canFind(a))
                                target.addrs ~= a;
                }
        }
        catch (Exception e)
            plog("p2p: extra addrs unusable: ", e.msg);
        import core.thread : Thread;
        auto t = new Thread(&loop);
        t.name = "libp2p";
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
    private void adoptCode(string code, bool save = true)
    {
        try
        {
            auto info = parsePairingCode(code);
            if (info.p2p.length == 0)
            {
                clearTarget();
                return;
            }
            if (save)
            {
                import std.file : write, mkdirRecurse;
                mkdirRecurse(settingsDir);
                write(buildPath(settingsDir, "p2p-code"), code);
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

    /// Add addresses the computer reported (from p2p.status) to the dial list and persist
    /// them, so a later reconnect — including off the LAN, over 4G — has every route to try.
    private void mergeLearnedAddrs(string[] fresh)
    {
        import std.algorithm : canFind;
        import std.array : join;

        string[] all;
        bool added;
        synchronized (lock)
        {
            if (!target.valid)
                return;
            foreach (a; fresh)
                if (a.length && !target.addrs.canFind(a))
                {
                    target.addrs ~= a;
                    added = true;
                }
            all = target.addrs.dup;
        }
        if (!added)
            return;
        plog("p2p: address list now ", all);
        try
        {
            import std.file : write, mkdirRecurse;

            mkdirRecurse(settingsDir);
            write(buildPath(settingsDir, "p2p-addrs"), all.join("\n"));
        }
        catch (Exception e)
            plog("p2p: cannot save addrs: ", e.msg);
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

    override void requestRaw(string method, string paramsJson, ResultCb cb)
    {
        if (p2pUp)
            link.submit(enqueueRaw(method, paramsJson, cb));
        else if (tcp.connected)
            tcp.requestRaw(method, paramsJson, cb);
        else
        {
            JSONValue e = ["code": JSONValue("no_computer"), "message": JSONValue("not connected to a computer")];
            cb(JSONValue(null), e);
        }
    }

    override bool canPush() const
    {
        return p2pUp;
    }

    /// Streams the file's raw bytes on the blob pipe, then sends library.import{ticket,...}.
    override void uploadFile(long ticket, string path, JSONValue meta, ResultCb cb)
    {
        pushFile(ticket, path, (JSONValue pr, JSONValue perr) {
            if (perr.type != JSONType.null_)
            {
                cb(JSONValue(null), perr);
                return;
            }
            auto p = meta;
            p["ticket"] = JSONValue(ticket);
            request("library.import", p, cb);
        });
    }

    /// Queues `path` to be streamed on the blob pipe under `ticket`; the vibe loop does it.
    private void pushFile(long ticket, string path, ResultCb cb)
    {
        if (!p2pUp)
        {
            cb(JSONValue(null), JSONValue([
                "code": JSONValue("no_computer"), "message": JSONValue("no libp2p link")
            ]));
            return;
        }
        pushCbs[ticket] = cb;
        synchronized (lock)
            pushJobs ~= PushJob(ticket, path);
    }

    /// A request timed out: the libp2p session is dropped (the loop dials the same
    /// code again) and the TCP link too; whatever was pending is answered with an error.
    override void reconnect()
    {
        if (p2pUp)
        {
            plog("p2p: reconnecting after a timeout");
            synchronized (lock)
                target.version_++;          // the session sees a new version and ends
            p2pUp = false;
            failAll("libp2p link reset after a timeout");
        }
        tcp.reconnect();
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
            if (obj.type == JSONType.object && "pushDone" in obj)
            {
                immutable ticket = obj["pushDone"].integer;
                if (auto cbp = ticket in pushCbs)
                {
                    auto cb = *cbp;
                    pushCbs.remove(ticket);
                    if ("ok" in obj && obj["ok"].type == JSONType.true_)
                        cb(JSONValue(["ok": JSONValue(true)]), JSONValue(null));
                    else
                        cb(JSONValue(null), JSONValue([
                            "code": JSONValue("push_failed"),
                            "message": ("error" in obj && obj["error"].type == JSONType.string)
                                ? obj["error"] : JSONValue("push failed"),
                        ]));
                }
                continue;
            }
            deliverLine(line);
        }
    }

    // ---- the vibe thread --------------------------------------------------------------

    private void loop()
    {
        import vibe.core.core : runTask, runEventLoop;

        useCrashStack();
        {   // vibe's own diagnostics (the exit reason of the loop, for one) → stderr → logcat.
            // info, not debug: debug logs every frame's worth of fiber chatter, a real drag on
            // a phone under sync. PW_QT_DEBUG turns the firehose back on for diagnosis.
            import vibe.core.log : setLogLevel, LogLevel;
            import std.process : environment;

            setLogLevel("PW_QT_DEBUG" in environment ? LogLevel.debug_ : LogLevel.info);
        }
        // If vibe's event loop ever returns or throws (it did on Android, with "May not
        // process events within an active yieldLock()" — a per-thread counter left
        // behind, which the same thread cannot shake off), say so and hand the job to a
        // fresh thread. This one parks for good: ending it runs vibe's thread
        // destructors over the dead tasks, which crashed.
        plog("p2p: thread starting");
        import photowagon.mobile.plog : installQuitHandler;
        runTask(() nothrow {
            installQuitHandler();   // after vibe's runEventLoop installed its own (below)
            try
                client();
            catch (Exception e)
            {
                try plog("p2p: client task died: ", e.msg); catch (Exception) {}
            }
        });
        try
            runEventLoop();
        catch (Throwable e)   // an Error too: a thread dies silently on one, the runtime tells nobody
            plog("p2p: event loop threw: ", e.toString());
        plog("p2p: event loop exited; a new thread takes over");
        deliverLink(false, null, "event loop exited");
        import core.thread : Thread;
        Thread.sleep(2.seconds);
        auto next = new Thread(&loop);
        next.name = "libp2p";
        next.isDaemon = true;
        next.start();
        for (;;)
            Thread.sleep(3600.seconds);
    }

    private void client()
    {
        import vibe.core.core : sleep;
        import libp2p.host.host : Host, HostConfig;
        import libp2p.transport.tcp : TcpTransport;
        import libp2p.transport.ws : WsTransport;
        import libp2p.transport.transport : Transport;
        version (LibP2P_OpensslTls) import libp2p.transport.ws_tls_openssl : OpensslTlsProvider;
        import photowagon.core.p2p.identity : loadOrCreateIdentity;

        auto identity = loadOrCreateIdentity(identityFile);
        HostConfig hc;
        hc.agentVersion = "photowagon-mobile/0.5.0";
        // Off-LAN (4G) the computer's two direct addresses are both dead ends — the LAN
        // address has no route and the public one is behind CGNAT and cannot accept an
        // inbound SYN — so each one otherwise burns the full 10 s dial timeout before the
        // relay path is even tried (~16 s to connect). A reachable relay answers in well
        // under a second, so a shorter dial timeout only cuts the dead direct dials.
        hc.swarm.dialTimeout = 5.seconds;
        // WebSocket transport: the public libp2p relays are WSS-only (/dns4/.../tls/ws), so the
        // phone needs /tls/ws to even reach them off-LAN. Plain /ws until openssl is linked; the
        // TLS provider lights up under -version=LibP2P_OpensslTls (see mobile/build-android.sh).
        version (LibP2P_OpensslTls)
            auto ws = new WsTransport(new OpensslTlsProvider());
        else
            auto ws = new WsTransport();
        Transport[] transports = [cast(Transport) new TcpTransport, ws];   // cast: else the literal infers Object[]
        auto host = new Host(identity, transports, hc);
        // NAT-traversal (relay transport + DCUtR) is ON here too. The stall this once caused was
        // the in-process UI link race on the desktop (now fixed); the relay transport lets the
        // phone reach the computer over a /p2p-circuit off-LAN, and DCUtR then tries for a direct
        // upgrade. Direct LAN sync works without any of it.
        import libp2p.protocol.relay.service : Relay;

        enum bool natTraversal = true;
        Relay relay = null;
        if (natTraversal)
        {
            relay = new Relay(host);
            // session() drives the punch explicitly on a relayed connection, so turn off the
            // library's auto-DCUtR: otherwise both fire on the same circuit and each spawns a
            // dial storm to the computer's addresses — needless churn on the relay path.
            relay.autoHolePunch = false;
            host.swarm.addTransport(relay);
        }
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
                session(host, relay, t);
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

    /// The 4-digit code shown on this phone and typed at the desktop to authorize it.
    private static string fourDigitCode()
    {
        import std.random : uniform;
        import std.format : format;

        return format("%04d", uniform(0, 10_000));
    }

    /// A friendly default name the desktop shows for this phone (the user can rename it).
    private static string deviceName()
    {
        import std.process : environment;
        import std.socket : Socket;

        auto n = environment.get("PW_DEVICE_NAME", "");
        if (n.length)
            return n;
        try
            return Socket.hostName();
        catch (Exception)
            return "Phone";
    }

    /// True when the multiaddr's /ip4 host is an RFC 1918 address (a LAN route).
    private static bool isPrivateIp4(string text)
    {
        import std.algorithm : findSplitAfter, startsWith;
        import std.string : indexOf;
        import std.conv : to;

        auto rest = text.findSplitAfter("/ip4/")[1];
        if (rest.length == 0)
            return false;
        immutable end = rest.indexOf('/');
        immutable host = end < 0 ? rest : rest[0 .. end];
        if (host.startsWith("10.") || host.startsWith("192.168."))
            return true;
        if (host.startsWith("172."))
        {
            auto p = host[4 .. $];
            immutable dot = p.indexOf('.');
            if (dot > 0)
                try
                {
                    immutable n = p[0 .. dot].to!int;
                    return n >= 16 && n <= 31;
                }
                catch (Exception)
                {
                }
        }
        return false;
    }

    /// One connected stream: dial, authenticate, then pump lines both ways until it drops.
    private void session(Host host, Relay relay, Target t)
    {
        import vibe.core.core : runTask, sleep;
        import libp2p.core.peer_id : PeerId;
        import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed, readExact;
        import libp2p.host.host : Host;
        import libp2p.multiformats.multiaddr : Multiaddr;
        import libp2p.protocol.relay.service : Relay;

        import std.algorithm : canFind;

        PeerId peer;
        Multiaddr[] lan, circuit, other;
        bool havePeer;
        foreach (text; t.addrs)
        {
            if (text.canFind("/ip4/0.0.0.0/") || text.canFind("/ip4/127."))
                continue; // a wildcard or loopback listen address is not a route to the computer
            auto full = Multiaddr.parse(text);
            auto comps = full.components;
            // The trailing /p2p/<id> names the computer. The address itself goes to the
            // swarm whole: it strips that trailer from a plain address, and keeps a relayed
            // one intact because the relay transport needs the relay's own /p2p/<id> too.
            // (Stripping every /p2p here turned the circuit into "/ip4/…/tcp/4001/p2p-circuit",
            // which the relay refused with "address does not name its relay": off the LAN,
            // the phone never had a valid route.)
            if (comps.length && comps[$ - 1].name == "p2p")
            {
                peer = PeerId.fromBytes(comps[$ - 1].value);
                havePeer = true;
            }
            // This build dials over TCP (and, with the TLS provider, /ws) and has no DNS
            // resolver: addresses that need DNS, QUIC or WebRTC are undialable here. Most of
            // the computer's advertised relays are /dns4/.../tls/ws (and some quic/webrtc), so
            // without this the phone spends a full dial timeout on each dead relay before it
            // reaches a usable /ip4/.../tcp one — ~16 s to connect on 4G. Keep only what we
            // can actually reach, and the reachable ip4 relay is tried first.
            if (text.canFind("/dns") || text.canFind("/quic") || text.canFind("/webrtc"))
                continue;
            if (comps.canFind!(c => c.name == "p2p-circuit"))
                circuit ~= full;
            else if (isPrivateIp4(text))
                lan ~= full;
            else
                other ~= full;
        }
        if (!havePeer)
            throw new Exception("code has no peer id");
        // Dialed in this order, and a dead address costs the full dial timeout: the LAN
        // first (instant when we are on it), then the relay circuit (reachable from
        // anywhere), and last the computer's public address — under CGNAT it never
        // answers and would only burn the timeout ahead of the circuit.
        auto addrs = lan ~ circuit ~ other;
        auto conn = host.connect(peer, addrs);
        // Which route won — a direct /ip4/.../tcp or a /p2p-circuit relay. On the same LAN this
        // must be the direct LAN address; a relay here means the direct route was missing or lost
        // and the link then inherits the relay's short circuit budget.
        if (conn !is null)
            plog("p2p: connected via ", conn.remoteAddr.toString);
        // If we reached the computer through a relay (a /p2p-circuit address, the 4G case),
        // punch a direct connection with DCUtR so the photos flow peer-to-peer, not through
        // the relay. Best-effort: if the NAT will not cooperate we simply stay on the relay.
        import std.algorithm : canFind;

        if (relay !is null && conn !is null && conn.remoteAddr.toString.canFind("p2p-circuit"))
            runTask(() nothrow {
                try
                {
                    relay.holePunch(peer);
                    plog("p2p: hole-punched a direct connection to the computer");
                }
                catch (Exception e)
                {
                    try plog("p2p: hole punch failed (staying on the relay): ", e.msg); catch (Exception) {}
                }
            });
        auto s = host.newStream(peer, ipcProtocol);
        scope (exit)
            s.close();
        JSONValue auth = ["id": JSONValue(0), "method": JSONValue("daemon.auth"),
            "params": JSONValue(["token": JSONValue(t.token), "name": JSONValue(deviceName())])];
        writeLengthPrefixed(s, cast(const(ubyte)[]) auth.toString());
        // The core sends events on this same stream (it attaches the event sink at once), so a
        // handshake reply can be preceded by an event frame — read past events to the response.
        JSONValue readResponse()
        {
            for (;;)
            {
                auto frame = cast(string) readLengthPrefixed(s, maxLine).idup;
                auto j = parseJSON(frame);
                if (j.type == JSONType.object && "event" in j.object)
                {
                    link.deliver(frame);   // hand the event to the UI, keep waiting for the reply
                    continue;
                }
                return j;
            }
        }
        auto reply = readResponse();
        if (!("result" in reply))
            throw new Exception("not admitted: " ~ reply.toString());
        // A device the desktop has never seen must be authorized there: we show a 4-digit
        // code and the person at the computer types it. The connection is held (this read
        // blocks) until they confirm — or the computer drops us.
        if ("needsPairing" in reply["result"] && reply["result"]["needsPairing"].type == JSONType.true_)
        {
            if (pairCode.length == 0)
                pairCode = fourDigitCode();
            immutable code = pairCode;   // stable across dial retries, so the operator sees one code
            plog("p2p: pairing code ", code, " — enter it on the computer to allow this phone");
            // tell the phone UI to show the code (drain() surfaces this as an event)
            link.deliver(JSONValue(["event": JSONValue("pairing.code"),
                "data": JSONValue(["code": JSONValue(code)])]).toString());
            JSONValue pair = ["id": JSONValue(1), "method": JSONValue("daemon.pair"),
                "params": JSONValue(["code": JSONValue(code), "name": JSONValue(deviceName())])];
            writeLengthPrefixed(s, cast(const(ubyte)[]) pair.toString());
            auto preply = readResponse();   // skips the pairing.request event the core broadcasts
            link.deliver(JSONValue(["event": JSONValue("pairing.code"),
                "data": JSONValue(["done": JSONValue(true)])]).toString());
            if (!("result" in preply))
                throw new Exception("pairing was not confirmed on the computer");
            pairCode = null;   // paired: a later re-pairing will make a fresh code
        }
        deliverLink(true, peer.toString, null);

        // Ask the computer for its full address list and remember any new ones (its public
        // address in particular): a later dial off the LAN — on 4G — then has a route to try,
        // without re-pairing. Done here, before the reader task below, so the reply is ours.
        try
        {
            JSONValue statusReq = ["id": JSONValue(2), "method": JSONValue("p2p.status"),
                "params": JSONValue.emptyObject];
            writeLengthPrefixed(s, cast(const(ubyte)[]) statusReq.toString());
            auto sres = readResponse();
            if ("result" in sres && sres["result"].type == JSONType.object && "addrs" in sres["result"])
            {
                string[] fresh;
                foreach (a; sres["result"]["addrs"].array)
                    if (a.type == JSONType.string)
                        fresh ~= a.str;
                mergeLearnedAddrs(fresh);
            }
        }
        catch (Exception e)
            plog("p2p: address refresh failed: ", e.msg);

        // Liveness: when Wi-Fi drops mid-session the socket does not fail for a long
        // time, so reads block and writes buffer while `p2pUp` stays true and every
        // request piles into a dead link until the 45 s sync deadline. A keepalive
        // fixes that: `lastRecv` is bumped on any frame the reader sees; a `daemon.hello`
        // goes out every `pingEvery`; and if nothing has come back for `deadAfter`
        // (a couple of missed pings) the session is declared dead and dropped, so the
        // outer loop re-dials in seconds rather than after three quarters of a minute.
        import core.time : MonoTime, seconds, msecs;

        bool done;
        auto lastRecv = MonoTime.currTime;
        auto reader = runTask(() nothrow {
            try
            {
                for (;;)
                {
                    auto frame = readLengthPrefixed(s, maxLine);
                    lastRecv = MonoTime.currTime;
                    link.deliver(cast(string) frame.idup);
                }
            }
            catch (Exception) {}
            done = true;
        });
        cast(void) reader;
        const(ubyte)[] ping = cast(const(ubyte)[]) JSONValue(["id": JSONValue(-1),
            "method": JSONValue("daemon.hello"), "params": JSONValue.emptyObject]).toString();
        enum pingEvery = 3.seconds;
        enum deadAfter = 9.seconds;
        auto lastPing = MonoTime.currTime;
        // Polling rather than the link's shared ManualEvent: on Android vibe's
        // per-thread event for it comes back invalid (an assertion in
        // threadlocalwaiter.d), and 20 ms of latency on a phone is nothing.
        while (!done)
        {
            foreach (line; link.takeInbox())
                if (line.length && !done)
                    writeLengthPrefixed(s, cast(const(ubyte)[]) line);
            // blob pipe: stream queued files' raw bytes on their own stream, beside this
            // loop, so a 31 MB video never blocks the keepalive here
            PushJob[] jobs;
            synchronized (lock)
            {
                jobs = pushJobs;
                pushJobs = null;
            }
            foreach (job; jobs)
            {
                immutable jt = job.ticket;
                immutable jp = job.path;
                runTask(() nothrow {
                    string err;
                    try
                        pushOne(host, peer, jt, jp);
                    catch (Exception e)
                        err = e.msg.length ? e.msg : "push failed";
                    try
                        link.deliver(JSONValue([
                            "pushDone": JSONValue(jt),
                            "ok": JSONValue(err.length == 0),
                            "error": err.length ? JSONValue(err) : JSONValue(null),
                        ]).toString());
                    catch (Exception)
                    {
                    }
                });
            }
            immutable now = MonoTime.currTime;
            if (now - lastPing >= pingEvery)
            {
                lastPing = now;
                try
                    writeLengthPrefixed(s, ping);
                catch (Exception)
                    break;                                // the write side is gone
            }
            if (now - lastRecv >= deadAfter)
            {
                plog("p2p: link silent for ", deadAfter.total!"seconds", "s — dropping to re-dial");
                break;                                    // no answer to the pings: the link is dead
            }
            uint v;
            synchronized (lock)
                v = target.version_;
            if (v != t.version_)
                break;                                    // a new code: drop this session
            sleep(20.msecs);
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

private enum pushProtocol = "/photowagon/push/1.0.0";

private ubyte[8] longToBe8(long v) @safe @nogc nothrow pure
{
    ubyte[8] b;
    foreach_reverse (i; 0 .. 8)
    {
        b[i] = cast(ubyte)(v & 0xff);
        v >>= 8;
    }
    return b;
}

/// Streams one file's raw bytes to `peer` on the blob pipe: (long ticket)(long size)(bytes),
/// then waits for the one-byte ack. vibe async file I/O, so the fiber yields and the session's
/// keepalive keeps ticking.
private void pushOne(Host host, PeerId peer, long ticket, string path)
{
    import vibe.core.file : openFile, FileMode;

    auto st = host.newStream(peer, pushProtocol);
    scope (exit)
        st.close();
    auto fh = openFile(path, FileMode.read);
    scope (exit)
        fh.close();
    immutable size = fh.size;
    ubyte[8] tb = longToBe8(ticket);
    st.write(tb[]);
    ubyte[8] sb = longToBe8(cast(long) size);
    st.write(sb[]);
    ubyte[64 * 1024] buf;
    ulong remaining = size;
    while (remaining > 0)
    {
        immutable n = cast(size_t)(remaining < buf.length ? remaining : buf.length);
        fh.read(buf[0 .. n]);
        st.write(buf[0 .. n]);
        remaining -= n;
    }
    ubyte[1] ack;
    readExact(st, ack[]);
}
