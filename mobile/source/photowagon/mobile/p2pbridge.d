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
import std.path : buildPath, baseName, dirName;
import std.string : startsWith, strip;

import qt.quick.qsocketnotifier;
import qt.quick.qtimer;
import cppq = qt.quick.qobject;
import qtmoc;

import libp2p.core.peer_id : PeerId;
import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed, readExact;
import libp2p.host.host : Host, HostConfig, Connection, Notifiee;
import libp2p.multiformats.multiaddr : Multiaddr;
import libp2p.transport.tcp : TcpTransport;
import libp2p.protocol.relay.service : Relay;
import libp2p.protocol.kad.kad : Kademlia, KademliaConfig, PeerInfo;
version (Libp2pQuic) import libp2p.transport.quic.transport : QuicTransport;

import photowagon.core.ipc.link : InProcessLink;
import photowagon.core.sync.pieces : PieceStore, PieceService, Manifest, Bitfield, manifestOf, askInfo, askHave,
    askPiece, tellManifest, givePiece, askThumbs, pieceProtocol, pieceSize;
version (PwHyperswarm)
{
    import photowagon.core.p2p.hswarm : HsTransport;
    import photowagon.core.sync.muxstream : MuxSession, MuxStream, muxTagControl, muxTagPiece;
    import hyperswarm.connection : HsConn = Connection;
}
import photowagon.core.pairingcode : parsePairingCode;
import libp2p.discovery.mdns : MdnsRendezvous, MdnsRendezvousConfig;
import libp2p.discovery.rendezvous : meetUnder, rendezvousKeyFor;
import libp2p.core.peer_id : PeerId;
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
    private Kademlia kad;               // vibe thread only: the DHT client that finds the computer's current addresses
    private static struct LpSess { Connection conn; int rank; bool linked; }
    private LpSess[string] lpSessions; // vibe thread: peer base58 → the connection its session runs on + rank (LAN preempts WAN)
    version (PwHyperswarm)
    {
        private static struct HsSess { HsConn conn; int rank; }
        private HsSess[string] hsSessions;   // peer hex → the connection its session runs on + rank (LAN preempts WAN)
    }
    private bool meeting;                // vibe thread: a meetUnder (WAN driver) attempt is in flight
    private MdnsRendezvous lanRv;        // vibe thread: the LAN rendezvous (browse) for the current token
    private string lanRvToken;           // the token lanRv was started for
    private string[] dhtSeeds;          // vibe thread only: DHT peers the computer was connected to (Ed25519, ip4) — our way in
    private static struct PushJob { long ticket; string path; string sha; long offset; }   // sha empty = whole-blob v1
    private PushJob[] pushJobs;          // under lock: files queued to push on the blob pipe
    private ResultCb[long] pushCbs;      // Qt thread only: ticket -> callback for a push
    private static struct PullJob { long ticket; long id; string dest; string sha; }   // sha set = piece protocol
    private PieceStore pieces;           // vibe thread: files arriving from the computer, piece by piece
    private PieceService pieceService;   // what we serve: our own files by sha256 (the camera roll), and the store
    private PullJob[] pullJobs;          // under lock: originals queued to download on the pull pipe
    // thumbnails for the grid: raw JPEG bytes on a piece stream (THUMB op), not base64 in JSON
    private static struct ThumbJob { long[] ids; void delegate(long, const(ubyte)[]) onThumb; void delegate() done; }
    private ThumbJob[] thumbJobs;        // under lock
    private ResultCb[long] pullCbs;      // Qt thread only: ticket -> callback for a download
    private long nextPull = 1;
    private uint joinedVersion;   // hyperswarm flavor: the target version this session serves

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
        // DHT seeds learned from the computer's peer list (see rememberSeeds): the phone's
        // way into the public DHT when it has to look the computer up
        try
        {
            import std.string : splitLines, strip;

            immutable sf = buildPath(settingsDir, "dht-seeds");
            if (sf.exists)
                foreach (ln; readText(sf).splitLines)
                    if (ln.strip.length)
                        dhtSeeds ~= ln.strip;
        }
        catch (Exception e)
            plog("p2p: dht seeds unusable: ", e.msg);
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
            // parsePairingCode guarantees a token. A token is a valid p2p target on its
            // own: the hyperswarm flavor derives the topic from it, and the libp2p flavor
            // finds the computer via the DHT rendezvous from it — so a token-only code (no
            // address, the current QR) engages p2p. Any p2p multiaddrs only seed the first
            // dial; the TcpBridge separately handles info.hosts for the legacy direct path.
            if (info.token.length == 0)
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
                if (info.p2p.length)
                    target.addrs = info.p2p.dup;   // a legacy code with addresses seeds the dial
                // else: a token-only code (the current QR) keeps the addresses learned before —
                // the preferential list (the computer's /p2p-circuit) must survive a re-adopt.
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

    /// Add addresses the computer reported (p2p.status) or the DHT returned to the dial list
    /// and persist them, so a later reconnect — including off the LAN, over 4G — has every
    /// route to try. `authoritative` = the list is the computer's CURRENT one: relay circuits
    /// we hold that are not in it point at relays it has left, and each dead circuit costs a
    /// full dial timeout on the next connect, so they are dropped.
    private void mergeLearnedAddrs(string[] fresh, bool authoritative = false)
    {
        import std.algorithm : canFind, remove;
        import std.array : join;

        string[] all;
        bool changed;
        synchronized (lock)
        {
            if (!target.valid)
                return;
            if (authoritative)
            {
                immutable before = target.addrs.length;
                target.addrs = target.addrs.remove!(a => a.canFind("/p2p-circuit") && !fresh.canFind(a));
                changed = target.addrs.length != before;
            }
            foreach (a; fresh)
                if (a.length && !target.addrs.canFind(a))
                {
                    target.addrs ~= a;
                    changed = true;
                }
            all = target.addrs.dup;
        }
        if (!changed)
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

    override bool canPull() const { return p2pUp; }

    /// Downloads the original of the computer's photo `id` into `dest`, resumably: the
    /// bytes land in `dest.part` as they arrive, a retry asks the computer to continue from
    /// its size, and the file is renamed into place once its sha256 checks out.
    /// Thumbnails as raw bytes over the piece stream — the pump drains the job on its
    /// next tick, on either flavor. Callbacks fire on the p2p thread, like request replies.
    override void fetchThumbs(long[] ids, void delegate(long, const(ubyte)[]) onThumb, void delegate() done)
    {
        if (ids.length == 0)
        {
            if (done !is null) done();
            return;
        }
        // p2p up: raw bytes on a piece stream (THUMB op), drained by the pump. Otherwise
        // mirror request()'s fallback — the TCP bridge's base-class JSON library.thumbs.
        if (p2pUp)
            synchronized (lock) thumbJobs ~= ThumbJob(ids.dup, onThumb, done);
        else if (tcp.connected)
            tcp.fetchThumbs(ids, onThumb, done);
        else if (done !is null)
            done();
    }

    override void downloadFile(long id, string dest, ResultCb cb) { downloadFile(id, dest, "", cb); }

    /// With the file's sha256 known (photo.get gives it) the piece protocol is used: pieces
    /// verified one by one, resumable from the piece store, from any peer that has them.
    void downloadFile(long id, string dest, string sha, ResultCb cb)
    {
        if (!p2pUp)
        {
            cb(JSONValue(null), JSONValue([
                "code": JSONValue("no_computer"), "message": JSONValue("no p2p link")
            ]));
            return;
        }
        enum maxAttempts = 4;
        immutable ticket = nextPull++;
        void attempt(int n)
        {
            pullCbs[ticket] = (JSONValue r, JSONValue perr) {
                if (perr.type != JSONType.null_ && n < maxAttempts && p2pUp
                    && perr.type == JSONType.object && "retry" in perr && perr["retry"].type == JSONType.true_)
                {
                    plog("pull: ", dest.baseName, " interrupted (", perr["message"].str, ") — resuming");
                    attempt(n + 1);
                    return;
                }
                cb(r, perr);
            };
            synchronized (lock)
                pullJobs ~= PullJob(ticket, id, dest, sha.length == 64 ? sha : "");
        }
        attempt(1);
    }

    /// Sends one file to the computer, resumably. `meta` = {name, takenAt, mtimeMs, sha256}.
    ///   1. probe:  library.import {name, sha256, probe} → already there (done), or `have` =
    ///              how many bytes of it the computer already spooled;
    ///   2. push:   the bytes from `have` on the resumable pipe (push/2.0.0, its own stream
    ///              on the direct connection; each slice lands on the computer's disk);
    ///   3. claim:  library.import {complete, sha256, …} → the computer verifies the hash
    ///              and files it.
    /// A drop anywhere retries from step 1 — so a 40 MB video that died at 30 MB sends the
    /// last 10, not the whole thing again — up to `maxAttempts` while the link is up. Without
    /// a sha256 in `meta` the old whole-blob pipe (v1 + ticket) is used.
    override void uploadFile(long ticket, string path, JSONValue meta, ResultCb cb)
    {
        if (!p2pUp)
        {
            cb(JSONValue(null), JSONValue([
                "code": JSONValue("no_computer"), "message": JSONValue("no p2p link")
            ]));
            return;
        }
        immutable sha = meta.type == JSONType.object && "sha256" in meta && meta["sha256"].type == JSONType.string
            ? meta["sha256"].str : "";
        if (sha.length != 64)
        {
            pushCbs[ticket] = (JSONValue _, JSONValue perr) {
                if (perr.type != JSONType.null_)
                {
                    cb(JSONValue(null), perr);
                    return;
                }
                auto p = meta;
                p["ticket"] = JSONValue(ticket);
                request("library.import", p, cb);
            };
            synchronized (lock)
                pushJobs ~= PushJob(ticket, path);
            return;
        }
        enum maxAttempts = 4;
        void attempt(int n)
        {
            JSONValue probe = ["name": meta["name"], "sha256": JSONValue(sha), "probe": JSONValue(true)];
            request("library.import", probe, (JSONValue r, JSONValue e) {
                if (e.type != JSONType.null_)
                {
                    cb(JSONValue(null), e);
                    return;
                }
                if (r.type == JSONType.object && "existed" in r && r["existed"].type == JSONType.true_)
                {
                    cb(r, JSONValue(null));   // the computer has it (this file, or an earlier copy)
                    return;
                }
                immutable have = r.type == JSONType.object && "have" in r && r["have"].type == JSONType.integer ? r["have"].integer : 0;
                // a computer that speaks pieces says so in the probe; pieces win (any order, any
                // source), the offset pipe stays for older computers
                immutable piecesOk = r.type == JSONType.object && "pieces" in r;
                if (have > 0 && !piecesOk)
                    plog("push: resuming ", path.baseName, " from ", have, " bytes (attempt ", n, ")");
                pushCbs[ticket] = (JSONValue _, JSONValue perr) {
                    if (perr.type != JSONType.null_)
                    {
                        if (n < maxAttempts && p2pUp)
                        {
                            plog("push: ", path.baseName, " interrupted (", perr["message"].str, ") — retrying");
                            attempt(n + 1);   // re-probe: the computer says where to resume
                        }
                        else
                            cb(JSONValue(null), perr);
                        return;
                    }
                    auto p = meta;
                    p["complete"] = JSONValue(true);
                    request("library.import", p, cb);
                };
                synchronized (lock)
                    pushJobs ~= PushJob(ticket, path, sha, piecesOk ? -1 : have);   // -1 = piece protocol
            });
        }
        attempt(1);
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
                tcp.standby = up;   // the plain-TCP fallback stops redialing while p2p has the floor
                if (!up)
                    failAll("libp2p link lost");
                plog("p2p: ", up ? "connected to " ~ p2pWith : "disconnected" ~ (d["error"].type == JSONType.string ? ": " ~ d["error"].str : ""));
                if (onConnected)
                    onConnected(connected);
                continue;
            }
            if (obj.type == JSONType.object && "pullDone" in obj)
            {
                immutable ticket = obj["pullDone"].integer;
                if (auto cbp = ticket in pullCbs)
                {
                    auto cb = *cbp;
                    pullCbs.remove(ticket);
                    if ("ok" in obj && obj["ok"].type == JSONType.true_)
                        cb(JSONValue(["path": obj["path"], "size": obj["size"]]), JSONValue(null));
                    else
                        cb(JSONValue(null), JSONValue([
                            "code": JSONValue("pull_failed"),
                            "message": ("error" in obj && obj["error"].type == JSONType.string) ? obj["error"] : JSONValue("download failed"),
                            "retry": JSONValue("retry" in obj && obj["retry"].type == JSONType.true_),
                        ]));
                }
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
        {
            import photowagon.mobile.plog : pinThreadTls;
            pinThreadTls("libp2p thread");   // Android: the GC does not scan our TLS by itself
        }
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
        import vibe.core.core : sleep, runTask;
        version (PwHyperswarm)
        {
            import std.process : environment;
            import std.file : exists;
            // hyperswarm flavor selected by PW_HS=1 (desktop/tests), the settings file
            // files/settings/hs-flavor (real phone toggle), or compiled as the default
            // (-d-version=PwHsDefault) for the no-root Waydroid rig, where neither env
            // injection nor run-as writes to app-private storage reach the app.
            version (PwHsDefault) enum bool hsDefault = true; else enum bool hsDefault = false;
            immutable bool wantQuic = environment.get("PW_QUIC", "") == "1";
            if (!wantQuic && (hsDefault
                    || environment.get("PW_HS", "") == "1"
                    || buildPath(settingsDir, "hs-flavor").exists))
            {
                plog("p2p: udx/hyperdht/hyperswarm flavor selected");
                hsClient();
                return;
            }
        }
        import libp2p.transport.ws : WsTransport;
        import libp2p.transport.transport : Transport;
        version (LibP2P_OpensslTls) import libp2p.transport.ws_tls_openssl : OpensslTlsProvider;
        import photowagon.core.p2p.identity : loadOrCreateIdentity;

        auto identity = loadOrCreateIdentity(identityFile);
        HostConfig hc;
        hc.agentVersion = "photowagon-mobile/0.5.0";
        // Off-LAN (4G) the computer's direct addresses are dead ends — the LAN address has
        // no route and the public one is behind CGNAT and cannot accept an inbound SYN — so
        // each one otherwise burns the full 10 s dial timeout before the relay path is even
        // tried. A reachable relay answers in well under a second, so a shorter dial timeout
        // only cuts the dead direct dials.
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
        // The piece protocol, both ways: what arrives from the computer lands in the piece
        // store (resumable in any order); what we have complete — our own camera roll by
        // sha256, and anything already downloaded — we serve to whoever the computer admits
        // us to talk to (today the computer; tomorrow the other phones of a shared album).
        pieces = new PieceStore(buildPath(dirName(settingsDir), "pieces"));
        pieceService = new PieceService(&localFileFor, pieces);
        host.setStreamHandler(pieceProtocol, (Stream s, Connection c, string) {
            scope (exit)
                s.close();
            try
                pieceService.serve(s);
            catch (Exception e)
            {
                try plog("pieces: request ended: ", e.msg); catch (Exception) {}
            }
        });
        // QUIC (/quic-v1): TLS 1.3 + native streams, no Noise/yamux, and the transport the
        // DCUtR hole punch runs over — the sync pipe. Built in when the arm64 ngtcp2/OpenSSL
        // archives are present (mobile/build-android.sh); TCP+Noise is the fallback.
        version (Libp2pQuic)
            host.swarm.addCapableTransport(new QuicTransport(identity));
        // The relay is only where the phone and the computer MEET off-LAN (a /p2p-circuit
        // carries the DCUtR signalling, a few KB); session() then insists on a direct
        // connection for the pipe. Auto-DCUtR stays off so the punch runs once, driven there.
        auto relay = new Relay(host);
        relay.autoHolePunch = false;
        host.swarm.addTransport(relay);
        // The DHT is the other half of the meeting point: when every saved address is dead
        // (off-LAN, and the computer's relay reservation moved to another relay since we
        // last talked), one query for the pairing rendezvous key returns the computer's
        // current addresses — the fresh /p2p-circuit among them. Client mode: queries
        // only, no serving, nobody's routing table lists this phone.
        KademliaConfig kc;
        kc.clientMode = true;
        kc.queryTimeout = 20.seconds;
        kad = new Kademlia(host, kc);
        plog("p2p: this phone is ", host.id.toString);
        // The single session entry (canonical hs shape): every DIRECT connection to the
        // computer — whoever wins the race between the DHT/meetUnder path and the mDNS LAN
        // path — runs one session via runOnConnection. A relayed connection is ignored here:
        // meetUnder makes one on its way and its own ensureDirect replaces it moments later,
        // and calling ensureDirect from inside a swarm callback would block it.
        auto self = this;
        host.addNotifiee(new class Notifiee {
            void connected(Connection c)
            {
                try
                {
                    import std.algorithm : canFind;
                    import vibe.core.core : runTask;

                    if (c.remoteAddr.toString.canFind("p2p-circuit"))
                        return;
                    auto cc = c;
                    runTask(() nothrow { try self.runOnConnection(cc); catch (Exception) {} });
                }
                catch (Exception)
                {
                }
            }

            void disconnected(Connection c)
            {
            }
        });
        import core.time : MonoTime, seconds;
        import std.algorithm : canFind;
        MonoTime[string] lastPunch;   // pace the ensureDirect punch-drive, per peer
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
            // LAN driver: browse the shared rendezvous for this key. MdnsRendezvous dials
            // each answer itself; the dial's DIRECT connection lands on the notifiee above.
            if (t.token != lanRvToken)
            {
                if (lanRv !is null)
                {
                    try
                        lanRv.close();
                    catch (Exception)
                    {
                    }
                    lanRv = null;
                }
                lanRvToken = t.token;
                try
                {
                    MdnsRendezvousConfig rc;
                    rc.announce = false;   // the phone only browses
                    lanRv = new MdnsRendezvous(host, "pw", cast(const(ubyte)[]) t.token, rc);
                }
                catch (Exception e)
                    plog("p2p: LAN rendezvous not started: ", e.msg);
            }
            // Preferential peer: the computer itself. Once its addresses are known (its
            // /p2p-circuit via a public relay, its public ip4 — learned at pairing and
            // persisted in p2p-addrs), dial them straight. This is the reliable path: it
            // skips getProviders, which is flaky on the huge public DHT. host.connect
            // de-dups, so re-dialing every cycle is cheap; a slow relay/punch is fine —
            // the loop keeps trying (patience). A circuit dial lands relayed; DCUtR then
            // upgrades it to a direct connection, which is what reaches the notifiee.
            string[] prefer;
            synchronized (lock)
                prefer = t.addrs.dup;
            foreach (a; prefer)
                try
                {
                    auto ma = Multiaddr.parse(a);
                    auto comps = ma.components;
                    if (comps.length == 0)
                        continue;
                    auto pid = PeerId.fromBytes(comps[$ - 1].value);
                    host.connect(pid, [ma]);
                    // A circuit addr only opens the relayed MEETING point; drive the DCUtR
                    // punch on it (auto-DCUtR is off, and meetUnder's getProviders is
                    // unreliable) so the preferential circuit yields a DIRECT connection.
                    // Off the supervisor on a task (ensureDirect blocks), paced per peer.
                    if (a.canFind("/p2p-circuit"))
                    {
                        immutable ps = pid.toBase58;
                        immutable nowp = MonoTime.currTime;
                        if (ps !in lastPunch || nowp - lastPunch[ps] >= 8.seconds)
                        {
                            lastPunch[ps] = nowp;
                            auto rl = relay;
                            auto pp = pid;
                            plog("p2p: driving ensureDirect (punch) via circuit to ", ps[0 .. 12]);
                            runTask(() nothrow { try rl.ensureDirect(pp); catch (Exception) {} });
                        }
                    }
                }
                catch (Exception e)
                    plog("p2p: prefer-dial failed ", a, ": ", e.msg);
            // WAN driver: meetUnder finds the computer under the SAME key on the DHT, punches,
            // and its direct connection lands on the notifiee. On its own task so it never
            // blocks this supervisor; one at a time, and only while no session is up.
            bool startMeet;
            synchronized (lock)
            {
                bool haveLink;
                foreach (_, ref v; lpSessions)
                    if (v.linked) { haveLink = true; break; }
                startMeet = !meeting && !haveLink;   // DHT-walk strangers never link → they never block the meet
            }
            if (startMeet)
            {
                synchronized (lock)
                    meeting = true;
                immutable tok = t.token;
                runTask(() nothrow {
                    try
                    {
                        joinDht(host);   // get kad into the DHT first — meetUnder only queries it
                        auto key = rendezvousKeyFor("pw", cast(const(ubyte)[]) tok);
                        cast(void) meetUnder(host, kad, relay, key, 30.seconds);
                    }
                    catch (Exception e)
                        try plog("p2p: meetUnder: ", e.msg); catch (Exception) {}
                    try
                        synchronized (lock)
                            meeting = false;
                    catch (Exception) {}
                });
            }
            sleep(1.seconds);
        }
    }

    /// The complete local file with this sha256, if we know one: a photo of ours the index
    /// hashed, or an original we downloaded. Null otherwise. (vibe thread)
    private string localFileFor(string sha)
    {
        string p;
        synchronized (lock)
            if (auto f = sha in localBySha)
                p = *f;
        import std.file : exists;
        return p.length && p.exists ? p : null;
    }

    /// The camera roll's sha256 → path map, filled by the index as it hashes (Qt thread).
    private string[string] localBySha;
    void registerLocal(string sha, string path)
    {
        if (sha.length != 64)
            return;
        synchronized (lock)
            localBySha[sha] = path;
    }

    version (PwHyperswarm)
    {
        // The udx/hyperdht/hyperswarm flavor: discover the desktop by the pairing-token topic
        // on the public hyperdht, punch a direct udx connection, and run the SAME control
        // (auth/pair + IPC) and piece+Merkle transfer over the one byte pipe via the mux.
        private void hsClient()
        {
            import vibe.core.core : sleep, runTask;
            import std.file : read;
            import photowagon.core.p2p.identity : loadOrCreateIdentity;

            loadOrCreateIdentity(identityFile);
            auto seed = cast(ubyte[]) read(identityFile);
            auto ht = new HsTransport(HsTransport.defaultBootstrap(), seed);
            ht.onPeer = (HsConn c) nothrow {
                try runTask(() nothrow { try hsRun(c); catch (Exception) {} });
                catch (Exception) {}
            };
            plog("p2p: hyperswarm flavor — this phone is ", hexKey(seed));
            string joined;
            for (;;)
            {
                Target t;
                synchronized (lock)
                    t = target;
                if (t.valid && t.token.length && t.token != joined)
                {
                    joined = t.token;
                    // Pass the KEY: HsTransport derives the topic and turns on the LAN
                    // rendezvous (browse) for the same key — on the LAN it hears the udx
                    // line and connects straight, in parallel with the DHT/punch path.
                    ht.start(cast(const(ubyte)[]) t.token, /*asServer*/ false);
                    plog("p2p: joined the pairing topic on the public DHT");
                }
                sleep(500.msecs);
            }
        }

        private static string hexKey(const(ubyte)[] seed)
        {
            import std.digest : toHexString, LetterCase;
            return toHexString!(LetterCase.lower)(seed[0 .. seed.length < 8 ? seed.length : 8]).idup;
        }

        // One connection: mux over the byte pipe, auth/pair on an 'i' control stream, then
        // the IPC pump + piece push/pull on 'p' streams. Structure mirrors session().
        private void hsRun(HsConn c)
        {
            import vibe.core.core : runTask, sleep;
            import core.time : MonoTime;
            import std.digest : toHexString, LetterCase;

            immutable peerKey = toHexString!(LetterCase.lower)(c.remotePublicKey[]).idup;
            immutable myRank = isPrivateIp4("/ip4/" ~ c.remoteAddress.host ~ "/") ? 2 : 1;
            HsConn toClose;
            synchronized (lock)
            {
                if (auto ss = peerKey in hsSessions)
                {
                    if (myRank <= ss.rank) { plog("hs: dup path rank ", myRank, " <= ", ss.rank, " — skip"); return; }
                    toClose = ss.conn;
                }
                hsSessions[peerKey] = HsSess(c, myRank);
            }
            plog("hs: session start rank ", myRank, " addr ", c.remoteAddress.host);
            if (toClose !is null)
            {
                plog("p2p: better path (rank ", myRank, ") — switching; destroying old");
                toClose.destroy();
                plog("hs: old destroyed");
            }
            scope (exit)
                synchronized (lock)
                    if (auto ss = peerKey in hsSessions)
                        if (ss.conn is c)
                            hsSessions.remove(peerKey);

            auto mux = new MuxSession(hsWrite(c), /*initiator*/ true, null);
            c.onData((ubyte[] b) nothrow { try mux.feed(b); catch (Exception) {} });
            bool dead;
            c.onClose = () nothrow { dead = true; try mux.closeAll(); catch (Exception) {} };

            auto ctl = mux.open();
            ctl.write([muxTagControl]);
            scope (exit)
                ctl.close();

            // auth (and pair if the desktop asks), synchronously, before pumping the UI
            plog("hs: auth on new path (rank ", myRank, ")");
            if (!hsAuth(ctl))
                return;
            plog("hs: auth ok (rank ", myRank, ")");
            deliverLink(true, toHexString!(LetterCase.lower)(c.remotePublicKey[]).idup, null);

            bool done;
            auto lastRecv = MonoTime.currTime;
            auto reader = runTask(() nothrow {
                try
                    for (;;)
                    {
                        auto line = cast(string) readLengthPrefixed(ctl, maxLine).idup;
                        lastRecv = MonoTime.currTime;
                        link.deliver(line);
                    }
                catch (Exception) {}
                done = true;
            });
            cast(void) reader;
            const(ubyte)[] ping = cast(const(ubyte)[]) JSONValue(["id": JSONValue(-1),
                "method": JSONValue("daemon.hello"), "params": JSONValue.emptyObject]).toString();
            enum pingEvery = 3.seconds, deadAfter = 15.seconds;
            auto lastPing = MonoTime.currTime;
            while (!done && !dead)
            {
                foreach (line; link.takeInbox())
                    if (line.length && !done)
                        try writeLengthPrefixed(ctl, cast(const(ubyte)[]) line);
                        catch (Exception) { done = true; break; }
                // pieces, each on its own 'p' mux stream, beside the control channel
                PushJob[] pj;
                synchronized (lock) { pj = pushJobs; pushJobs = null; }
                foreach (job; pj)
                {
                    immutable jt = job.ticket, jo = job.offset;
                    immutable jp = job.path, js = job.sha;
                    runTask(() nothrow {
                        string err;
                        try
                        {
                            auto ps = mux.open();
                            ps.write([muxTagPiece]);
                            scope (exit) ps.close();
                            if (js.length)
                                pushPieces(ps, jp, js);
                            else
                                throw new Exception("hyperswarm flavor needs a sha256 (pieces)");
                        }
                        catch (Exception e)
                            err = e.msg.length ? e.msg : "push failed";
                        try link.deliver(JSONValue(["pushDone": JSONValue(jt), "ok": JSONValue(err.length == 0),
                            "error": err.length ? JSONValue(err) : JSONValue(null)]).toString());
                        catch (Exception) {}
                    });
                }
                // thumbnails: one 'p' stream per batch, raw JPEG bytes (THUMB op)
                ThumbJob[] tj;
                synchronized (lock) { tj = thumbJobs; thumbJobs = null; }
                foreach (job; tj)
                {
                    immutable long[] tids = job.ids.idup;
                    auto onT = job.onThumb; auto tdone = job.done;
                    runTask(() nothrow {
                        try
                        {
                            auto ps = mux.open();
                            ps.write([muxTagPiece]);
                            scope (exit) ps.close();
                            askThumbs(ps, tids, onT);
                        }
                        catch (Exception) {}
                        try if (tdone !is null) tdone(); catch (Exception) {}
                    });
                }
                PullJob[] pull;
                synchronized (lock) { pull = pullJobs; pullJobs = null; }
                foreach (job; pull)
                {
                    immutable pt = job.ticket, pd = job.dest, psha = job.sha;
                    auto pstore = pieces;
                    runTask(() nothrow {
                        string err; bool retry; long sz;
                        try
                        {
                            auto ps = mux.open();
                            ps.write([muxTagPiece]);
                            scope (exit) ps.close();
                            if (psha.length)
                                sz = pullPieces(ps, pstore, psha, pd, retry);
                            else
                                throw new Exception("hyperswarm flavor downloads by pieces (need sha256)");
                        }
                        catch (Exception e) { err = e.msg.length ? e.msg : "download failed"; retry = true; }
                        try link.deliver(JSONValue(["pullDone": JSONValue(pt), "ok": JSONValue(err.length == 0),
                            "path": JSONValue(pd), "size": JSONValue(sz), "retry": JSONValue(retry),
                            "error": err.length ? JSONValue(err) : JSONValue(null)]).toString());
                        catch (Exception) {}
                    });
                }
                immutable now = MonoTime.currTime;
                if (now - lastPing >= pingEvery)
                {
                    lastPing = now;
                    try writeLengthPrefixed(ctl, ping); catch (Exception) break;
                }
                if (now - lastRecv >= deadAfter)
                {
                    plog("p2p: hyperswarm link silent — dropping");
                    break;
                }
                uint v;
                synchronized (lock) v = target.version_;
                if (v != joinedVersion)
                {
                }
                sleep(20.msecs);
            }
            bool stillCurrent;
            synchronized (lock)
                if (auto ss = peerKey in hsSessions)
                    stillCurrent = ss.conn is c;
            if (stillCurrent)
                deliverLink(false, null, "connection closed");
            else
                plog("hs: superseded — silent exit (rank ", myRank, ")");
            try c.closeGracefully(2.seconds); catch (Exception) {}
        }

        // A nothrow byte-sink bound to a connection, for the mux.
        private void delegate(const(ubyte)[]) nothrow hsWrite(HsConn c)
        {
            return (const(ubyte)[] f) nothrow { try c.write(f.dup); catch (Exception) {} };
        }

        // daemon.auth, then daemon.pair if the desktop needs it; blocks until admitted or refused.
        private bool hsAuth(MuxStream ctl)
        {
            JSONValue auth = ["id": JSONValue(-10), "method": JSONValue("daemon.auth"),
                "params": JSONValue(["token": JSONValue(hsToken()), "name": JSONValue(deviceName())])];
            writeLengthPrefixed(ctl, cast(const(ubyte)[]) auth.toString());
            for (;;)
            {
                auto j = parseJSON(cast(string) readLengthPrefixed(ctl, maxLine).idup);
                if (j.type != JSONType.object)
                    continue;
                if ("event" in j.object) { link.deliver(j.toString()); continue; }
                immutable id = "id" in j.object && j["id"].type == JSONType.integer ? j["id"].integer : 0;
                immutable ok = ("result" in j.object) !is null;
                if (id == -10)
                {
                    if (!ok) { deliverLink(false, null, "not admitted: " ~ j.toString()); return false; }
                    auto r = j["result"];
                    if (r.type == JSONType.object && "needsPairing" in r.object && r["needsPairing"].type == JSONType.true_)
                    {
                        if (pairCode.length == 0)
                            pairCode = fourDigitCode();
                        plog("p2p: pairing code ", pairCode, " — enter it on the computer");
                        link.deliver(JSONValue(["event": JSONValue("pairing.code"), "data": JSONValue(["code": JSONValue(pairCode)])]).toString());
                        JSONValue pair = ["id": JSONValue(-11), "method": JSONValue("daemon.pair"),
                            "params": JSONValue(["code": JSONValue(pairCode), "name": JSONValue(deviceName())])];
                        writeLengthPrefixed(ctl, cast(const(ubyte)[]) pair.toString());
                        continue;
                    }
                    return true;   // admitted
                }
                if (id == -11)
                {
                    if (!ok) { deliverLink(false, null, "pairing refused"); return false; }
                    link.deliver(JSONValue(["event": JSONValue("pairing.code"), "data": JSONValue(["done": JSONValue(true)])]).toString());
                    pairCode = null;
                    return true;
                }
                link.deliver(j.toString());
            }
        }

        private string hsToken()
        {
            synchronized (lock) return target.token;
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

    /// Wi-Fi (a LAN) or cellular? The address the kernel would source a packet to the
    /// internet from tells: RFC 1918 = a LAN behind a home router; a carrier address (CGNAT
    /// 100.64/10 or public) = cellular. A UDP connect() only picks a route, nothing is sent.
    /// Unknown → true, so the LAN is still tried.
    private static bool onLan()
    {
        import std.socket : UdpSocket, InternetAddress;

        try
        {
            auto s = new UdpSocket();
            scope (exit)
                s.close();
            s.connect(new InternetAddress("8.8.8.8", 53));
            auto la = cast(InternetAddress) s.localAddress;
            if (la is null)
                return true;
            return isPrivateIp4("/ip4/" ~ la.toAddrString ~ "/");
        }
        catch (Exception)
            return true;
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

    /// Run the app session on an already-open DIRECT connection to the computer: authenticate
    /// with the token, pair if new, then pump lines both ways until it drops. The swarm
    /// Notifiee calls this for every direct connection; the meetUnder/DHT path and the mDNS
    /// LAN path each just CAUSE one, and the swarm's Notifiee is the single entry (the canonical
    /// hs shape). Single-flight per peer, so the two paths racing to the same computer run one
    /// session, not two. No dialing and no ensureDirect here — the notifiee already dropped the
    /// relayed connections; only direct ones reach this.
    private void runOnConnection(Connection conn)
    {
        import vibe.core.core : runTask, sleep;
        import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed, readExact;
        import std.algorithm : canFind;

        auto peer = conn.remotePeer;
        immutable peerKey = peer.toBase58;
        // Roaming: a private-IP (LAN) path outranks a public/relay-punched (WAN) path. A better
        // path preempts the running session — closing the old connection so its pump exits at
        // once — and takes over; an equal/worse duplicate is dropped. Same rule as the hs flavor.
        immutable myRank = isPrivateIp4(conn.remoteAddr.toString) ? 2 : 1;
        Connection toClose;
        synchronized (lock)
        {
            if (auto ss = peerKey in lpSessions)
            {
                if (myRank <= ss.rank) { plog("p2p(libp2p): dup path rank ", myRank, " <= ", ss.rank, " — skip"); return; }
                toClose = ss.conn;
            }
            lpSessions[peerKey] = LpSess(conn, myRank);
        }
        if (toClose !is null)
        {
            plog("p2p: better path (rank ", myRank, ") — switching; closing old");
            toClose.close();
            plog("p2p(libp2p): old closed");
        }
        scope (exit)
            synchronized (lock)
                if (auto ss = peerKey in lpSessions)
                    if (ss.conn is conn)
                        lpSessions.remove(peerKey);
        // The token names who we expect; the IPC auth below is what actually rejects a stranger
        // that answered the same rendezvous (same as hs). Captured once for this session.
        Target t;
        synchronized (lock)
            t = target;
        if (!t.valid)
            return;
        auto s = conn.newStream(ipcProtocol);
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
        synchronized (lock)
            if (auto ss = peerKey in lpSessions)
                if (ss.conn is conn)
                    ss.linked = true;   // a real desktop link now holds the meet gate closed

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
                mergeLearnedAddrs(fresh, /*authoritative*/ true);   // its circuits are the current ones
            }
            // The computer's live DHT peers double as our seeds into the public DHT (the
            // ones this build can talk to: Ed25519 ids — the lite Noise verifies no RSA — on
            // ip4 tcp/quic, no relay circuits). The IPFS bootstrappers are RSA (Qm…), hence this.
            if ("result" in sres && sres["result"].type == JSONType.object && "peers" in sres["result"])
            {
                string[] found;
                foreach (pj; sres["result"]["peers"].array)
                {
                    if (pj.type != JSONType.object || !("connected" in pj) || pj["connected"].type != JSONType.true_)
                        continue;
                    immutable pid = pj["peerId"].str;
                    if (!pid.startsWith("12D3Koo"))
                        continue;
                    foreach (a; pj["addrs"].array)
                    {
                        if (a.type != JSONType.string)
                            continue;
                        immutable text = a.str;
                        if (!text.startsWith("/ip4/") || text.canFind("/p2p-circuit") || text.canFind("/webrtc") || text.canFind("/ws"))
                            continue;
                        if (!text.canFind("/tcp/") && !text.canFind("/quic-v1"))
                            continue;
                        found ~= text.canFind("/p2p/") ? text : text ~ "/p2p/" ~ pid;
                        break;   // one address per peer is plenty
                    }
                }
                rememberSeeds(found);
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
        void mark(string what) nothrow
        {
            // PW_TRACE_SESSION: where the vibe loop was when it died (an OOM right after
            // connect on Waydroid x86_64, 2026-09-21) — each step and the D heap in use
            import core.memory : GC;
            try plog("p2p: session ", what, " heap=", GC.stats.usedSize / 1024, "K"); catch (Exception) {}
        }
        mark("A: keepalive setup");
        {   // can this thread's GC hand out a frame-sized buffer at all? (Waydroid x86_64 OOM hunt)
            try { auto probe = new ubyte[64 * 1024 * 1024]; probe[$ - 1] = 1; mark("A2: 64 MiB probe ok"); probe = null; }
            catch (Throwable t) { try plog("p2p: session A2: 64 MiB probe FAILED: ", t.msg); catch (Exception) {} }
        }
        auto reader = runTask(() nothrow {
            try
            {
                mark("B: reader task up");
                for (;;)
                {
                    // readLengthPrefixed, unrolled so the length is on record before the
                    // allocation that has been failing on Waydroid x86_64
                    import libp2p.core.stream : readVarint;
                    import std.conv : to;

                    ulong len;
                    try
                        len = s.readVarint;
                    catch (Error t)
                    {
                        mark("D5: readVarint FAILED: " ~ t.msg ~ " | " ~ (() { try return t.info.toString(); catch (Throwable) return "no trace"; })());
                        throw t;
                    }
                    if (len > maxLine)
                        throw new Exception("frame of " ~ len.to!string ~ " bytes exceeds the limit");
                    if (len > 256 * 1024)
                        mark("D: frame of " ~ len.to!string ~ " bytes coming");
                    ubyte[] frame;
                    try
                        frame = new ubyte[cast(size_t) len];
                    catch (Throwable t)
                    {
                        mark("D2: allocation of " ~ len.to!string ~ " FAILED: " ~ t.msg);
                        throw new Exception("cannot allocate a " ~ len.to!string ~ "-byte frame");
                    }
                    try
                        readExact(s, frame);
                    catch (Error t)
                    {
                        mark("D3: readExact of " ~ len.to!string ~ " FAILED: " ~ t.msg);
                        throw t;
                    }
                    lastRecv = MonoTime.currTime;
                    try
                        link.deliver(cast(string) frame.idup);
                    catch (Error t)
                    {
                        mark("D4: deliver of " ~ len.to!string ~ " FAILED: " ~ t.msg);
                        throw t;
                    }
                }
            }
            catch (Exception) {}
            done = true;
        });
        cast(void) reader;
        const(ubyte)[] ping = cast(const(ubyte)[]) JSONValue(["id": JSONValue(-1),
            "method": JSONValue("daemon.hello"), "params": JSONValue.emptyObject]).toString();
        // Tolerant on purpose: on a cellular uplink under a full-rate push the RTT can sit
        // in the hundreds of ms (it hit 2 s before the stack went BBR + round-robin across
        // streams, and a 9 s dead-after then cut a live push at 42 s and restarted it from
        // zero — 2026-09-20). A truly dead link takes 15 s to notice; a lost push costs more.
        enum pingEvery = 3.seconds;
        enum deadAfter = 15.seconds;
        auto lastPing = MonoTime.currTime;
        mark("C: loop start");
        // Polling rather than the link's shared ManualEvent: on Android vibe's
        // per-thread event for it comes back invalid (an assertion in
        // threadlocalwaiter.d), and 20 ms of latency on a phone is nothing.
        while (!done)
        {
            foreach (line; link.takeInbox())
                if (line.length && !done)
                {
                    try
                        writeLengthPrefixed(s, cast(const(ubyte)[]) line);
                    catch (Error t)
                    {
                        mark("E: write of " ~ (() { import std.conv : to; return line.length.to!string; })() ~ " FAILED: " ~ t.msg);
                        throw t;
                    }
                }
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
                immutable js = job.sha;
                immutable jo = job.offset;
                runTask(() nothrow {
                    string err;
                    try
                    {
                        if (js.length && jo < 0)
                        {
                            auto ps = conn.newStream(pieceProtocol);
                            scope (exit) ps.close();
                            pushPieces(ps, jp, js);
                        }
                        else if (js.length)
                            pushResumable(conn, jp, js, jo);
                        else
                            pushOne(conn, jt, jp);
                    }
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
            // thumbnails: raw JPEG bytes on a piece stream (THUMB op), one stream per batch
            ThumbJob[] tjobs;
            synchronized (lock)
            {
                tjobs = thumbJobs;
                thumbJobs = null;
            }
            foreach (job; tjobs)
            {
                immutable long[] tids = job.ids.idup;
                auto onT = job.onThumb;
                auto tdone = job.done;
                runTask(() nothrow {
                    try
                    {
                        auto ps = conn.newStream(pieceProtocol);
                        scope (exit) ps.close();
                        askThumbs(ps, tids, onT);
                    }
                    catch (Exception)
                    {
                    }
                    try
                        if (tdone !is null)
                            tdone();
                    catch (Exception)
                    {
                    }
                });
            }
            // pull pipe: originals the UI asked for, each on its own stream, resumable
            PullJob[] pulls;
            synchronized (lock)
            {
                pulls = pullJobs;
                pullJobs = null;
            }
            foreach (job; pulls)
            {
                immutable pt = job.ticket;
                immutable pid = job.id;
                immutable pd = job.dest;
                immutable psha = job.sha;
                auto pstore = pieces;
                runTask(() nothrow {
                    string err;
                    bool retry;
                    long size;
                    try
                        if (psha.length)
                        {
                            auto ps = conn.newStream(pieceProtocol);
                            scope (exit) ps.close();
                            size = pullPieces(ps, pstore, psha, pd, retry);
                        }
                        else
                            size = pullOne(conn, pid, pd, retry);
                    catch (Exception e)
                    {
                        err = e.msg.length ? e.msg : "download failed";
                        retry = true;   // a dropped stream: the .part keeps what landed
                    }
                    try
                        link.deliver(JSONValue([
                            "pullDone": JSONValue(pt),
                            "ok": JSONValue(err.length == 0),
                            "path": JSONValue(pd),
                            "size": JSONValue(size),
                            "retry": JSONValue(retry),
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
        bool stillCurrent;
        synchronized (lock)
            if (auto ss = peerKey in lpSessions)
                stillCurrent = ss.conn is conn;
        if (stillCurrent)
            deliverLink(false, null, "connection closed");
        else
            plog("p2p(libp2p): superseded — silent exit (rank ", myRank, ")");
    }

    /// Keep the freshest DHT seeds (newest first, at most 12) and persist them for the next
    /// start — that is what makes an off-LAN lookup possible after the phone was on the LAN once.
    private void rememberSeeds(string[] found)
    {
        import std.algorithm : canFind;
        import std.array : join;

        if (found.length == 0)
            return;
        string[] next = found.dup;
        foreach (s; dhtSeeds)
            if (!next.canFind(s))
                next ~= s;
        if (next.length > 12)
            next = next[0 .. 12];
        if (next == dhtSeeds)
            return;
        dhtSeeds = next;
        try
        {
            import std.file : write, mkdirRecurse;

            mkdirRecurse(settingsDir);
            write(buildPath(settingsDir, "dht-seeds"), next.join("\n"));
            plog("p2p: ", next.length, " dht seeds remembered");
        }
        catch (Exception e)
            plog("p2p: cannot save dht seeds: ", e.msg);
    }

    /// Where is the computer now? It announces itself in the DHT as the PROVIDER of the
    /// rendezvous key derived from the pairing token, with its current addresses (a
    /// computer behind CGNAT is not in the public routing tables, so a lookup by peer id
    /// alone would come back empty — hence provider records). One query through the public
    /// bootstrap peers (the same seeds the desktop joins through); a lookup by peer id is
    /// the fallback for a computer that is publicly reachable. Only what this build can
    /// dial comes back, circuits first. Empty when the DHT does not know it (yet).
    /// The phone's way INTO the public DHT, so `meetUnder`'s getProviders has a routing
    /// table to query: connect to the peers the computer was last seen with (rememberSeeds),
    /// then a few public go-libp2p nodes (Ed25519 ids on ip4 — the IPFS bootstrappers are
    /// RSA, which this lite Noise cannot verify). Public peers churn, so these are a
    /// fallback, not a dependency; two live seeds are enough. Idempotent: host.connect to an
    /// already-connected seed returns the existing connection.
    private void joinDht(Host host)
    {
        import std.algorithm : canFind;

        static immutable fallback = [
            "/ip4/52.242.196.161/tcp/4001/p2p/12D3KooWMjQdm4U71R6T3RC9HboQeKyvnPttvAUYp4uZ3hBNYvHr",
            "/ip4/40.160.21.102/tcp/4001/p2p/12D3KooWEaVCpKd2MgZeLugvwCWRSQAMYWdu6wNG6SySQsgox8k5",
            "/ip4/98.81.67.202/tcp/4001/p2p/12D3KooWJgc1Dm8xYwFVNfbNz4Zpxa91YtV2KxcUgR723ypHQaMR",
            "/ip4/23.166.88.52/tcp/4001/p2p/12D3KooWDvhR5MkmS4Z4JUBMXfWDNcQ6baLFSxfKGTJ3Ni9Hquad",
        ];
        string[] seeds = dhtSeeds.dup;
        foreach (f; fallback)
            if (!seeds.canFind(f))
                seeds ~= f;
        size_t joined, tried;
        foreach (s; seeds)
        {
            if (joined >= 4 || tried >= 12)   // enter through more of the computer's own well-connected peers, so getProviders converges to where it announced
                break;
            tried++;
            try
            {
                auto ma = Multiaddr.parse(s);
                auto comps = ma.components;
                auto sid = PeerId.fromBytes(comps[$ - 1].value);
                host.connect(sid, [ma]);
                kad.addAddress(sid, ma);
                joined++;
            }
            catch (Exception e)
                plog("p2p: dht seed ", s, " unreachable: ", e.msg);
        }
        plog("p2p: in the DHT through ", joined, " seed(s)");
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

private enum pushProtocolV2 = "/photowagon/push/2.0.0";

/// Upload over the piece protocol: tell the computer the manifest, ask which pieces it has,
/// send the missing ones (each verified on arrival), one stream per request. A drop costs
/// at most the piece in flight; the next attempt asks again and sends only what is missing.
private void pushPieces(Stream st, string path, string sha)
{
    import std.conv : to;
    import vibe.core.file : openFile, FileMode;

    auto man = manifestOf(path);
    if (!tellManifest(st, sha, man))
        throw new Exception("computer refused the manifest");
    auto theirs = askHave(st, sha, man.count);
    if (theirs.count == 0)
        theirs = Bitfield(man.count);
    immutable missing = man.count - theirs.haveCount;
    plog("push: ", path.baseName, " ", man.count, " pieces, computer has ", theirs.haveCount, ", sending ", missing);
    auto fh = openFile(path, FileMode.read);
    scope (exit)
        fh.close();
    auto buf = new ubyte[pieceSize];
    foreach (i; 0 .. man.count)
    {
        if (theirs.has(i))
            continue;
        immutable n = man.lengthOf(i);
        fh.seek(cast(long) i * pieceSize);
        fh.read(buf[0 .. n]);
        if (!givePiece(st, sha, i, buf[0 .. n]))
            throw new Exception("computer refused piece " ~ i.to!string);
    }
}

/// Download over the piece protocol: the computer's manifest, our piece store's bitfield,
/// then every missing piece (verified against its hash as it lands); finish() checks the
/// whole file and moves it to `dest`. Returns the size.
private long pullPieces(Stream st, PieceStore pieces, string sha, string dest, out bool retry)
{
    import std.conv : to;

    retry = true;
    auto man = askInfo(st, sha);
    if (man.count == 0 && man.size == 0)
    {
        retry = false;
        throw new Exception("the computer does not have that file");
    }
    if (!(pieces.manifest(sha).count == man.count && man.count > 0))
        pieces.adopt(sha, man);
    auto mine = pieces.have(sha);
    plog("pull: ", dest.baseName, " ", man.count, " pieces, have ", mine.haveCount);
    foreach (i; 0 .. man.count)
    {
        if (mine.has(i))
            continue;
        auto bytes = askPiece(st, sha, man, i);
        pieces.store(sha, i, bytes);
    }
    try
        pieces.finish(sha, dest);
    catch (Exception e)
    {
        retry = false;
        throw e;
    }
    return man.size;
}
private enum pullProtocol = "/photowagon/pull/1.0.0";

/// Downloads the computer's original `id` into `dest` (see core/p2p/blobpush.d pullProtocol):
/// asks for the bytes from the size of `dest.part`, appends as they arrive, and when all are
/// in checks the file's sha256 against the one the computer declared before renaming it
/// into place. Returns the size. Sets `retry` = false on a definitive refusal (no such
/// photo / not allowed / hash mismatch — the .part is discarded), true when a retry would
/// continue from the .part; throws on a dropped stream.
private long pullOne(Connection conn, long id, string dest, out bool retry)
{
    import vibe.core.file : openFile, FileMode;
    import std.file : exists, getSize, rename, remove, mkdirRecurse;
    import std.path : dirName;
    import std.conv : to;
    import std.digest.sha : SHA256;
    import std.digest : toHexString, LetterCase;

    retry = true;
    immutable part = dest ~ ".part";
    mkdirRecurse(dest.dirName);
    immutable offset = part.exists ? cast(long) getSize(part) : 0;
    auto st = conn.newStream(pullProtocol);
    scope (exit)
        st.close();
    ubyte[8] ib = longToBe8(id), ob = longToBe8(offset);
    st.write(ib[] ~ ob[]);
    ubyte[1] status;
    readExact(st, status[]);
    if (status[0] != 0)
    {
        retry = false;
        throw new Exception("the computer has no such original, or refused");
    }
    ubyte[8] sb;
    readExact(st, sb[]);
    long size;
    foreach (x; sb[])
        size = (size << 8) | x;
    ubyte[32] sha;
    readExact(st, sha[]);
    if (offset > size)
    {
        remove(part);   // a stale/foreign .part: start over next time
        throw new Exception("partial file larger than the original — discarded");
    }
    if (offset > 0)
        plog("pull: resuming ", dest.baseName, " from ", offset, " of ", size, " bytes");
    else
        plog("pull: ", dest.baseName, " ", size, " bytes on pull/1.0.0");
    auto fh = openFile(part, offset > 0 ? FileMode.append : FileMode.createTrunc);
    ubyte[64 * 1024] buf;
    long remaining = size - offset;
    try
    {
        while (remaining > 0)
        {
            immutable n = cast(size_t)(remaining < buf.length ? remaining : buf.length);
            readExact(st, buf[0 .. n]);
            fh.write(buf[0 .. n]);
            remaining -= n;
        }
    }
    finally
        fh.close();
    // the whole file, hashed once it is complete (the prefix may be from an earlier attempt)
    SHA256 h;
    h.start();
    {
        auto rf = openFile(part, FileMode.read);
        scope (exit)
            rf.close();
        long left = size;
        while (left > 0)
        {
            immutable n = cast(size_t)(left < buf.length ? left : buf.length);
            rf.read(buf[0 .. n]);
            h.put(buf[0 .. n]);
            left -= n;
        }
    }
    immutable got = toHexString!(LetterCase.lower)(h.finish()[]).idup;
    immutable want = toHexString!(LetterCase.lower)(sha[]).idup;
    if (got != want)
    {
        remove(part);
        retry = false;
        throw new Exception("downloaded bytes do not match the computer's sha256 — discarded");
    }
    if (dest.exists)
        remove(dest);
    rename(part, dest);
    return size;
}

/// The resumable pipe (push/2.0.0, see core/p2p/blobpush.d): header (sha256 raw)(size)
/// (offset), one status byte back, then the bytes from `offset`; the computer spools each
/// slice to disk as it lands, so whatever got through survives a drop. Throws on a wrong
/// offset (the caller re-probes) and on a refused/failed push.
private void pushResumable(Connection conn, string path, string shaHex, long offset)
{
    import vibe.core.file : openFile, FileMode;
    import std.conv : to;

    ubyte[32] sha;
    foreach (i; 0 .. 32)
        sha[i] = cast(ubyte) shaHex[2 * i .. 2 * i + 2].to!int(16);
    auto st = conn.newStream(pushProtocolV2);
    scope (exit)
        st.close();
    auto fh = openFile(path, FileMode.read);
    scope (exit)
        fh.close();
    immutable size = cast(long) fh.size;
    if (offset > size)
        throw new Exception("computer has more bytes than the file (" ~ offset.to!string ~ " > " ~ size.to!string ~ ")");
    ubyte[8] sb = longToBe8(size), ob = longToBe8(offset);
    st.write(sha[] ~ sb[] ~ ob[]);
    ubyte[1] status;
    readExact(st, status[]);
    if (status[0] == 2)
    {
        ubyte[8] hb;
        readExact(st, hb[]);
        long have;
        foreach (x; hb[])
            have = (have << 8) | x;
        throw new Exception("offset out of step: the computer has " ~ have.to!string ~ " bytes");
    }
    if (status[0] != 0)
        throw new Exception("push refused by the computer");
    fh.seek(offset);
    plog("push: ", path.baseName, " ", size - offset, " bytes from offset ", offset, " on push/2.0.0");
    ubyte[64 * 1024] buf;
    long remaining = size - offset;
    while (remaining > 0)
    {
        immutable n = cast(size_t)(remaining < buf.length ? remaining : buf.length);
        fh.read(buf[0 .. n]);
        st.write(buf[0 .. n]);
        remaining -= n;
    }
    ubyte[1] ack;
    readExact(st, ack[]);
    if (ack[0] != 1)
        throw new Exception("computer did not confirm the bytes");
}

/// Streams one file's raw bytes on the blob pipe — a stream on the DIRECT connection, never
/// a relayed one: (long ticket)(long size)(bytes), then waits for the one-byte ack. vibe
/// async file I/O, so the fiber yields and the session's keepalive keeps ticking.
private void pushOne(Connection conn, long ticket, string path)
{
    import vibe.core.file : openFile, FileMode;

    auto st = conn.newStream(pushProtocol);
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
