/// One phone↔desktop session over a hyperswarm Connection: the app protocol that used to
/// ride libp2p's `/photowagon/ipc` stream (plus a blob stream per file) now rides ONE
/// end-to-end encrypted udx byte stream, framed by photowagon.core.sync.frames:
///
///   control frames  — the JSON lines of docs/ipc.md (auth, pairing, requests, events, the
///                     keepalive), exactly what the UI's InProcessLink carries;
///   chunk frames    — a file being pushed, ≤64 KB at a time with a sha256 + offset, so a
///                     control frame always gets a turn between chunks and a drop resumes
///                     from the receiver's `have` offset instead of restarting the file;
///   ack frames      — the receiver confirming each chunk landed.
///
/// Runs entirely on the vibe thread that owns the udx loop (Connection callbacks are
/// nothrow and fire there; our pump is a task on the same thread). The Qt side is reached
/// only through the InProcessLink, exactly as before, so P2pBridge.drain() and LocalBridge
/// are unchanged: `p2p.link` events, `pushDone` notes and IPC replies look identical.
module photowagon.mobile.hsession;

import core.time : Duration, MonoTime, msecs, seconds;
import std.json;

import hyperswarm.connection : Connection;

import photowagon.core.ipc.link : InProcessLink;
import photowagon.core.sync.frames;
import photowagon.mobile.plog : plog;

/// A file the Qt side asked us to push. `meta` is the library.import metadata
/// ({name, takenAt, mtimeMs, sha256}) LocalBridge assembled; the sha256 keys the resume.
struct PushJob
{
    long ticket;
    string path;
    JSONValue meta;
}

/// What the session needs from its owner (P2pBridge), as delegates so the owner's
/// fields stay private and the session has no compile-time tie to the bridge class.
struct SessionHost
{
    InProcessLink link;
    string delegate() token;          /// the pairing token to authenticate with
    string delegate() deviceName;     /// this phone's display name
    string delegate() pairCode;       /// the 4-digit code shown while pairing ("" = make one)
    void delegate(string) setPairCode;
    PushJob[] delegate() takeJobs;    /// queued pushes (drains the owner's queue)
}

final class HsSession
{
    private Connection c;
    private SessionHost host;
    private FrameDecoder dec;
    private bool authed, done, closed;
    private MonoTime lastRecv, lastPing;
    private string peerHex;

    // request ids we own on the control channel; everything else is the UI's
    private enum long idHello = -1, idAuth = -10, idPair = -11, idProbe = -20, idComplete = -21;
    private enum pingEvery = 3.seconds;
    private enum deadAfter = 9.seconds;

    // ---- the one push in flight -------------------------------------------------------
    private enum PushState { none, probing, chunking, completing }
    private PushState pstate;
    private PushJob job;
    private ubyte[32] sha;
    private long offset, size;
    private import vibe.core.file : FileStream;
    private FileStream fh;
    private bool fhOpen;

    this(Connection c, SessionHost host)
    {
        this.c = c;
        this.host = host;
        lastRecv = lastPing = MonoTime.currTime;
        peerHex = hex(c.remotePublicKey[]);
        c.onData(&onData);
        c.onClose = &onClose;
        // authenticate first; the UI's own requests are pumped only once admitted
        sendControl(req(idAuth, "daemon.auth", ["token": JSONValue(host.token()), "name": JSONValue(host.deviceName())]));
        import vibe.core.core : runTask;
        runTask(&pump);
    }

    /// Drop the session (a fresh pairing code, or the owner shutting down).
    void close() nothrow
    {
        if (closed)
            return;
        closed = true;
        done = true;
        c.closeGracefully(2.seconds);
    }

    bool alive() const nothrow @nogc { return !done; }
    string peer() const nothrow @nogc { return peerHex; }

    // ---- inbound ----------------------------------------------------------------------

    private void onData(ubyte[] bytes) nothrow
    {
        if (done)
            return;
        try
        {
            lastRecv = MonoTime.currTime;
            dec.feed(bytes);
            Frame f;
            while (dec.next(f))
            {
                switch (f.type)
                {
                case typeControl: onControl(cast(string) f.payload.idup); break;
                case typeAck:     onAck(decodeAck(f.payload)); break;
                default:          plog("hs: unexpected frame type ", f.type, " from the computer"); break;
                }
            }
        }
        catch (Exception e)
        {
            try plog("hs: bad frame: ", e.msg); catch (Exception) {}
            fail("bad frame: " ~ e.msg);
        }
    }

    private void onControl(string line)
    {
        JSONValue j;
        try
            j = parseJSON(line);
        catch (Exception)
            return;
        if (j.type != JSONType.object)
            return;
        if ("event" in j.object)
        {
            host.link.deliver(line);   // events go straight to the UI, even mid-handshake
            return;
        }
        immutable id = "id" in j.object && j["id"].type == JSONType.integer ? j["id"].integer : long.max;
        switch (id)
        {
        case idHello: return;                       // keepalive answered; lastRecv already bumped
        case idAuth:  onAuthReply(j); return;
        case idPair:  onPairReply(j); return;
        case idProbe: onProbeReply(j); return;
        case idComplete: onCompleteReply(j); return;
        default:
            host.link.deliver(line);                // a reply to one of the UI's requests
        }
    }

    // A device the desktop has never seen must be authorized there: we show a 4-digit
    // code and the person at the computer types it; the desktop answers once they do.
    private void onAuthReply(JSONValue reply)
    {
        if (!("result" in reply.object))
        {
            fail("not admitted: " ~ reply.toString());
            return;
        }
        auto r = reply["result"];
        if (r.type == JSONType.object && "needsPairing" in r.object && r["needsPairing"].type == JSONType.true_)
        {
            string code = host.pairCode();
            if (code.length == 0)
            {
                code = fourDigitCode();
                host.setPairCode(code);           // stable across reconnects: the operator sees one code
            }
            plog("hs: pairing code ", code, " — enter it on the computer to allow this phone");
            host.link.deliver(JSONValue(["event": JSONValue("pairing.code"),
                "data": JSONValue(["code": JSONValue(code)])]).toString());
            sendControl(req(idPair, "daemon.pair", ["code": JSONValue(code), "name": JSONValue(host.deviceName())]));
            return;
        }
        admitted();
    }

    private void onPairReply(JSONValue reply)
    {
        host.link.deliver(JSONValue(["event": JSONValue("pairing.code"),
            "data": JSONValue(["done": JSONValue(true)])]).toString());
        if (!("result" in reply.object))
        {
            fail("pairing was not confirmed on the computer");
            return;
        }
        host.setPairCode(null);                   // paired: a later re-pairing makes a fresh code
        admitted();
    }

    private void admitted()
    {
        authed = true;
        plog("hs: admitted by the computer (", peerHex[0 .. 12], "…)");
        deliverLink(true, peerHex, null);
    }

    // ---- outbound pump: the UI's requests, the keepalive, the push ------------------------

    private void pump() nothrow
    {
        import vibe.core.core : sleep;
        try
        {
            while (!done)
            {
                if (authed)
                {
                    foreach (line; host.link.takeInbox())
                        if (line.length && !done)
                            sendControl(line);
                    drivePush();
                }
                immutable now = MonoTime.currTime;
                if (now - lastPing >= pingEvery)
                {
                    lastPing = now;
                    sendControl(req(idHello, "daemon.hello", null));
                }
                if (now - lastRecv >= deadAfter)
                {
                    plog("hs: link silent for ", deadAfter.total!"seconds", "s — dropping");
                    fail("connection closed");
                    break;
                }
                // Polling rather than the link's ManualEvent: on Android vibe's per-thread
                // event for it comes back invalid, and 20 ms of latency on a phone is nothing.
                sleep(20.msecs);
            }
        }
        catch (Exception e)
        {
            try plog("hs: pump died: ", e.msg); catch (Exception) {}
            fail(e.msg);
        }
    }

    // ---- the push: probe → chunks (one in flight, acked) → complete ----------------------

    private void drivePush()
    {
        if (pstate != PushState.none)
            return;
        auto jobs = host.takeJobs();
        if (jobs.length == 0)
            return;
        job = jobs[0];
        // anything beyond the first waits: takeJobs drained them, so put the rest back is the
        // owner's business — we ask again next tick, hence the owner must keep them queued.
        // (P2pBridge hands us one job per call.)
        if (!hexToBytes(getStr(job.meta, "sha256"), sha))
        {
            finishPush(false, "bad sha256 in metadata");
            return;
        }
        pstate = PushState.probing;
        sendControl(req(idProbe, "library.import", [
            "name": job.meta["name"], "sha256": job.meta["sha256"], "probe": JSONValue(true)]));
    }

    private void onProbeReply(JSONValue reply)
    {
        if (pstate != PushState.probing)
            return;
        if (!("result" in reply.object))
        {
            finishPush(false, "probe failed: " ~ reply.toString());
            return;
        }
        auto r = reply["result"];
        if (r.type == JSONType.object && "existed" in r.object && r["existed"].type == JSONType.true_)
        {
            finishPush(true, null);              // already on the computer: nothing to send
            return;
        }
        offset = r.type == JSONType.object && "have" in r.object && r["have"].type == JSONType.integer ? r["have"].integer : 0;
        try
        {
            import vibe.core.file : openFile, FileMode;
            fh = openFile(job.path, FileMode.read);
            fhOpen = true;
            size = cast(long) fh.size;
        }
        catch (Exception e)
        {
            finishPush(false, "cannot read " ~ job.path ~ ": " ~ e.msg);
            return;
        }
        if (offset > size)
            offset = 0;                          // the spool is longer than our file: start over
        plog("hs: pushing ", getStr(job.meta, "name"), " from offset ", offset, " of ", size);
        if (offset >= size)
            sendComplete();
        else
            sendChunk();
    }

    private void sendChunk()
    {
        pstate = PushState.chunking;
        immutable n = cast(size_t)((size - offset) < maxChunk ? (size - offset) : maxChunk);
        auto buf = new ubyte[n];
        fh.seek(offset);
        fh.read(buf);
        c.write(encodeChunk(job.ticket, sha, offset, buf));
    }

    private void onAck(Ack a)
    {
        if (pstate != PushState.chunking || a.ticket != job.ticket)
            return;
        final switch (a.status)
        {
        case AckStatus.ok:
            offset = a.offset;
            if (offset >= size)
                sendComplete();
            else
                sendChunk();
            break;
        case AckStatus.offsetMismatch:
            // the receiver's spool is elsewhere than we thought: ask again, resume from there
            plog("hs: offset mismatch at ", offset, " — re-probing");
            pstate = PushState.probing;
            sendControl(req(idProbe, "library.import", [
                "name": job.meta["name"], "sha256": job.meta["sha256"], "probe": JSONValue(true)]));
            break;
        case AckStatus.hashMismatch:
            plog("hs: computer discarded a corrupt spool — restarting ", getStr(job.meta, "name"));
            offset = 0;
            sendChunk();
            break;
        }
    }

    private void sendComplete()
    {
        pstate = PushState.completing;
        auto p = job.meta;
        p["complete"] = JSONValue(true);
        sendControl(req(idComplete, "library.import", p.object));
    }

    private void onCompleteReply(JSONValue reply)
    {
        if (pstate != PushState.completing)
            return;
        if ("result" in reply.object)
            finishPush(true, null);
        else
            finishPush(false, "error" in reply.object ? reply["error"].toString() : reply.toString());
    }

    /// Tells the Qt side (P2pBridge.drain → LocalBridge.finish) how the push ended.
    private void finishPush(bool ok, string error)
    {
        closeFile();
        pstate = PushState.none;
        host.link.deliver(JSONValue([
            "pushDone": JSONValue(job.ticket),
            "ok": JSONValue(ok),
            "error": error.length ? JSONValue(error) : JSONValue(null),
        ]).toString());
        job = PushJob.init;
    }

    private void closeFile() nothrow
    {
        if (!fhOpen)
            return;
        fhOpen = false;
        try fh.close(); catch (Exception) {}
    }

    // ---- teardown -----------------------------------------------------------------------

    private void onClose() nothrow
    {
        fail("connection closed");
    }

    private void fail(string why) nothrow
    {
        if (done)
            return;
        done = true;
        try
        {
            if (pstate != PushState.none)
                finishPush(false, why);
            deliverLink(false, null, why);
        }
        catch (Exception) {}
        if (!closed)
        {
            closed = true;
            c.closeGracefully(1.seconds);
        }
    }

    private void deliverLink(bool up, string peer, string error)
    {
        JSONValue d = ["up": JSONValue(up)];
        d["peer"] = peer.length ? JSONValue(peer) : JSONValue(null);
        d["error"] = error.length ? JSONValue(error) : JSONValue(null);
        host.link.deliver(JSONValue(["event": JSONValue("p2p.link"), "data": d]).toString());
    }

    // ---- helpers ------------------------------------------------------------------------

    private void sendControl(string line) nothrow
    {
        // encodeControl enforces the frame cap; a control line that large is a bug, not a
        // reason to take the session down — log it and drop that one message.
        try
            c.write(encodeControl(line));
        catch (Exception e)
        {
            try plog("hs: control frame dropped: ", e.msg); catch (Exception) {}
        }
    }

    private void sendControl(JSONValue j) nothrow
    {
        try sendControl(j.toString()); catch (Exception) {}
    }

    private static JSONValue req(long id, string method, JSONValue[string] params)
    {
        JSONValue r = ["id": JSONValue(id), "method": JSONValue(method)];
        r["params"] = params is null ? JSONValue.emptyObject : JSONValue(params);
        return r;
    }

    private static string getStr(JSONValue j, string key)
    {
        return j.type == JSONType.object && key in j.object && j[key].type == JSONType.string ? j[key].str : null;
    }

    private static string fourDigitCode()
    {
        import std.random : uniform;
        import std.format : format;
        return format("%04d", uniform(0, 10_000));
    }

    private static string hex(const(ubyte)[] b)
    {
        import std.digest : toHexString, LetterCase;
        return toHexString!(LetterCase.lower)(b).idup;
    }

    private static bool hexToBytes(string h, ref ubyte[32] out_)
    {
        import std.ascii : isHexDigit;
        import std.conv : to;
        if (h.length != 64)
            return false;
        foreach (i; 0 .. 32)
        {
            if (!isHexDigit(h[2 * i]) || !isHexDigit(h[2 * i + 1]))
                return false;
            out_[i] = h[2 * i .. 2 * i + 2].to!ubyte(16);
        }
        return true;
    }
}
