// LocalBridge — the phone's library behind the method names of docs/ipc.md,
// merged with the computer's when one is paired.
//
// The phone's own photos (PhoneIndex) and the computer's (over TcpBridge)
// form one timeline: pages are k-way merged by capture time, a computer
// photo that is the same file as a local one (same name and size — the way
// "Send to computer" copies it) is shown once, as the local one. Computer
// items carry ids offset by `remoteBase`, their thumbnails are fetched as
// data: URLs, and the open photo's bytes come through `photo.file`. The
// computer's albums are listed and browsed as they are. Without a computer
// (or offline) everything still works on the phone alone.
module photowagon.mobile.localbridge;

import photowagon.mobile.plog : plog, timed, useCrashStack;
import photowagon.core.library.calendar : fileUrl;

import std.algorithm : min, canFind;
import std.base64 : Base64;
import std.conv : to;
import std.file : read, exists, readText, write, mkdirRecurse;
import std.json;
import core.thread : Thread;
import core.time : MonoTime, minutes, msecs, seconds;
import std.path : baseName, buildPath, dirName;
import std.stdio : writeln, stdout;

import qt.quick.qtimer;
import cppq = qt.quick.qobject;

import photowagon.core.library.calendar : isoTime, localDate;
import photowagon.mobile.phoneindex : PhoneIndex, PhoneFilter, PhonePhoto, DetectedFace, facesToJson;
import photowagon.mobile.tcpbridge : TcpBridge;
import photowagon.ui.transport : Bridge, ResultCb;

/// Computer photo ids are shifted by this in what the UI sees.
enum long remoteBase = 1_000_000_000L;

version (Android)
{
    // mobile/jni/videothumb.c — hands a file path to Android's ACTION_SEND share sheet.
}

final class LocalBridge : Bridge
{
    private PhoneIndex index;
    private Bridge computer;
    private bool up;
    private QTimer rescan;        // until the permission lands, keep trying
    private int rescanTries;
    private bool permissionAsked;
    // ---- sync: every photo not on the computer yet goes there, in the background,
    // whenever a computer is connected. The queue is the index itself (sent / tries
    // per photo, saved after every step), so a crash or a kill loses nothing: the next
    // launch resumes. Reading + hashing + base64 of a file happens on a thread; the
    // computer is asked by hash first and the bytes go only when it lacks them.
    private bool autoSync;             // persisted: files/settings/autosync
    private bool manualRun;            // "Send all now": one run to the end, auto-sync untouched
    private string autoSyncFile;
    // Held sending: paused by the user (persisted: settings/sync-paused), or data saver on
    // (settings/data-saver) while the network is metered — which CoreService reads from
    // Android's ConnectivityManager into settings/metered ("1"/"0"). The photo in flight
    // finishes; the next one waits. Explicit one-photo actions (Send, Add to album) still go.
    private bool syncPaused, dataSaver, metered;
    private string pausedFile, dataSaverFile, meteredFile;
    private QTimer meteredPoll;
    private string syncStatusFile;     // files/settings/sync-status, read by the Java notifier
    private long[] sendQueue;         // the WANTED photos (negotiated), waiting for their bytes
    private long sent, sendTotal, sendFailed, skipped, declined;
    private long lastRunFailed;   // failures of the last finished run, for the service's summary
    private int manualUploads;    // single-photo Sends in flight (busy, for the notification)
    private bool sending;              // the legacy (base64) send of one photo is under way
    // Pushes in flight on the raw-bytes pipe, by photo id → the content (hash) being sent and
    // the attempt's number (a late answer to an attempt that timed out or was dropped with the
    // link finds a different number and is ignored). Several at once: one photo at a time
    // idled the link through every photo's fixed costs (stream + manifest round trips, the
    // computer landing the file) — measured ~160 ms per photo against ~180 ms of transfer on
    // loopback, "less than half the speed" on the phone's Wi-Fi.
    private struct Upload { string hash; long attempt; }
    private Upload[long] uploads;
    private long uploadAttempts;
    private enum sendWindow = 3;
    private bool busySending() const { return sending || uploads.length > 0; }
    private bool negotiating;         // a library.offer round is in flight
    private QTimer prepPoll;           // watches the preparation thread
    private shared(Prepared)* inflight;
    private long nextTicket = 1;      // blob-pipe ticket, paired with library.import
    private string lastSyncError;

    // Sync negotiation: the phone offers a batch of hashes, the computer answers which it
    // has and which it refuses, and only the rest are sent. Hashes are computed off-thread.
    private enum offerBatchN = 512;   // one negotiation covers up to 512 photos
    private long[] pendingOfferIds;   // the whole batch being negotiated
    private long[] pendingHashIds;    // the subset of it being hashed right now
    private shared(HashBatch)* hashing;
    private QTimer hashPoll;

    private static struct HashBatch
    {
        shared(string)[] hashes;   // parallel to pendingHashIds; "" on a read failure
        shared(long)[] sizes;      // the sizes they were computed for
        shared(string)[] pieces;   // their piece hashes (base64), same order
        shared(string)[] fps;      // their fingerprints, same order
        bool done;
    }

    private static struct Prepared
    {
        long id;
        string name;
        string takenAt;
        long mtimeMs;
        string hash;         // sha256 of the bytes actually read (and sent)
        string knownHash;    // the hash the photo had when it was offered ("" = none yet)
        string paramsJson;   // the whole library.import params, serialised on the worker
        string facesJson;    // pre-serialised "faces" array (on the Qt thread), spliced in below
        string error;
        bool done;
    }

    // A sync request that gets no answer: the computer or the link is stuck. The
    // probe is tiny; the upload can be 15 MB over a slow Wi-Fi.
    private enum probeTimeoutMs = 45_000;
    private enum uploadTimeoutMs = 300_000;
    private QTimer syncDeadline;
    private long syncRequestSeq;   // a late answer to an abandoned request is ignored

    // ---- merged paging state --------------------------------------------------------
    private JSONValue pageParams;      // the filter of the current listing (no offset/limit)
    private bool refreshing;           // this listing refreshes one already on screen (library.changed)
    // A refresh's stand-in for a slow computer: its photos the previous listing had served.
    // Answered with the phone's photos read NOW, a refresh neither shrinks the grid nor holds
    // back a photo just taken; the computer's late answer refreshes again.
    private JSONValue[] prevRemote;
    private string prevFilterKey;      // the previous listing's filter, as text (pageParams is later
                                       // shared with the requests, which add offset/limit to it)
    private PhoneFilter localFilter;
    private bool remoteOnly;           // album / person / favorites: the phone has no such thing
    private long localOff, remoteOff;
    private long remoteTotal = -1;     // -1 = not asked yet
    private bool remoteDone;
    private JSONValue[] localBuf, remoteBuf;
    private JSONValue[] served;        // everything handed out so far, merged order
    private bool listing;              // a listing was started (served is meaningful)

    // Page operations run one at a time, in order (docs/phone-core-service.md, "Sessions and
    // state"). A new listing (offset 0) or a new UI session supersedes whatever is pending:
    // those answer with an error at once — never left hanging — and a late computer reply
    // for a superseded operation mutates nothing. pageGen counts listings (and sessions).
    private final class PageOp
    {
        ResultCb cb;
        bool done;
    }
    private struct QueuedPage
    {
        JSONValue params;
        ResultCb cb;
        bool neighbours;   // photo.neighbours: may page further until it finds the photo
        bool search;       // search.combined: a fixed result that becomes the listing
        bool skeleton;     // library.skeleton: the whole listing at once
    }
    private QueuedPage[] pageQueue;
    private PageOp curOp;
    private long pageGen, sessionGen;
    private QTimer pageDeadline;       // a computer that does not answer a page in time is skipped
    private void delegate() onPageDeadline;
    private enum pageDeadlineMs = 20_000;
    private enum firstPageWaitMs = 2_500;   // the grid's first page: the phone's photos show by then
    private MonoTime lastLateRefresh;
// the computer's first page came after firstPageWaitMs: the next first pages give it the
// long wait (a slow computer's answer would otherwise be cut off every time); cleared when a
// first page answers in time
private bool slowComputer;
    private enum neighboursMaxServed = 100_000;  // how far photo.neighbours pages to find a photo
    private bool[string] localKeys;    // "name|size" of local photos, for dedupe
    private bool[string] localHashes;  // a known content hash survives metadata size changes
    private long dupes;
    private string[long] thumbCache;   // remote id → thumb URL (a file:// on disk, or a data: URL fallback)
    private string remoteThumbDir;     // desktop thumbs cached as JPEG files (EGL file→texture, low RAM, survive drops)
    private string remoteFileDir;      // originals downloaded from the computer (photo.download)
    private string previewDir;         // the viewer's 2048 px previews of computer photos (a few, recent)
    private enum keepPreviews = 24;
    private bool closing;              // shutdown(): no new work, no more events
    private bool testDownloadDone;     // PW_TEST_DOWNLOAD fired once

    private Thread owner;   // the Qt thread: paging state and events live here

    this(PhoneIndex index, Bridge computer, string settingsDir = null)
    {
        owner = Thread.getThis();
        this.index = index;
        this.computer = computer;
        if (settingsDir.length)
        {
            autoSyncFile = buildPath(settingsDir, "autosync");
            syncStatusFile = buildPath(settingsDir, "sync-status");
            autoSync = autoSyncFile.exists;
            pausedFile = buildPath(settingsDir, "sync-paused");
            dataSaverFile = buildPath(settingsDir, "data-saver");
            meteredFile = buildPath(settingsDir, "metered");
            syncPaused = pausedFile.exists;
            dataSaver = dataSaverFile.exists;
            metered = readMetered();
            // Desktop thumbnails land here as JPEG files (a sibling of settings/), so the
            // grid loads them as file:// textures (EGL) instead of base64 in memory, and
            // they survive the p2p link dropping.
            remoteThumbDir = buildPath(dirName(settingsDir), "remote-thumbs");
            remoteFileDir = buildPath(dirName(settingsDir), "remote-files");   // downloaded originals
            previewDir = buildPath(dirName(settingsDir), "previews");         // the viewer's computer photos
            try
            {
                import photowagon.mobile.atomicfile : sweepTemporaries;

                mkdirRecurse(remoteThumbDir);
                sweepTemporaries(remoteThumbDir);
            }
            catch (Exception)
                remoteThumbDir = null;
            try
            {
                import photowagon.mobile.atomicfile : sweepTemporaries;

                mkdirRecurse(previewDir);
                sweepTemporaries(previewDir);
            }
            catch (Exception)
                previewDir = null;
        }
        prepPoll = new QTimer(cast(cppq.QObject) null);
        prepPoll.setInterval(50);
        prepPoll.connectTimeout(&onPrepared);
        hashPoll = new QTimer(cast(cppq.QObject) null);
        hashPoll.setInterval(50);
        hashPoll.connectTimeout(&onHashed);
        syncDeadline = new QTimer(cast(cppq.QObject) null);
        syncDeadline.setSingleShot(true);
        syncDeadline.connectTimeout(&onSyncTimeout);
        // the network's metered flag follows Android (CoreService writes it): 4G → hold,
        // Wi-Fi → go on, without the user doing anything
        meteredPoll = new QTimer(cast(cppq.QObject) null);
        meteredPoll.setInterval(3000);
        meteredPoll.connectTimeout({
            immutable m = readMetered();
            if (m == metered)
                return;
            metered = m;
            plog("sync: network is ", m ? "metered" : "not metered", dataSaver ? " (data saver on)" : "");
            if (held())
                holdRun();   // drop the queue now: a push the link loses must not leave it "active"
            else
                { startSync(); pumpFaces(); }   // faces held back meanwhile go too (auto-sync off: startSync does nothing)
        });
        if (meteredFile.length)
            meteredPoll.start();
        index.onChanged = () { emit("library.changed", JSONValue.emptyObject); };
        index.onFacesReady = &pumpFaces;   // a face pass finished: hand over what the computer lacks
        // Background never hurts foreground: while a photo is being pushed to the computer,
        // the indexer's decode slice yields so it can't starve the socket (the video-push
        // drops) or jank the UI. It resumes the instant the push ends.
        index.shouldYield = () => busySending || negotiating;
        index.onProgress = (long done, long total) {
            emit("index.progress", JSONValue([
                "rootId": JSONValue(0), "scanned": JSONValue(done), "imported": JSONValue(done),
                "skipped": JSONValue(0), "total": JSONValue(total)
            ]));
        };
        index.onDone = (long added, long removed) {
            emit("index.done", JSONValue([
                "rootId": JSONValue(0), "imported": JSONValue(added), "skipped": JSONValue(0),
                "removed": JSONValue(removed), "seconds": JSONValue(0)
            ]));
            startSync();       // new photos: off they go
        };
        computer.onPairingChanged = () { emitLink(computer.connected); };
        computer.onConnected = (bool ok) {
            emitLink(ok);
            emit("library.changed", JSONValue.emptyObject); // the merged timeline changed shape
            if (ok)
            {
                emit("people.changed", JSONValue.emptyObject);   // the open photo's faces, now reachable
                startSync();
                facesApiMissing = false;   // a (re)connection may be another computer, or one with vision now
                pumpFaces();
                // PW_TEST_DOWNLOAD=<computer photo id>: the desktop test build downloads that
                // original once the link is up and logs the result (the resume-test hook,
                // like PW_SHOT_SEND for uploads); no UI needed.
                import std.process : environment;
                import std.conv : to;

                immutable td = environment.get("PW_TEST_DOWNLOAD", "");
                if (td.length && !testDownloadDone)
                {
                    testDownloadDone = true;
                    request("photo.download", JSONValue(["id": JSONValue(remoteBase + td.to!long)]), (r, e) {
                        plog("test download: ", e.type == JSONType.null_ ? "ok " ~ r.toString() : "failed " ~ e.toString());
                    });
                }
            }
            else
            {
                // whatever was in flight is lost with the link; the next connection starts clean
                syncDeadline.stop();
                syncRequestSeq++;
                sending = false;
                uploads = null;   // their answers, if any ever come, belong to the dead link
                negotiating = false;
                publishSync();
            }
        };
        computer.onEvent = (string ev, JSONValue data) {
            if (ev == "library.changed" || ev == "index.done")
                emit("library.changed", JSONValue.emptyObject);
            else if (ev == "people.changed" || ev == "faces.done")
                emit(ev, data);   // the UI reloads people; a face named on the computer shows here
            else if (ev == "pairing.code")
                emit(ev, data);   // the first-pairing code to show, so the desktop can authorize
        };
    }

    override void start()
    {
        computer.start();
        up = true;
        if (onConnected)
            onConnected(true);
        rescan = new QTimer(cast(cppq.QObject) null);
        rescan.setInterval(2000);
        rescan.connectTimeout(&retryScan);
        index.onScanned = (size_t found) {
            if (found > 0)
                setPermissionNeeded(false);   // readable now (granted meanwhile)
            if (found > 0 || rescanTries > 60)
            {
                rescan.stop();
                return;
            }
            // nothing readable: the permission is missing. Asking is the UI's job (it needs the
            // Activity, which is not in the core's process once the core moves out): report it
            // (core.permission), and keep looking for a while.
            if (!permissionAsked)
            {
                permissionAsked = true;
                setPermissionNeeded(true);
            }
            rescan.start();
        };
        index.scan();
    }

    /// While the permission dialog is up, look again every 2 s.
    private void retryScan()
    {
        rescanTries++;
        index.scan();
    }

    override bool connected() const { return up; }
    override bool remote() const { return false; }
    override string endpoint() const { return computer.endpoint(); }
    override void setEndpoint(string host, ushort port)
    {
        facesApiMissing = false;   // another computer: ask it afresh
        facesRetryAt = null;
        originals = null;          // its photo ids name other photos
        remoteSkel = null;         // (so do its listings)
        remoteSkelSig = null;
        remoteSkelOrder = null;
        computerNoSkeleton = false;
        thumbQueue = null;
        endpointGen++;
        computer.setEndpoint(host, port);
        emitLink(computer.connected);   // paired now (or not): the UI shows it at once
    }

    private void emitLink(bool up)
    {
        // a batch in flight on a link that went down may never report back: start over
        if (!up)
        {
            thumbGen++;
            thumbBatches = 0;
            thumbInFlight = null;
        }
        else
            pumpThumbs();
        emit("computer.link", JSONValue(["connected": JSONValue(up), "endpoint": JSONValue(computer.endpoint),
            "paired": JSONValue(computer.paired)]));
    }

    private void emit(string ev, JSONValue data)
    {
        if (closing)
            return;
        remember(ev, data);
        if (onEvent)
            onEvent(ev, data);
    }

    // ---- the core's state, for a UI that (re)connects ---------------------------------------
    // Everything the UI would have learned from events it missed: kept as the events go out,
    // served as one snapshot (core.state) before the UI is told the core is up
    // (docs/phone-core-service.md, "Sessions and state").
    private bool indexActive;
    private JSONValue lastProgress;
    private string pendingPairingCode;
    private bool permissionNeeded;

    private void remember(string ev, JSONValue data)
    {
        switch (ev)
        {
        case "index.progress":
            indexActive = true;
            lastProgress = data;
            break;
        case "index.done":
            indexActive = false;
            break;
        case "pairing.code":
            pendingPairingCode = data.type == JSONType.object && "done" in data ? null
                : data.type == JSONType.object && "code" in data && data["code"].type == JSONType.string ? data["code"].str : null;
            break;
        default:
            break;
        }
    }

    /// The snapshot a (re)connecting UI applies before it is told the core is up.
    JSONValue coreState()
    {
        JSONValue ix = ["active": JSONValue(indexActive)];
        if (indexActive && lastProgress.type == JSONType.object)
            foreach (k; ["imported", "skipped", "total"])
                if (k in lastProgress)
                    ix[k] = lastProgress[k];
        return JSONValue([
            "endpoint": JSONValue(computer.endpoint),
            "computer": JSONValue(["connected": JSONValue(computer.connected), "endpoint": JSONValue(computer.endpoint),
                "paired": JSONValue(computer.paired)]),
            "sync": syncStatus(),
            "indexing": ix,
            "pairingCode": pendingPairingCode.length ? JSONValue(pendingPairingCode) : JSONValue(null),
            "permissionNeeded": JSONValue(permissionNeeded),
        ]);
    }

    // The photo permission's state, as an event: a snapshot can go out before the first scan
    // knows, so each flip is sent on its own (the UI asks when it turns true).
    private void setPermissionNeeded(bool needed)
    {
        if (needed == permissionNeeded)
            return;
        permissionNeeded = needed;
        emit("core.permission", JSONValue(["needed": JSONValue(needed)]));
    }

    private static JSONValue error(string code, string message)
    {
        return JSONValue(["code": JSONValue(code), "message": JSONValue(message)]);
    }

    private static long num(JSONValue p, string key, long def = 0)
    {
        if (p.type != JSONType.object) return def;
        auto v = key in p;
        return v && v.type == JSONType.integer ? v.integer : def;
    }

    private static bool flag(JSONValue p, string key)
    {
        if (p.type != JSONType.object) return false;
        auto v = key in p;
        return v && v.type == JSONType.true_;
    }

    private static PhoneFilter filterOf(JSONValue p)
    {
        PhoneFilter f;
        f.year = cast(int) num(p, "year");
        f.month = cast(int) num(p, "month");
        f.day = cast(int) num(p, "day");
        f.kind = kindOf(p);
        f.hideSent = flag(p, "hideSent");
        return f;
    }

    /// The collection asked for: "video" or "screenshot". The UI's default "photo" (the
    /// desktop timeline's "photographs only") is not one: the phone's timeline has always
    /// shown its videos and screenshots, and Favorites must not lose starred ones.
    private static string kindOf(JSONValue p)
    {
        if (p.type != JSONType.object || "kind" !in p || p["kind"].type != JSONType.string)
            return "";
        immutable k = p["kind"].str;
        return k == "video" || k == "screenshot" ? k : "";
    }

    // ---- requests -------------------------------------------------------------------

    override void request(string method, JSONValue params, ResultCb cb)
    {
        if (closing)
        {
            cb(JSONValue(null), error("shutting_down", "the phone core is shutting down"));
            return;
        }
        try
        {
            switch (method)
            {
            case "library.page":    enqueuePage(params, cb, false); return;
            // the whole listing at once (the grid lays it all out, thumbnails load on screen)
            case "library.skeleton":
                supersedePaging("superseded", "a new listing started", [QueuedPage(params, cb, false, false, true)]);
                pumpPages();
                return;
            // the grid's visible tiles whose computer thumbnail is not here yet
            case "library.wantThumbs": wantThumbs(params); cb(JSONValue.emptyObject, JSONValue(null)); return;
            case "photo.neighbours": enqueuePage(params, cb, true); return;
            case "search.combined": supersedePaging("superseded", "a new listing started",
                    [QueuedPage(params, cb, false, true)]);
                pumpPages();
                return;
            case "library.dates":   timed("library.dates", 30, { dates(params, cb); }); return;
            case "photo.get":       get(num(params, "id"), cb); return;
            case "photo.upload":    upload(num(params, "id"), cb); return;
            case "photo.download":  download(num(params, "id"), cb); return;
            case "photo.region":    region(params, cb); return;
            case "photo.share":     share(num(params, "id"), cb); return;
            case "core.state":      cb(coreState(), JSONValue(null)); return;
            case "album.list":      albums(cb); return;
            case "photo.faces":     faces(num(params, "id"), cb); return;
            case "people.list":     people(cb); return;
            case "face.candidates": { auto q = params; q["inline"] = true; forward(method, q, cb); return; }
            // names, merges and corrections: the computer keeps the face database, both ways
            case "face.setPerson": case "face.delete": case "people.rename": case "people.merge":
            case "people.delete": case "people.similar": case "people.setCover": case "people.remove":
                forward(method, params, cb); return;
            // album writes run on the computer (it owns the library); the phone forwards them
            case "album.rename": case "album.delete":
                forward(method, params, cb); return;
            // photo ids are the phone's: the computer's own shifted, the phone's own
            // resolved by hash — and sent first when the computer does not have them yet
            case "album.create": case "album.addPhotos": case "album.removePhotos":
                albumWithPhotos(method, params, cb); return;
            case "photo.shareMany": shareMany(params, cb); return;
            case "library.importedFiles": importedFiles(params, cb); return;
            // Cast runs on the computer (it has the CastService + is on the TV's LAN); the
            // phone is a remote control. Photo ids are rewritten to the computer's own ids.
            case "cast.devices": case "cast.next": case "cast.prev":
            case "cast.pause": case "cast.resume": case "cast.stop":
                forward(method, params, cb); return;
            case "cast.photo":
                {
                    auto q = params;
                    immutable pid = ("id" in q) ? q["id"].integer : 0;
                    if (pid < remoteBase)
                    {
                        cb(JSONValue(null), error("local_only", "cast only photos that are on the computer"));
                        return;
                    }
                    q["id"] = pid - remoteBase;
                    forward(method, q, cb);
                    return;
                }
            default:
                timed(method, 30, { cb(handleSync(method, params), JSONValue(null)); });
            }
        }
        catch (Exception e)
            cb(JSONValue(null), error("internal", e.msg));
    }

    private JSONValue handleSync(string method, JSONValue p)
    {
        switch (method)
        {
        case "daemon.hello":
            return JSONValue([
                "version": JSONValue("0.4.0"), "dataDir": JSONValue("phone"),
                "peerId": JSONValue(null), "addrs": JSONValue(cast(JSONValue[]) []), "phone": JSONValue(true),
                "computer": JSONValue(computer.endpoint), "computerConnected": JSONValue(computer.connected)
            ]);
        case "library.roots":
            {
                JSONValue[] roots;
                long id;
                foreach (r; index.rootPaths)
                    roots ~= JSONValue(["id": JSONValue(++id), "path": JSONValue(r), "photos": JSONValue(index.length)]);
                return JSONValue(["roots": JSONValue(roots)]);
            }
        case "library.rescan":
            index.scan();
            return JSONValue.emptyObject;
        case "p2p.status":
            return JSONValue(["peerId": JSONValue(null), "addrs": JSONValue(cast(JSONValue[]) []), "peers": JSONValue(cast(JSONValue[]) []), "off": JSONValue(true)]);
        case "library.pauseSync":     // {paused}: hold sending (persisted) / go on
            {
                syncPaused = p.type == JSONType.object && "paused" in p && p["paused"].type == JSONType.true_;
                setFlagFile(pausedFile, syncPaused);
                plog("sync: ", syncPaused ? "paused by the user" : "resumed by the user");
                if (held())
                    holdRun();
                else
                    { startSync(); pumpFaces(); }   // faces held back meanwhile go too (auto-sync off: startSync does nothing)
                return syncStatus();
            }
        case "library.dataSaver":     // {on}: nothing goes over a metered network
            {
                dataSaver = p.type == JSONType.object && "on" in p && p["on"].type == JSONType.true_;
                setFlagFile(dataSaverFile, dataSaver);
                if (held())
                    holdRun();
                else
                    { startSync(); pumpFaces(); }   // faces held back meanwhile go too (auto-sync off: startSync does nothing)
                return syncStatus();
            }
        case "library.sendAll":       // one run now; the automatic-sync preference stays as it is
            {
                // an explicit "send now" is also a "go on": it ends a pause (data saver still
                // holds it on a metered network — that is what the switch is for)
                if (syncPaused)
                {
                    syncPaused = false;
                    setFlagFile(pausedFile, false);
                }
                manualRun = true;
                index.resetTries();
                immutable n = index.unsentCount();
                publishSync();   // "manual" out before hashing / negotiating: CoreService holds the run
                startSync();
                return JSONValue(["queued": JSONValue(n)]);
            }
        case "library.autoSync":      // {on}
            {
                setAutoSync(p.type == JSONType.object && "on" in p && p["on"].type == JSONType.true_);
                if (autoSync) startSync();
                else { sendQueue.length = 0;
            offeredHash = null; publishSync(); }
                return syncStatus();
            }
        case "library.syncStatus":
            return syncStatus();
        default:
            throw new Exception("not available on the phone: " ~ method);
        }
    }

    // ---- the merged timeline -----------------------------------------------------------

    /// A new UI session (a (re)connection): whatever paging the previous one had pending is
    /// answered with an error, and its late computer replies change nothing.
    void beginSession()
    {
        sessionGen++;
        supersedePaging("session_superseded", "a new UI session started");
    }

    private void enqueuePage(JSONValue p, ResultCb cb, bool neighbours)
    {
        // a new listing makes everything pending about the old one moot
        if (!neighbours && num(p, "offset") == 0)
            supersedePaging("superseded", "a new listing started", [QueuedPage(p, cb, neighbours)]);
        else
            pageQueue ~= QueuedPage(p, cb, neighbours);
        pumpPages();
    }

    /// Cut everything pending short. The replacement (if any) is in the queue BEFORE any
    /// victim is answered: a victim's callback that starts yet another listing then
    /// supersedes the replacement, not the other way round.
    private void supersedePaging(string code, string why, QueuedPage[] replacement = null)
    {
        pageGen++;
        auto victims = pageQueue;
        auto cur = curOp;
        pageQueue = replacement.dup;
        curOp = null;
        if (pageDeadline !is null)
            pageDeadline.stop();
        onPageDeadline = null;
        immutable err = error(code, why);
        if (cur !is null && !cur.done)
        {
            cur.done = true;
            answerQuietly(cur.cb, JSONValue(null), err);
        }
        foreach (q; victims)
            answerQuietly(q.cb, JSONValue(null), err);
    }

    // a failing answer must not stall or skip the ones after it
    private static void answerQuietly(ResultCb cb, JSONValue r, JSONValue e)
    {
        try
            cb(r, e);
        catch (Exception ex)
            plog("paging: an answer's callback failed: ", ex.msg);
    }

    private void pumpPages()
    {
        while (curOp is null && pageQueue.length)
        {
            auto q = pageQueue[0];
            pageQueue = pageQueue[1 .. $];
            auto op = new PageOp;
            op.cb = q.cb;
            curOp = op;
            try
            {
                if (q.skeleton)
                    skeletonOp(q.params, op);
                else if (q.search)
                    search(q.params, op);
                else if (q.neighbours)
                    neighbours(q.params, op);
                else
                    page(q.params, op);
            }
            catch (Exception e)
                finishOp(op, JSONValue(null), error("internal", e.msg));
        }
    }

    /// Answer an operation exactly once; the next queued one runs after it.
    private void finishOp(PageOp op, JSONValue r, JSONValue e)
    {
        if (op.done)
            return;
        op.done = true;
        if (curOp is op)
        {
            curOp = null;
            if (pageDeadline !is null)
                pageDeadline.stop();
            onPageDeadline = null;
        }
        answerQuietly(op.cb, r, e);
        pumpPages();
    }

    private void page(JSONValue p, PageOp op)
    {
        immutable offset = num(p, "offset");
        immutable limit = cast(size_t) num(p, "limit", 60);
        if (offset == 0 || !listing)
            resetPaging(p);
        // a stretch already handed out (a UI rebuilding its list, a reply it lost): the same
        // items again, not the next ones
        if (offset > 0 && offset < served.length)
        {
            immutable long end = offset + limit < served.length ? offset + limit : served.length;
            auto items = served[cast(size_t) offset .. cast(size_t) end].dup;
            immutable total = currentTotal();
            withRemoteThumbs(items, () {
                finishOp(op, JSONValue(["total": JSONValue(total), "offset": JSONValue(end), "items": JSONValue(items)]), JSONValue(null));
            });
            return;
        }
        fillSome(limit, op, (JSONValue[] out_) {
            immutable total = currentTotal();
            immutable long end = served.length;   // captured now, not read when the answer goes out
            withRemoteThumbs(out_, () {
                finishOp(op, JSONValue(["total": JSONValue(total), "offset": JSONValue(end), "items": JSONValue(out_)]), JSONValue(null));
            });
        });
    }

    // ---- the whole listing at once --------------------------------------------------------

    // the computer's lean listing per filter, the last one it gave: answered from at once,
    // brought up to date in the background (a change then refreshes the grid)
    private JSONValue[][string] remoteSkel;
    private string[string] remoteSkelSig;   // what the computer said, as it said it (a change test)
    private string[] remoteSkelOrder;       // oldest first: at most skelCacheMax listings kept
    private enum skelCacheMax = 4;
    private bool computerNoSkeleton;        // an older computer: the UI pages instead

    /// library.skeleton: every photo of the listing, the phone's own and the computer's
    /// (its copies of the phone's photos left out), newest first — lean items for the grid
    /// to lay out whole. The computer's part comes from its last answer when there is one
    /// (instant), else the phone waits for it up to firstPageWaitMs and then shows its own
    /// photos; the computer's late answer is kept and refreshes the listing (from it, then).
    private void skeletonOp(JSONValue p, PageOp op)
    {
        if (computerNoSkeleton && computer.connected)
        {
            finishOp(op, JSONValue(null), error("unknown_method", "the computer has no library.skeleton"));
            return;
        }
        resetPaging(p);
        immutable key = pageParams.toString();
        immutable gen = pageGen;
        JSONValue[] local;
        if (!remoteOnly)
            foreach (ref ph; index.page(localFilter, 0, long.max))
                local ~= ph.toJson();
        bool answered;
        void answer(JSONValue[] remote)
        {
            answered = true;
            auto merged = mergeWhole(local, remote);
            served = merged;
            localOff = cast(long) local.length;
            remoteDone = true;
            finishOp(op, JSONValue(["total": JSONValue(merged.length), "items": JSONValue(merged)]), JSONValue(null));
        }
        if (!computer.connected || onlyUnsent())
        {
            answer(null);   // the phone's photos (as the paged listing does offline)
            return;
        }
        if (auto cached = key in remoteSkel)
            answer(*cached);
        else
            armPageDeadline(() {
                if (answered || op.done || curOp !is op)
                    return;
                plog("skeleton: the computer did not answer in ", firstPageWaitMs, " ms — the phone's photos now");
                answer(null);
            }, firstPageWaitMs);
        JSONValue params = pageParams;
        params["hashes"] = true;
        immutable asked = MonoTime.currTime;
        immutable eg = endpointGen;
        computer.request("library.skeleton", params, (r, e) {
            if (eg != endpointGen)
                return;   // another computer since: this answer is about the old one's photos
            if (e.type != JSONType.null_)
            {
                immutable unknown = e.type == JSONType.object && "code" in e && e["code"].type == JSONType.string
                    && e["code"].str == "unknown_method";
                if (unknown && !computerNoSkeleton)
                {
                    computerNoSkeleton = true;
                    if (answered)   // it went out with the phone's photos only: page it instead
                    {
                        emit("library.changed", JSONValue.emptyObject);
                        return;
                    }
                }
                if (answered || op.done || curOp !is op)
                    return;
                pageDeadline.stop();
                onPageDeadline = null;
                // a computer from before library.skeleton: the UI pages instead
                if (e.type == JSONType.object && "code" in e && e["code"].type == JSONType.string && e["code"].str == "unknown_method")
                {
                    answered = true;
                    finishOp(op, JSONValue(null), error("unknown_method", "the computer has no library.skeleton"));
                    return;
                }
                answer(null);
                return;
            }
            immutable sig = r["items"].toString();
            immutable changed = (key in remoteSkelSig) is null || remoteSkelSig[key] != sig;
            JSONValue[] remote;
            foreach (it; r["items"].array)
                remote ~= toPhoneItem(it);
            if ((key in remoteSkel) is null)
            {
                remoteSkelOrder ~= key;
                if (remoteSkelOrder.length > skelCacheMax)
                {
                    remoteSkel.remove(remoteSkelOrder[0]);
                    remoteSkelSig.remove(remoteSkelOrder[0]);
                    remoteSkelOrder = remoteSkelOrder[1 .. $];
                }
            }
            remoteSkel[key] = remote;
            remoteSkelSig[key] = sig;
            plog("skeleton: ", remote.length, " of the computer's in ", (MonoTime.currTime - asked).total!"msecs", " ms",
                answered ? (changed ? " (changed since: refreshing)" : " (as cached)") : "");
            if (!answered && !op.done && curOp is op)
            {
                pageDeadline.stop();
                onPageDeadline = null;
                answer(remote);
                return;
            }
            // the listing went out without it (late) or from an older copy of it: refresh, the
            // next listing takes it from the cache at once
            if (changed && gen == pageGen)
                emit("library.changed", JSONValue.emptyObject);
        });
    }

    /// The phone's photos and the computer's, newest first, the computer's copies of the
    /// phone's own photos left out (by content hash, or name and size); thumbnails the phone
    /// already has filled in.
    private JSONValue[] mergeWhole(JSONValue[] local, JSONValue[] remote)
    {
        bool[string] localH16;
        foreach (h, _; localHashes)
            localH16[h.length > 16 ? h[0 .. 16] : h] = true;
        JSONValue[] rem;
        rem.reserve(remote.length);
        foreach (it; remote)
        {
            if (!remoteOnly)
            {
                immutable h16 = "hash16" in it && it["hash16"].type == JSONType.string ? it["hash16"].str : "";
                immutable key = ("path" in it && it["path"].type == JSONType.string ? it["path"].str.baseName : "")
                    ~ "|" ~ ("size" in it && it["size"].type == JSONType.integer ? it["size"].integer.to!string : "");
                if ((h16.length && h16 in localH16) || key in localKeys)
                    continue;   // the local copy stands for it
            }
            it = JSONValue(it.object.dup);   // (the cached copy stays as the computer gave it)
            immutable rid = it["id"].integer - remoteBase;
            if (auto t = rid in thumbCache)
                it["thumbUrl"] = *t;
            else if (remoteThumbDir.length)
            {
                immutable fp = buildPath(remoteThumbDir, rid.to!string ~ ".jpg");
                if (fp.exists)
                {
                    thumbCache[rid] = fileUrl(fp);
                    it["thumbUrl"] = thumbCache[rid];
                }
            }
            rem ~= it;
        }
        JSONValue[] out_;
        out_.reserve(local.length + rem.length);
        size_t a, b;
        while (a < local.length || b < rem.length)
        {
            immutable takeLocal = b >= rem.length
                || (a < local.length && local[a]["takenTs"].integer >= rem[b]["takenTs"].integer);
            out_ ~= takeLocal ? local[a++] : rem[b++];
        }
        return out_;
    }

    // ---- the computer's thumbnails, for the tiles on screen ------------------------------

    private bool[long] thumbInFlight;   // asked of the computer, not landed yet
    private long[] thumbQueue;          // waiting, the most recently wanted first
    private int thumbBatches;           // batches on the wire (at most thumbBatchMax)
    private enum thumbBatchMax = 3;
    private long thumbGen;              // bumped when the link drops: older batches no longer count
    private int[long] thumbTries;       // failed fetches per photo (given up after thumbTriesMax)
    private enum thumbTriesMax = 2;

    /// {ids: [the phone's ids of computer photos]}: the grid's visible tiles still without a
    /// thumbnail. The most recent ones first (a fast scroll asks for many; the last are the
    /// ones on screen), in batches; each lands on disk and is announced in thumbs.ready.
    private void wantThumbs(JSONValue p)
    {
        if (!computer.connected || p.type != JSONType.object || !("ids" in p) || p["ids"].type != JSONType.array)
            return;
        // the newly wanted go to the front (the last asked are the ones on screen now); none is
        // dropped — a tile that stays on screen does not ask twice
        long[] front;
        bool[long] seen;
        foreach_reverse (v; p["ids"].array)
        {
            if (v.type != JSONType.integer || v.integer < remoteBase)
                continue;
            immutable rid = v.integer - remoteBase;
            if (rid in thumbCache || rid in thumbInFlight || rid in seen)
                continue;
            seen[rid] = true;
            front ~= rid;
        }
        long[] rest;
        foreach (rid; thumbQueue)
            if (rid !in seen)
                rest ~= rid;
        thumbQueue = front ~ rest;
        pumpThumbs();
    }

    private void pumpThumbs()
    {
        enum batch = 24;
        while (thumbBatches < thumbBatchMax && thumbQueue.length && computer.connected)
        {
            JSONValue[] want;
            while (want.length < batch && thumbQueue.length)
            {
                immutable rid = thumbQueue[0];
                thumbQueue = thumbQueue[1 .. $];
                if (rid in thumbCache || rid in thumbInFlight)
                    continue;
                thumbInFlight[rid] = true;
                want ~= JSONValue(rid);
            }
            if (!want.length)
                break;
            thumbBatches++;
            fetchThumbs(want, true, thumbGen);
        }
    }

    /// The photos before and after `id` in the current listing. Pages further (without
    /// answering anyone) until it finds the photo — a viewer re-opened after a reconnect may
    /// show one far past the first page.
    private void neighbours(JSONValue p, PageOp op)
    {
        immutable id = num(p, "id");
        foreach (i, ref it; served)
            if (it["id"].integer == id)
            {
                // the last one served: its successor may be on the next page
                if (i + 1 == served.length && canAdvance())
                {
                    if (served.length < neighboursMaxServed)
                        break;
                    finishOp(op, JSONValue(null), error("search_limit",   // successor unknown
                        "photo at the end of the first " ~ neighboursMaxServed.to!string ~ " of the listing"));
                    return;
                }
                immutable prev = i > 0 ? served[i - 1]["id"].integer : 0;
                immutable next = i + 1 < served.length ? served[i + 1]["id"].integer : 0;
                finishOp(op, JSONValue(["prev": prev ? JSONValue(prev) : JSONValue(null),
                    "next": next ? JSONValue(next) : JSONValue(null)]), JSONValue(null));
                return;
            }
        if (!listing)
        {
            finishOp(op, JSONValue(["prev": JSONValue(null), "next": JSONValue(null)]), JSONValue(null));
            return;
        }
        if (served.length >= neighboursMaxServed)
        {
            // not "no neighbours": the search gave up (the viewer keeps its photo, without arrows)
            finishOp(op, JSONValue(null), error("search_limit",
                "photo not within the first " ~ neighboursMaxServed.to!string ~ " of the listing"));
            return;
        }
        fillSome(200, op, (JSONValue[] out_) {
            if (out_.length == 0)   // the listing is exhausted
            {
                // found as the very last photo (it has no successor), or not in it at all
                long prev;
                if (served.length && served[$ - 1]["id"].integer == id && served.length > 1)
                    prev = served[$ - 2]["id"].integer;
                finishOp(op, JSONValue(["prev": prev ? JSONValue(prev) : JSONValue(null), "next": JSONValue(null)]), JSONValue(null));
            }
            else
                neighbours(p, op);
        });
    }

    private void resetPaging(JSONValue p)
    {
        pageGen++;
        listing = true;
        pageParams = JSONValue.emptyObject;
        foreach (key; ["year", "month", "day", "albumId", "personId", "rootId", "favorites"])
            if (p.type == JSONType.object)
                if (auto v = key in p)
                    pageParams[key] = *v;
        if (kindOf(p).length)
            pageParams["kind"] = kindOf(p);
        localFilter = filterOf(p);
        {
            // same listing refreshed: keep the computer's photos it showed (see prevRemote)
            immutable filterKey = pageParams.toString();
            JSONValue[] kept;
            if (flag(p, "refresh") && filterKey == prevFilterKey)
                foreach (it; served)
                    if (it.type == JSONType.object && "remote" in it && it["remote"].type == JSONType.true_)
                        kept ~= it;
            prevRemote = kept;
            prevFilterKey = filterKey;
        }
        refreshing = flag(p, "refresh");
        remoteOnly = num(p, "albumId") || num(p, "personId") || flag(p, "favorites");
        localOff = remoteOff = 0;
        remoteTotal = -1;
        remoteDone = !computer.connected || onlyUnsent();
        localBuf.length = 0;
        remoteBuf.length = 0;
        served = null;   // a fresh array: slices held by pending thumbnail fetches stay theirs
        dupes = 0;
        localKeys = null;
        localHashes = null;
        // a computer photo is left out for the phone's copy only when that copy is in this
        // listing too (a collection or a date: the phone may classify or date the same
        // picture differently)
        // (the hidden imported photos too: their computer copies must stay out as well)
        auto dedupFilter = localFilter;
        dedupFilter.hideSent = false;
        foreach (ref ph; index.page(dedupFilter, 0, long.max))
        {
            localKeys[ph.path.baseName ~ "|" ~ ph.size.to!string] = true;
            if (ph.hash.length)
                localHashes[ph.hash] = true;
        }
    }

    /// "Hide imported photos": the timeline is then what is left to send — the phone's
    /// photos the computer does not have yet, none of the computer's own. (A collection that
    /// only the computer has — an album, a person, favorites — still shows its photos.)
    private bool onlyUnsent() const
    {
        return localFilter.hideSent && !remoteOnly;
    }

    /// Whether the listing can still grow: buffered items, phone photos not read yet, or a
    /// computer that has more.
    private bool canAdvance()
    {
        return localBuf.length || remoteBuf.length || !remoteDone
            || (!remoteOnly && localOff < index.count(localFilter));
    }

    /// fillPage until it yields something or the listing is exhausted: a computer page that
    /// was all duplicates of phone photos merges to nothing without being the end. Goes on
    /// as long as a round makes progress (a source advanced); every round that asks the
    /// computer continues from its reply, so the stack does not grow with the rounds.
    private void fillSome(size_t limit, PageOp op, void delegate(JSONValue[]) then)
    {
        immutable lo = localOff, ro = remoteOff;
        immutable rd = remoteDone;
        fillPage(limit, op, (JSONValue[] out_) {
            immutable progressed = localOff != lo || remoteOff != ro || remoteDone != rd;
            if (out_.length == 0 && canAdvance() && progressed)
                fillSome(limit, op, then);
            else
                then(out_);
        });
    }

    /// The computer is left out from here on (an error, or no answer in time): what it had
    /// not delivered yet is no longer part of the total.
    private void abandonRemote()
    {
        remoteDone = true;
        if (remoteTotal > remoteOff)
            remoteTotal = remoteOff;
    }

    /// Top up both buffers (asking the computer when needed), merge up to `limit` items onto
    /// `served`, and hand them to `then` — unless `op` was superseded meanwhile.
    private void fillPage(size_t limit, PageOp op, void delegate(JSONValue[]) then)
    {
        // top up the local buffer
        if (!remoteOnly && localBuf.length < limit)
        {
            foreach (ref ph; index.page(localFilter, localOff, limit))
            {
                localBuf ~= ph.toJson();
                localOff++;
            }
        }
        // top up the remote buffer, then merge (asynchronously when the computer is asked)
        if (!remoteDone && remoteBuf.length < limit)
        {
            JSONValue params = pageParams;
            params["offset"] = remoteOff;
            params["limit"] = limit;
            bool settled, timedOut;
            // The FIRST page does not wait long for the computer: the phone's own photos show
            // at once (2.5 s at most) and, when the computer's page turns up late, the listing
            // is refreshed — the grid reconciles it in place. Later pages keep the long wait
            // (the user is scrolling into them; skipping the computer there loses them).
            // (a refresh of the listing on screen waits for the computer: answering with the
            // phone's photos first would shrink the grid under the user and lose the scroll)
            immutable firstPage = remoteOff == 0 && served.length == 0 && !refreshing;
            immutable refreshFirst = remoteOff == 0 && served.length == 0 && refreshing;
            immutable waitMs = (firstPage || (refreshFirst && prevRemote.length)) && !slowComputer
                ? firstPageWaitMs : pageDeadlineMs;
            immutable asked = MonoTime.currTime;
            void merge()
            {
                if ((firstPage || refreshFirst) && !timedOut && MonoTime.currTime - asked < firstPageWaitMs.msecs)
                    slowComputer = false;
                if (firstPage)
                    plog("paging: first page after ", (MonoTime.currTime - asked).total!"msecs", " ms",
                        remoteDone && remoteBuf.length == 0 ? " (the phone's photos only)" : "");
                then(mergeServed(limit));
            }
            // After waitMs this listing goes on without the computer (remoteDone).
            armPageDeadline(() {
                if (settled || op.done || curOp !is op)
                    return;
                settled = true;
                timedOut = true;
                if (refreshFirst && prevRemote.length)
                {
                    // a refresh of the listing on screen: the phone's photos as they are now
                    // (a photo just taken included) beside the computer's the listing already
                    // had — the grid neither shrinks nor waits; the late reply refreshes again
                    plog("paging: the computer did not answer a refresh in ", waitMs,
                        " ms — the phone's photos now, the computer's from before");
                    // (through the same de-duplication as a fresh answer: one of them may have
                    // been downloaded to the phone since, and its local copy now stands for it)
                    remoteBuf = null;
                    foreach (it; prevRemote)
                    {
                        immutable key = ("path" in it && it["path"].type == JSONType.string ? it["path"].str.baseName : "")
                            ~ "|" ~ ("size" in it && it["size"].type == JSONType.integer ? it["size"].integer.to!string : "");
                        immutable hash = "hash" in it && it["hash"].type == JSONType.string ? it["hash"].str : "";
                        if (!remoteOnly && ((hash.length && hash in localHashes) || key in localKeys))
                            continue;
                        remoteBuf ~= it;
                    }
                    remoteOff = remoteTotal = cast(long) remoteBuf.length;
                    remoteDone = true;
                    try
                        merge();
                    catch (Exception ex)
                        finishOp(op, JSONValue(null), error("internal", ex.msg));
                    return;
                }
                if (refreshFirst)
                {
                    // a refresh with nothing of the computer's kept (a listing that had none):
                    // fail it quietly, the UI keeps what it shows, the late reply refreshes again
                    plog("paging: the computer did not answer a refresh in ", waitMs, " ms — keeping the listing on screen");
                    finishOp(op, JSONValue(null), error("refresh_timeout", "the computer did not answer in time"));
                    return;
                }
                plog("paging: the computer did not answer library.page in ", waitMs, " ms — listing without it");
                abandonRemote();
                try
                    merge();
                catch (Exception ex)
                    finishOp(op, JSONValue(null), error("internal", ex.msg));
            }, waitMs);
            testDelayed(() {
                computer.request("library.page", params, (r, e) {
                    // the first page went without the computer and its answer came after all:
                    // refresh the listing so its photos join — that refresh (and the next first
                    // pages) wait the long deadline, so it is not cut off again; at most every
                    // 20 s, so a computer slower than even that cannot keep the listing reloading
                    if (timedOut && (firstPage || refreshFirst) && e.type == JSONType.null_)
                        slowComputer = true;   // the next listings give it the long wait: its data, not a stand-in
                    // (a refresh's late answer counts even when EMPTY: the listing on screen may be
                    // holding photos the computer no longer has)
                    if (timedOut && (firstPage || refreshFirst) && e.type == JSONType.null_ && r.type == JSONType.object
                        && "items" in r && (refreshFirst || r["items"].array.length)
                        && MonoTime.currTime - lastLateRefresh > 20.seconds)
                    {
                        lastLateRefresh = MonoTime.currTime;
                        plog("paging: the computer's first page came late — refreshing the listing");
                        emit("library.changed", JSONValue.emptyObject);
                        return;
                    }
                    // superseded (a new listing or session), timed out, or already answered:
                    // this reply belongs to state that is gone
                    if (settled || op.done || curOp !is op)
                        return;
                    settled = true;
                    pageDeadline.stop();
                    onPageDeadline = null;
                    try
                    {
                        if (e.type != JSONType.null_)
                            abandonRemote();
                        else
                        {
                            remoteTotal = r["total"].integer;
                            auto items = r["items"].array;
                            remoteOff += items.length;
                            if (items.length == 0 || remoteOff >= remoteTotal)
                                remoteDone = true;
                            foreach (it; items)
                            {
                                immutable key = (it["path"].type == JSONType.string ? it["path"].str.baseName : "") ~ "|" ~ it["size"].integer.to!string;
                                immutable hash = "hash" in it && it["hash"].type == JSONType.string ? it["hash"].str : "";
                                if (!remoteOnly && ((hash.length && hash in localHashes) || key in localKeys))
                                {
                                    dupes++;
                                    continue; // the local copy stands for it
                                }
                                remoteBuf ~= toPhoneItem(it);
                            }
                        }
                        merge();
                    }
                    catch (Exception ex)   // a malformed reply: answer, never leave the queue stuck
                    {
                        abandonRemote();
                        finishOp(op, JSONValue(null), error("internal", ex.msg));
                    }
                });
            });
            return;
        }
        then(mergeServed(limit));
    }

    /// Run `dg` if the computer has not answered the current operation within
    /// pageDeadlineMs (finishOp and a new listing disarm it).
    private void armPageDeadline(void delegate() dg, int ms = pageDeadlineMs)
    {
        if (pageDeadline is null)
        {
            pageDeadline = new QTimer(cast(cppq.QObject) null);
            pageDeadline.setSingleShot(true);
            pageDeadline.connectTimeout({
                if (auto d = onPageDeadline)
                {
                    onPageDeadline = null;
                    d();
                }
            });
        }
        onPageDeadline = dg;
        pageDeadline.setInterval(ms);
        pageDeadline.start();
    }

    /// search.combined on the phone. Linked: the computer's blended search (meaning, text in
    /// the pictures, file names) — a match that is also on this phone shows as the phone's
    /// own photo — followed by this phone's file names that match. Offline (or no answer in
    /// time): the phone's file and folder names only, and the answer says so (`scope`). The
    /// result becomes the current listing, so the viewer's arrows walk the results.
    private void search(JSONValue p, PageOp op)
    {
        import std.path : dirName;
        import std.string : strip, toLower, indexOf;

        immutable q = p.type == JSONType.object && "q" in p && p["q"].type == JSONType.string
            ? p["q"].str.strip : "";
        immutable limit = cast(size_t) num(p, "limit", 200);
        resetPaging(JSONValue.emptyObject);
        remoteOnly = true;   // a fixed result: nothing to page further
        remoteDone = true;
        immutable gen = pageGen;

        JSONValue[string] byKey, byHash;   // this phone's photos, for the computer's matches
        JSONValue[] local;                 // this phone's file / folder names that match
        immutable needle = q.toLower;
        foreach (ref ph; index.page(PhoneFilter.init, 0, long.max))
        {
            auto j = ph.toJson();
            byKey[ph.path.baseName ~ "|" ~ ph.size.to!string] = j;
            if (ph.hash.length)
                byHash[ph.hash] = j;
            if (needle.length && (ph.path.dirName.baseName ~ "/" ~ ph.path.baseName).toLower.indexOf(needle) >= 0)
                local ~= j;
        }

        plog("search: ", local.length, " of this phone's ", byKey.length, " photos match by name");
        // scope: where it looked; reason (scope "phone" only): why the computer was not in it
        void answer(JSONValue[] found, string scope_, string reason = "")
        {
            if (op.done || pageGen != gen)
                return;
            bool[long] seen;
            JSONValue[] out_;
            foreach (it; found)
                if (out_.length < limit && it["id"].integer !in seen)
                {
                    seen[it["id"].integer] = true;
                    out_ ~= it;
                }
            served = out_.dup;
            withRemoteThumbs(out_, () {
                immutable n = out_.length;
                finishOp(op, JSONValue(["total": JSONValue(n), "offset": JSONValue(n),
                    "items": JSONValue(out_), "scope": JSONValue(scope_), "reason": JSONValue(reason)]), JSONValue(null));
            });
        }

        if (!computer.connected || q.length == 0)
            return answer(local, "phone", computer.connected ? "" : "offline");
        bool settled;
        armPageDeadline(() {
            if (settled || op.done || curOp !is op)
                return;
            settled = true;
            plog("search: the computer did not answer in ", pageDeadlineMs / 1000, " s — this phone's file names only");
            answer(local, "phone", "timeout");
        });
        computer.request("search.combined", JSONValue(["q": JSONValue(q), "limit": JSONValue(limit)]), (r, e) {
            if (settled || op.done || curOp !is op)
                return;
            settled = true;
            pageDeadline.stop();
            onPageDeadline = null;
            try
            {
                if (e.type != JSONType.null_)
                {
                    plog("search: the computer could not search: ", e.toString());
                    return answer(local, "phone", "failed");
                }
                JSONValue[] found;
                foreach (it; r["items"].array)
                {
                    immutable key = (it["path"].type == JSONType.string ? it["path"].str.baseName : "") ~ "|" ~ it["size"].integer.to!string;
                    immutable hash = "hash" in it && it["hash"].type == JSONType.string ? it["hash"].str : "";
                    if (hash.length && hash in byHash)
                        found ~= byHash[hash];
                    else if (auto l = key in byKey)
                        found ~= *l;
                    else
                        found ~= toPhoneItem(it);
                }
                answer(found ~ local, "computer");
            }
            catch (Exception ex)   // a malformed reply: answer, never leave the queue stuck
                finishOp(op, JSONValue(null), error("internal", ex.msg));
        });
    }

    // PW_TEST_PAGE_DELAY=<max ms>: the computer's page requests go out after a random delay,
    // so their replies arrive late and in any order (the stage-3 paging test); =<ms> for a
    // fixed one (the deadline test); =<ms>@<n> delays only the n-th request (a later page).
    private QTimer[] testTimers;
    private int testRequests;

    private void testDelayed(void delegate() dg)
    {
        import std.process : environment;
        import std.random : uniform;

        import std.string : split;

        auto spec = environment.get("PW_TEST_PAGE_DELAY", "").split("@");
        immutable s = spec.length ? spec[0] : "";
        ++testRequests;
        if (s.length == 0 || (spec.length > 1 && spec[1].to!int != testRequests))
        {
            dg();
            return;
        }
        auto t = new QTimer(cast(cppq.QObject) null);
        t.setSingleShot(true);
        t.setInterval(s[0] == '=' ? s[1 .. $].to!int : uniform(0, s.to!int + 1));
        t.connectTimeout({
            dg();
            import std.algorithm : remove, countUntil;
            immutable at = testTimers.countUntil!(x => x is t);
            if (at >= 0)
                testTimers = testTimers.remove(at);
        });
        testTimers ~= t;
        t.start();
    }

    /// A computer item as the phone shows it: shifted id, marked remote.
    private static JSONValue toPhoneItem(JSONValue it)
    {
        it["id"] = it["id"].integer + remoteBase;
        it["remote"] = true;
        it["sent"] = true;
        it["thumbUrl"] = JSONValue(null); // filled from the computer below
        return it;
    }

    /// Merge up to `limit` items from the two buffers by date onto `served`.
    private JSONValue[] mergeServed(size_t limit)
    {
        JSONValue[] out_;
        while (out_.length < limit && (localBuf.length || remoteBuf.length))
        {
            bool takeLocal;
            if (localBuf.length && remoteBuf.length)
                takeLocal = localBuf[0]["takenTs"].integer >= remoteBuf[0]["takenTs"].integer;
            else
                takeLocal = localBuf.length > 0;
            if (takeLocal)
            {
                out_ ~= localBuf[0];
                localBuf = localBuf[1 .. $];
            }
            else
            {
                out_ ~= remoteBuf[0];
                remoteBuf = remoteBuf[1 .. $];
            }
        }
        // the remote buffer may still be short while the local one is long; that is
        // fine: next page tops both up again
        served ~= out_;
        return out_;
    }

    private long currentTotal()
    {
        long total = remoteOnly ? 0 : index.count(localFilter);
        if (remoteTotal > 0)
            total += remoteTotal - dupes;
        if (total < served.length)
            total = served.length;
        return total;
    }

    /// The viewer's preview of a computer photo as a file:// URL: decoded once, published
    /// atomically under previews/ — the bytes never ride the UI's socket as a multi-megabyte
    /// data: URL. The name carries a digest of the bytes, so a photo changed on the computer
    /// (or another computer's photo with the same id) gets a new URL, never an image Qt
    /// cached for the old one. "" when it cannot be written (the caller shows the thumbnail).
    private string previewUrl(long rid, JSONValue f)
    {
        if (previewDir.length == 0)
            return "";
        try
        {
            import photowagon.mobile.atomicfile : writeAtomic;
            import std.digest : toHexString, LetterCase;
            import std.digest.sha : sha1Of;
            import std.string : startsWith;

            immutable mime = f["mime"].str;
            auto bytes = Base64.decode(f["base64"].str);
            immutable ext = mime.startsWith("image/png") ? ".png" : mime.startsWith("image/webp") ? ".webp" : ".jpg";
            immutable tag = toHexString!(LetterCase.lower)(sha1Of(bytes))[0 .. 12].idup;
            immutable fp = buildPath(previewDir, rid.to!string ~ "-" ~ tag ~ ext);
            if (!fp.exists)
                writeAtomic(fp, bytes);
            else
            {
                import std.datetime.systime : Clock;
                import std.file : setTimes;

                try
                    setTimes(fp, Clock.currTime, Clock.currTime);   // in use again: not old
                catch (Exception)
                {
                }
            }
            prunePreviews();
            return fileUrl(fp);
        }
        catch (Exception e)
        {
            plog("viewer: cannot write the preview: ", e.msg);
            return "";
        }
    }

    // By age, not count: a burst of late replies (photos opened and left quickly) must not
    // delete the one the viewer is about to show. Old ones go; a hard cap bounds the disk.
    private enum previewMaxAgeMinutes = 30;
    private enum previewHardCap = 200;

    private void prunePreviews()
    {
        import std.algorithm : sort;
        import std.datetime.systime : Clock;
        import std.file : dirEntries, SpanMode, remove, DirEntry;
        import core.time : minutes;
        import photowagon.mobile.atomicfile : isTemporary;

        try
        {
            DirEntry[] files;
            foreach (e; dirEntries(previewDir, SpanMode.shallow))
                if (e.isFile && !isTemporary(e.name))
                    files ~= e;
            files.sort!((a, b) => a.timeLastModified > b.timeLastModified);
            immutable cutoff = Clock.currTime - previewMaxAgeMinutes.minutes;
            foreach (i, e; files)
                if (i >= previewHardCap || (i >= keepPreviews && e.timeLastModified < cutoff))
                    remove(e.name);
        }
        catch (Exception)
        {
        }
    }

    /// Stop taking work and stop talking (the first step of the core's shutdown): requests
    /// are refused, events dropped, pending paging answered, the timers that start new work
    /// (rescans, sync deadlines, face retries) stopped. Idempotent.
    void shutdown()
    {
        if (closing)
            return;
        closing = true;   // first: a cancelled caller that asks again is refused, not admitted
        supersedePaging("shutting_down", "the phone core is shutting down");
        foreach (t; [rescan, prepPoll, hashPoll, syncDeadline, pageDeadline, facesRetryTimer, meteredPoll, recheckPoll])
            if (t !is null)
                t.stop();
        onPageDeadline = null;
    }

    /// Fills thumbUrl of remote items in `items` (data: URLs), then calls `done`.
    private void withRemoteThumbs(JSONValue[] items, void delegate() done)
    {
        JSONValue[] want;
        foreach (ref it; items)
        {
            if (it["id"].integer < remoteBase)
                continue;
            immutable rid = it["id"].integer - remoteBase;
            if (auto t = rid in thumbCache)
            {
                it["thumbUrl"] = *t;
                continue;
            }
            // already on disk from a previous fetch? use it, no round-trip over the link.
            if (remoteThumbDir.length)
            {
                immutable fp = buildPath(remoteThumbDir, rid.to!string ~ ".jpg");
                if (fp.exists)
                {
                    immutable url = fileUrl(fp);
                    thumbCache[rid] = url;
                    it["thumbUrl"] = url;
                    continue;
                }
            }
            want ~= JSONValue(rid);
        }
        // Deliver the page NOW, with whatever thumbs are already cached. The remote
        // thumbnails ride the (possibly flaky) computer link as base64 blobs; blocking
        // the grid on that request made the whole timeline hang with no timeout whenever
        // a circuit stalled ("muitíssimo lento"). So never wait on it: fetch the missing
        // ones in the background and, when they land, emit library.changed so the UI
        // reloads and fills them in. A dead/absent link just leaves those cells blank
        // instead of freezing the app.
        done();
        if (want.length == 0 || !computer.connected)
            return;
        // In batches: a whole page's worth in one reply was 10 MB of base64 on the wire
        // (2026-09-21, Waydroid rig), a single frame the phone has to hold and parse at
        // once. A few dozen thumbnails per request keeps every frame small and lets the
        // first ones show while the rest are still coming.
        enum batch = 24;
        for (size_t at = 0; at < want.length; at += batch)
            fetchThumbs(want[at .. (at + batch < want.length ? at + batch : want.length)]);
    }

    /// `queued`: a batch of pumpThumbs (the next ones go out when it lands).
    private void fetchThumbs(JSONValue[] want, bool queued = false, long tgen = 0)
    {
        immutable gen = pageGen;   // the cache outlives a listing; patching `served` may not
        long[] ids;
        foreach (w; want)
            ids ~= w.integer;
        bool got;
        size_t received, rawBytes;
        // Raw JPEG bytes over the piece stream (THUMB op) — no base64 anywhere: each
        // thumbnail is written straight to disk and the grid loads it as a file:// texture
        // (EGL, off the GUI thread); it persists across p2p drops. Transports without a
        // byte pipe fall back to the legacy JSON path inside Bridge.fetchThumbs.
        computer.fetchThumbs(ids, (long rid, const(ubyte)[] jpeg) {
            if (jpeg.length == 0 || remoteThumbDir.length == 0)
                return;
            try
            {
                import photowagon.mobile.atomicfile : writeAtomic;

                immutable fp = buildPath(remoteThumbDir, rid.to!string ~ ".jpg");
                writeAtomic(fp, jpeg);   // the grid may already be loading this file
                thumbCache[rid] = fileUrl(fp);
                got = true;
                received++;
                rawBytes += jpeg.length;
            }
            catch (Exception)
            {
            }
        }, () {
            plog("thumbs: ", received, "/", ids.length, " via pieces, ", rawBytes, " bytes raw (no base64)");
            if (Thread.getThis() !is owner)
                plog("BUG: thumbnail batch completed off the Qt thread");
            // only the queued batch that set the marks clears them (a legacy page fetch sets none;
            // a batch from before the link dropped had its marks cleared already, and a newer
            // batch's may stand in their place)
            if (queued && tgen == thumbGen)
                foreach (rid; ids)
                    thumbInFlight.remove(rid);
            if (queued && tgen == thumbGen)
            {
                thumbBatches--;
                // the ones that did not come: again later (a few times — some photos have none)
                foreach (rid; ids)
                    if (rid !in thumbCache)
                    {
                        immutable tries = thumbTries.get(rid, 0) + 1;
                        thumbTries[rid] = tries;
                        if (tries <= thumbTriesMax)
                            thumbQueue ~= rid;
                    }
                pumpThumbs();
            }
            // patch what was already served, so a reload / the viewer see the thumbs
            if (gen == pageGen)
                foreach (ref it; served)
                    if (it["id"].integer >= remoteBase && it["thumbUrl"].type == JSONType.null_)
                        if (auto t = (it["id"].integer - remoteBase) in thumbCache)
                            it["thumbUrl"] = *t;
            // which ones landed: the grid patches those tiles (no reload of the listing)
            if (got)
            {
                JSONValue ready = JSONValue.emptyObject;
                foreach (rid; ids)
                    if (auto t = rid in thumbCache)
                        ready[(rid + remoteBase).to!string] = *t;
                emit("thumbs.ready", JSONValue(["urls": ready]));
            }
        });
    }

    private void dates(JSONValue p, ResultCb cb)
    {
        // "Hide imported photos" on the timeline: what is left to send, the phone's own only
        immutable onlyUnsent = flag(p, "hideSent") && !(num(p, "albumId") || num(p, "personId") || flag(p, "favorites"));
        auto local = index.dates(onlyUnsent);
        if (!computer.connected || onlyUnsent)
        {
            cb(local, JSONValue(null));
            return;
        }
        computer.request("library.dates", JSONValue(null), (r, e) {
            if (e.type != JSONType.null_)
            {
                cb(local, JSONValue(null));
                return;
            }
            cb(mergeDates(local, r), JSONValue(null));
        });
    }

    /// Sums the two trees per year/month/day (duplicates are counted twice; close enough).
    static JSONValue mergeDates(JSONValue a, JSONValue b)
    {
        long[string] days; // "y-m-d" → count
        foreach (tree; [a, b])
            foreach (y; tree["years"].array)
                foreach (m; y["months"].array)
                    foreach (d; m["days"].array)
                        days[y["year"].integer.to!string ~ "-" ~ m["month"].integer.to!string ~ "-" ~ d["day"].integer.to!string]
                            += d["count"].integer;
        // rebuild newest first
        import std.algorithm : sort;
        import std.array : array, split;

        struct Key { int y, m, d; long n; }
        Key[] keys;
        foreach (k, n; days)
        {
            auto parts = k.split("-");
            keys ~= Key(parts[0].to!int, parts[1].to!int, parts[2].to!int, n);
        }
        keys.sort!((p, q) => p.y != q.y ? p.y > q.y : p.m != q.m ? p.m > q.m : p.d > q.d);
        JSONValue[] years;
        int cy = -1, cm = -1;
        foreach (ref k; keys)
        {
            if (k.y != cy)
            {
                years ~= JSONValue(["year": JSONValue(k.y), "count": JSONValue(0), "months": JSONValue(cast(JSONValue[]) [])]);
                cy = k.y; cm = -1;
            }
            auto year = &years[$ - 1];
            if (k.m != cm)
            {
                (*year)["months"].array ~= JSONValue(["month": JSONValue(k.m), "count": JSONValue(0), "days": JSONValue(cast(JSONValue[]) [])]);
                cm = k.m;
            }
            auto month = &(*year)["months"].array[$ - 1];
            (*month)["days"].array ~= JSONValue(["day": JSONValue(k.d), "count": JSONValue(k.n)]);
            (*month)["count"] = JSONValue((*month)["count"].integer + k.n);
            (*year)["count"] = JSONValue((*year)["count"].integer + k.n);
        }
        return JSONValue(["years": JSONValue(years)]);
    }

    private void albums(ResultCb cb)
    {
        if (!computer.connected)
        {
            cb(JSONValue(["albums": JSONValue(cast(JSONValue[]) [])]), JSONValue(null));
            return;
        }
        computer.request("album.list", JSONValue(null), (r, e) {
            cb(e.type == JSONType.null_ ? r : JSONValue(["albums": JSONValue(cast(JSONValue[]) [])]), JSONValue(null));
        });
    }

    /// One photo: the phone's own, or the computer's with its bytes inlined.
    private void get(long id, ResultCb cb)
    {
        if (id < remoteBase)
        {
            auto ph = index.get(id);
            if (ph is null)
                cb(JSONValue(null), error("not_found", "no such photo"));
            else
            {
                cb(ph.toJson(), JSONValue(null));
                recheckLater(id);   // shown: its kept digest is checked in full now
            }
            return;
        }
        if (!computer.connected)
        {
            cb(JSONValue(null), error("no_computer", "the computer is not connected"));
            return;
        }
        immutable rid = id - remoteBase;
        JSONValue params = ["id": JSONValue(rid)];
        computer.request("photo.get", params, (r, e) {
            if (e.type != JSONType.null_)
            {
                cb(JSONValue(null), e);
                return;
            }
            auto item = toPhoneItem(r);
            if (auto t = rid in thumbCache)
                item["thumbUrl"] = *t;
            JSONValue fp = ["id": JSONValue(rid), "maxEdge": JSONValue(2048)];
            computer.request("photo.file", fp, (f, e2) {
                string url;
                if (e2.type == JSONType.null_)
                    url = previewUrl(rid, f);
                if (url.length)
                    item["fileUrl"] = url;
                else if (item["thumbUrl"].type == JSONType.string)
                    item["fileUrl"] = item["thumbUrl"];
                cb(item, JSONValue(null));
            });
        });
    }

    /// Downloads the ORIGINAL of a computer photo to this phone (`remote-files/<id>.<ext>`
    /// next to the settings), resumably over the pull pipe; the reply carries a file:// URL
    /// the viewer can open, and the file stays for offline use. A local photo is already
    /// here and just answers with its own path.
    /// What to hand to the OS share sheet (WhatsApp, e-mail, …): a real local file — the
    /// phone's own original, or the computer's original fetched into remote-files first by
    /// `download` — as {path, mime}. Opening the sheet needs the Activity, so the UI does it
    /// (uiadapter.UiBridge).
    private static string mimeFor(string path)
    {
        import std.path : extension;
        import std.uni : toLower;

        switch (path.extension.toLower)
        {
        case ".mp4", ".m4v": return "video/mp4";
        case ".mov": return "video/quicktime";
        case ".3gp": return "video/3gpp";
        case ".webm": return "video/webm";
        case ".mkv": return "video/x-matroska";
        case ".jpg", ".jpeg": return "image/jpeg";
        case ".png": return "image/png";
        case ".webp": return "image/webp";
        case ".heic", ".heif": return "image/heic";
        case ".gif": return "image/gif";
        default: return "*/*";
        }
    }

    private void share(long id, ResultCb cb)
    {
        download(id, (r, e) {
            if (e.type != JSONType.null_) { cb(JSONValue(null), e); return; }
            immutable path = (r.type == JSONType.object && "path" in r && r["path"].type == JSONType.string)
                ? r["path"].str : "";
            if (!path.length) { cb(JSONValue(null), error("no_file", "no local file to share")); return; }
            // the share targets filter on it: a video offered as image/* reaches the wrong apps
            cb(JSONValue(["path": JSONValue(path), "mime": JSONValue(mimeFor(path))]), JSONValue(null));
        });
    }

    /// library.importedFiles: the phone's photos the computer already has — what "Free up
    /// space" offers to delete from the phone: {count, bytes, paths}. Plainly, from the index
    /// (they were delivered); with {verify: true}, only those that still are: each file is
    /// hashed again as it is NOW (an edit or a replacement since would not be on the
    /// computer) and the computer is asked whether it really holds that content (library.holds:
    /// the file on its disk, not only a row). Nothing is offered for deletion unconfirmed; each
    /// confirmed file carries the size and mtime it was hashed at, which Android checks again
    /// right before asking to delete it (an edit since → left alone).
    private void importedFiles(JSONValue p, ResultCb cb)
    {
        auto cands = index.onComputer();
        if (!flag(p, "verify"))
        {
            JSONValue[] paths;
            long bytes;
            foreach (ref ph; cands)
            {
                paths ~= JSONValue(ph.path);
                bytes += ph.size;
            }
            cb(JSONValue(["count": JSONValue(paths.length), "bytes": JSONValue(bytes), "paths": JSONValue(paths)]),
                JSONValue(null));
            return;
        }
        if (!computer.connected)
        {
            cb(JSONValue(null), error("offline", "the computer must be connected to confirm it has the photos"));
            return;
        }
        if (freeUpBox !is null)
        {
            cb(JSONValue(null), error("busy", "already checking the photos with the computer"));
            return;
        }
        auto box = new shared(FreeUpBox);
        string[] paths;
        foreach (ref ph; cands)
            paths ~= ph.path;
        box.paths = cast(shared) paths.idup;
        freeUpBox = box;
        freeUpCb = cb;
        immutable(string)[] immPaths = paths.idup;
        auto t = new Thread({ useCrashStack(); freeUpHash(box, immPaths); });
        t.name = "freeup";
        t.isDaemon = true;
        t.start();
        if (freeUpPoll is null)
        {
            freeUpPoll = new QTimer(cast(cppq.QObject) null);
            freeUpPoll.setInterval(200);
            freeUpPoll.connectTimeout(&onFreeUpHashed);
        }
        freeUpPoll.start();
    }

    private static struct FreeUpBox
    {
        immutable(string)[] paths;
        string[] shas;   // "" = could not be read, or changed while it was read
        long[] sizes;
        long[] mtimes;   // ms, as it was hashed
        bool done;
    }
    private shared(FreeUpBox)* freeUpBox;
    private ResultCb freeUpCb;
    private QTimer freeUpPoll;

    private static void freeUpHash(shared(FreeUpBox)* b, immutable(string)[] paths)
    {
        import core.atomic : atomicStore;
        import std.digest : toHexString, LetterCase;
        import std.stdio : File;
        import photowagon.core.util.fastsha : SHA256;

        version (Posix)
        {
            import core.sys.posix.sys.resource : setpriority, PRIO_PROCESS;

            setpriority(PRIO_PROCESS, 0, 12);   // behind the UI, like the sync's hashing
        }
        import std.file : getSize, timeLastModified;

        string[] shas;
        long[] sizes, mtimes;
        auto buf = new ubyte[1 << 20];   // streamed: a phone video is hundreds of MB
        foreach (path; paths)
        {
            try
            {
                immutable size0 = getSize(path);
                immutable mtime0 = timeLastModified(path).toUnixTime!long * 1000
                    + timeLastModified(path).fracSecs.total!"msecs";
                SHA256 h;
                long n;
                auto f = File(path, "rb");
                foreach (chunk; f.byChunk(buf))
                {
                    h.put(chunk);
                    n += chunk.length;
                }
                f.close();
                // written to while it was read: what was hashed is not what is there
                immutable same = n == size0 && getSize(path) == size0
                    && timeLastModified(path).toUnixTime!long * 1000 + timeLastModified(path).fracSecs.total!"msecs" == mtime0;
                shas ~= same ? toHexString!(LetterCase.lower)(h.finish()).idup : "";
                sizes ~= n;
                mtimes ~= mtime0;
            }
            catch (Exception)
            {
                shas ~= "";
                sizes ~= 0;
                mtimes ~= 0;
            }
        }
        b.shas = cast(shared) shas;
        b.sizes = cast(shared) sizes;
        b.mtimes = cast(shared) mtimes;
        atomicStore(b.done, true);
    }

    /// The files are hashed: ask the computer about them, a batch at a time.
    private void onFreeUpHashed()
    {
        import core.atomic : atomicLoad;

        auto b = freeUpBox;
        if (b is null || !atomicLoad(b.done))
            return;
        freeUpPoll.stop();
        auto paths = cast(immutable(string)[]) b.paths;
        auto shas = cast(string[]) b.shas;
        auto sizes = cast(long[]) b.sizes;
        auto mtimes = cast(long[]) b.mtimes;
        size_t[][string] byHash;   // current content → the files holding it
        foreach (i, sha; shas)
            if (sha.length == 64)
                byHash[sha] ~= i;
        auto hashes = byHash.keys;
        bool[string] have;
        void finish(JSONValue err)
        {
            freeUpBox = null;
            auto cb = freeUpCb;
            freeUpCb = null;
            if (err.type != JSONType.null_)
            {
                cb(JSONValue(null), err);
                return;
            }
            JSONValue[] out_, files;
            long bytes;
            foreach (sha, idxs; byHash)
                if (sha in have)
                    foreach (i; idxs)
                    {
                        out_ ~= JSONValue(paths[i]);
                        files ~= JSONValue(["path": JSONValue(paths[i]), "size": JSONValue(sizes[i]),
                            "mtimeMs": JSONValue(mtimes[i])]);
                        bytes += sizes[i];
                    }
            plog("free up: ", out_.length, " of ", paths.length, " files confirmed on the computer");
            cb(JSONValue(["count": JSONValue(out_.length), "bytes": JSONValue(bytes), "paths": JSONValue(out_),
                "files": JSONValue(files)]), JSONValue(null));
        }
        void ask(size_t from)
        {
            if (from >= hashes.length)
            {
                finish(JSONValue(null));
                return;
            }
            if (!computer.connected)
            {
                finish(error("offline", "the computer went away while confirming the photos"));
                return;
            }
            import std.algorithm : min;

            immutable to = min(hashes.length, from + offerBatchN);
            JSONValue[] batch;
            foreach (h; hashes[from .. to])
                batch ~= JSONValue(h);
            computer.request("library.holds", JSONValue(["hashes": JSONValue(batch)]), (r, e) {
                if (e.type != JSONType.null_)
                {
                    immutable unknown = e.type == JSONType.object && "code" in e && e["code"].type == JSONType.string
                        && e["code"].str == "unknown_method";
                    finish(unknown ? error("old_computer", "update Photo Wagon on the computer first") : e);
                    return;
                }
                if (r.type == JSONType.object && "have" in r && r["have"].type == JSONType.array)
                    foreach (h; r["have"].array)
                        if (h.type == JSONType.string)
                            have[h.str] = true;
                ask(to);
            });
        }
        ask(0);
    }

    /// Several photos to the share sheet at once: a local file for each (the computer's
    /// fetched first), in order; photos that cannot be had are left out and counted.
    private void shareMany(JSONValue p, ResultCb cb)
    {
        enum maxShare = 100;   // Android's share targets refuse far fewer; a clear limit instead
        JSONValue[] ids = p.type == JSONType.object && "ids" in p && p["ids"].type == JSONType.array
            ? p["ids"].array : null;
        foreach (i; ids)
            if (i.type != JSONType.integer)
            {
                cb(JSONValue(null), error("bad_params", "photo ids must be numbers"));
                return;
            }
        if (ids.length == 0)
        {
            cb(JSONValue(null), error("bad_params", "no photos to share"));
            return;
        }
        if (ids.length > maxShare)
        {
            cb(JSONValue(null), error("too_many", "share at most " ~ maxShare.to!string ~ " photos at once"));
            return;
        }
        JSONValue[] paths;
        size_t missing;
        void step(size_t i)
        {
            if (i == ids.length)
            {
                if (paths.length == 0)
                {
                    cb(JSONValue(null), error("no_file", "none of these photos is available here right now"));
                    return;
                }
                // one type the targets can filter on: image/*, video/*, or anything
                string kind;
                foreach (pth; paths)
                {
                    import std.algorithm : startsWith;
                    immutable m = mimeFor(pth.str);
                    immutable k = m.startsWith("video/") ? "video/*" : m.startsWith("image/") ? "image/*" : "*/*";
                    kind = kind.length == 0 || kind == k ? k : "*/*";
                }
                cb(JSONValue(["paths": JSONValue(paths), "mime": JSONValue(paths.length == 1 ? mimeFor(paths[0].str) : kind),
                    "missing": JSONValue(missing)]), JSONValue(null));
                return;
            }
            download(ids[i].integer, (r, e) {
                if (e.type == JSONType.null_ && r.type == JSONType.object && "path" in r
                    && r["path"].type == JSONType.string && r["path"].str.length)
                    paths ~= r["path"];
                else
                    missing++;
                step(i + 1);
            });
        }
        step(0);
    }

    /// album.create / addPhotos / removePhotos with the phone's photo ids: each becomes the
    /// computer's id. The computer's photos are shifted back; the phone's are looked up by
    /// their hash (the import probe) and, for create/add, sent first when the computer does
    /// not have them. The answer says how many were sent and how many could not be added.
    private void albumWithPhotos(string method, JSONValue params, ResultCb cb)
    {
        if (!computer.connected)
        {
            cb(JSONValue(null), error("no_computer", "albums live on the computer — connect it first"));
            return;
        }
        if (params.type != JSONType.object || "photoIds" !in params || params["photoIds"].type != JSONType.array)
        {
            forward(method, params, cb);
            return;
        }
        foreach (i; params["photoIds"].array)
            if (i.type != JSONType.integer)
            {
                cb(JSONValue(null), error("bad_params", "photo ids must be numbers"));
                return;
            }
        immutable sendMissing = method != "album.removePhotos";
        computerIds(params["photoIds"].array, sendMissing, (long[] got, size_t sent, size_t failed) {
            if (got.length == 0 && failed > 0)
            {
                cb(JSONValue(null), error("no_photos", failed == 1 ? "the photo could not be put on the computer"
                    : "none of the photos could be put on the computer"));
                return;
            }
            auto q = params;
            JSONValue[] arr;
            foreach (g; got)
                arr ~= JSONValue(g);
            q["photoIds"] = JSONValue(arr);
            forward(method, q, (r, e) {
                if (e.type == JSONType.null_)
                {
                    if (r.type != JSONType.object)
                        r = JSONValue.emptyObject;
                    r["sent"] = sent;
                    r["failed"] = failed;
                    r["added"] = got.length;
                }
                cb(r, e);
            });
        });
    }

    /// The computer's ids for the phone's photo ids, in order (see albumWithPhotos).
    private void computerIds(JSONValue[] ids, bool sendMissing, void delegate(long[], size_t, size_t) done)
    {
        long[] got;
        size_t sent, failed;
        void step(size_t i)
        {
            if (i == ids.length)
                return done(got, sent, failed);
            immutable id = ids[i].type == JSONType.integer ? ids[i].integer : 0;
            void next(long cid)
            {
                if (cid > 0)
                    got ~= cid;
                else
                    failed++;
                step(i + 1);
            }
            if (id >= remoteBase)
                return next(id - remoteBase);
            auto ph = index.get(id);
            if (ph is null || !computer.connected)
                return next(0);
            immutable name = ph.path.baseName;
            string hash = ph.hash;
            if (hash.length == 0)
            {
                try
                    hash = fileSha256(ph.path);
                catch (Exception ex)
                    return next(0);
            }
            void probe(void delegate(long) then)
            {
                computer.request("library.import", JSONValue(["name": JSONValue(name), "sha256": JSONValue(hash),
                    "probe": JSONValue(true)]), (r, e) {
                    then(e.type == JSONType.null_ && r.type == JSONType.object && "existed" in r
                        && r["existed"].type == JSONType.true_ && "id" in r && r["id"].type == JSONType.integer
                        ? r["id"].integer : 0);
                });
            }
            probe((long cid) {
                if (cid > 0 || !sendMissing)
                    return next(cid);
                // not there yet: send it, then ask again (a fresh import may not name its id)
                upload(id, (r, e) {
                    if (e.type != JSONType.null_)
                        return next(0);
                    sent++;
                    if (r.type == JSONType.object && "id" in r && r["id"].type == JSONType.integer)
                        return next(r["id"].integer);
                    // a fresh import is indexed in the background: ask again for a while
                    int tries = 20;   // × 500 ms
                    void again()
                    {
                        probe((long cid2) {
                            if (cid2 > 0 || --tries <= 0 || !computer.connected)
                                return next(cid2);
                            later(500, &again);
                        });
                    }
                    again();
                });
            });
        }
        step(0);
    }

    // Run `dg` in `ms` milliseconds, on the Qt thread. One timer for all of them: a timer
    // per call would stay alive (DSide roots a connected delegate until its sender dies).
    private QTimer laterTimer;
    private struct Later
    {
        MonoTime due;
        void delegate() dg;
    }
    private Later[] laters;

    private void later(int ms, void delegate() dg)
    {
        if (laterTimer is null)
        {
            laterTimer = new QTimer(cast(cppq.QObject) null);
            laterTimer.setSingleShot(true);
            laterTimer.connectTimeout(&runLaters);
        }
        laters ~= Later(MonoTime.currTime + ms.msecs, dg);
        armLater();
    }

    private void armLater()
    {
        if (laters.length == 0)
            return;
        MonoTime first = laters[0].due;
        foreach (l; laters)
            if (l.due < first)
                first = l.due;
        immutable wait = (first - MonoTime.currTime).total!"msecs";
        laterTimer.setInterval(wait > 0 ? cast(int) wait : 0);
        laterTimer.start();
    }

    private void runLaters()
    {
        immutable now = MonoTime.currTime;
        Later[] due, rest;
        foreach (l; laters)
            (l.due <= now ? due : rest) ~= l;
        laters = rest;
        foreach (l; due)
            if (!closing)
            {
                try
                    l.dg();
                catch (Exception ex)
                    plog("later: a callback failed: ", ex.msg);
            }
        armLater();
    }

    // ---- "checked again the next time it is shown" -----------------------------------
    // A rescan keeps a file's digest on its fingerprint alone (size + 8 samples). The full
    // check happens when the photo is shown: the viewer opening it re-digests it off-thread,
    // one at a time, once per session; a different sha256 replaces the kept digest (and makes
    // the photo unsent — it is new content). A push checks every piece it sends as well.
    private static struct RecheckBox
    {
        long id;
        string sha, pieces, fp;
        long size;
        bool done;
    }
    private long[] recheckQueue;
    private bool[long] rechecked;
    private shared(RecheckBox)* rechecking;
    private QTimer recheckPoll;

    private void recheckLater(long id)
    {
        auto ph = index.get(id);
        // No digest yet: the next offer computes it anyway. A video is not checked here: the
        // player does not read the whole file to show it, so the check would cost a full read
        // (its pieces are checked as they are sent). A photo was just read whole to be shown
        // — the check reads it back from the page cache, no storage I/O, only the sha256.
        if (ph is null || !ph.hash.length || ph.isVideo || (id in rechecked) !is null)
            return;
        rechecked[id] = true;
        recheckQueue ~= id;
        pumpRecheck();
    }

    private void pumpRecheck()
    {
        if (rechecking !is null || closing)
            return;
        while (recheckQueue.length)
        {
            immutable id = recheckQueue[0];
            recheckQueue = recheckQueue[1 .. $];
            auto ph = index.get(id);
            if (ph is null)
                continue;
            auto box = new shared(RecheckBox);
            box.id = id;
            rechecking = box;
            immutable path = ph.path;
            auto t = new Thread({ useCrashStack(); digestInto(box, path); });
            t.name = "recheck";
            t.isDaemon = true;
            t.start();
            if (recheckPoll is null)
            {
                recheckPoll = new QTimer(cast(cppq.QObject) null);
                recheckPoll.setInterval(200);
                recheckPoll.connectTimeout(&onRechecked);
            }
            recheckPoll.start();
            return;
        }
    }

    private static void digestInto(shared(RecheckBox)* b, string path)
    {
        version (Posix)
        {
            import core.sys.posix.sys.resource : setpriority, PRIO_PROCESS;

            setpriority(PRIO_PROCESS, 0, 12);   // behind the UI, like the sync's hashing
        }
        try
        {
            import photowagon.core.sync.digest : digestFile, encodePieces;

            auto d = digestFile(path);
            b.sha = d.sha;
            b.pieces = encodePieces(d.pieces);
            b.fp = d.fingerprint;
            b.size = d.size;
        }
        catch (Exception)
        {
        }
        b.done = true;
    }

    private void onRechecked()
    {
        auto b = rechecking;
        if (b is null || !b.done)
            return;
        recheckPoll.stop();
        rechecking = null;
        if (b.sha.length)
        {
            bool changed;
            if (auto ph = index.get(b.id))
                changed = ph.hash.length && ph.hash != b.sha;
            index.setDigest(b.id, cast(string) b.sha, cast(string) b.pieces, cast(string) b.fp, b.size);
            if (changed)
            {
                plog("index: photo ", b.id, " changed since it was hashed — its digest is replaced");
                index.saveNow();   // kept even if the process dies next
                startSync();       // new content: offered now if auto-sync is on
            }
        }
        pumpRecheck();
    }

    private static string fileSha256(string path)
    {
        import std.digest : toHexString, LetterCase;
        import photowagon.core.util.fastsha : SHA256;
        import std.stdio : File;

        SHA256 h;
        foreach (chunk; File(path, "rb").byChunk(1 << 20))
            h.put(chunk);
        return toHexString!(LetterCase.lower)(h.finish()).idup;
    }

    // ---- the zoomed viewer: the visible part of a big photo at full resolution ----------
    // (the phone's own original, or the computer's fetched raw first — never base64)
    private string[long] originals;          // computer photo id → its original fetched this run
    private ResultCb[][string] downloadWaiters; // "<endpoint gen>:<photo id>" → who waits for its pull
    private long endpointGen;                // bumped by setEndpoint: a pull of the old computer is not the new one's
    private int regionSeq;
    private string[] regionFiles;
    private void region(JSONValue p, ResultCb cb)
    {
        import photowagon.mobile.region : Frac, decodeRegion;
        import qt.quick.qimagereader : QImageReader;
        import qt.quick.qimage : QImage;
        import cxxrt : make;

        double f(string k, double def)
        {
            if (p.type != JSONType.object || k !in p)
                return def;
            return p[k].type == JSONType.float_ ? p[k].floating : p[k].type == JSONType.integer ? cast(double) p[k].integer : def;
        }
        immutable id = num(p, "id");
        auto r = Frac(f("x", 0), f("y", 0), f("w", 1), f("h", 1));
        immutable maxEdge = cast(int) num(p, "maxEdge", 0);
        download(id, (d, e) {
            if (e.type != JSONType.null_)
                return cb(JSONValue(null), e);
            try
            {
                import std.file : tempDir;

                immutable dir = previewDir.length ? previewDir : tempDir;
                immutable dst = buildPath(dir, "region-" ~ (++regionSeq).to!string ~ ".jpg");
                auto reader = make!QImageReader();
                auto img = new QImage();
                scope (exit) { destroy(img); destroy(reader); }
                immutable t0 = MonoTime.currTime;
                decodeRegion(reader, img, d["path"].str, r, maxEdge);
                if (!img.save(dst, "JPEG".ptr, 92))
                    throw new Exception("cannot write the region");
                plog("region: photo ", id, " ", img.width(), "x", img.height(), " in ",
                    (MonoTime.currTime - t0).total!"msecs", " ms");
                // the last few only: the viewer shows one at a time
                regionFiles ~= dst;
                while (regionFiles.length > 3)
                {
                    try { import std.file : remove; remove(regionFiles[0]); } catch (Exception) {}
                    regionFiles = regionFiles[1 .. $];
                }
                JSONValue out_ = ["id": JSONValue(id), "x": JSONValue(r.x), "y": JSONValue(r.y),
                    "w": JSONValue(r.w), "h": JSONValue(r.h), "fileUrl": JSONValue(fileUrl(dst))];
                cb(out_, JSONValue(null));
            }
            catch (Exception ex)
                cb(JSONValue(null), error("io", ex.msg));
        });
    }

    private void download(long id, ResultCb cb)
    {
        import std.path : extension;

        if (id < remoteBase)
        {
            auto ph = index.get(id);
            if (ph is null)
            {
                cb(JSONValue(null), error("not_found", "no such photo"));
                return;
            }
            cb(JSONValue(["path": JSONValue(ph.path), "fileUrl": JSONValue(fileUrl(ph.path)), "size": JSONValue(0L)]), JSONValue(null));
            return;
        }
        immutable rid = id - remoteBase;
        // fetched (and verified) already in this run: the file, at once — a zoomed viewer asks
        // on every pan, and a second pull of the same file would race the first one's finish
        if (auto have = rid in originals)
        {
            import std.file : exists, getSize;

            if ((*have).exists)
            {
                cb(JSONValue(["path": JSONValue(*have), "fileUrl": JSONValue(fileUrl(*have)),
                    "size": JSONValue(cast(long) getSize(*have))]), JSONValue(null));
                return;
            }
            originals.remove(rid);
        }
        // one pull per photo (of this computer): later askers wait for the one running
        immutable gen = endpointGen;
        immutable wkey = gen.to!string ~ ":" ~ rid.to!string;
        if (auto w = wkey in downloadWaiters)
        {
            *w ~= cb;
            return;
        }
        if (!computer.connected || !computer.canPull())
        {
            cb(JSONValue(null), error("no_computer", "the computer is not reachable for a download"));
            return;
        }
        downloadWaiters[wkey] = [cb];
        auto askers = cb;
        cb = (JSONValue d, JSONValue de) {
            auto all = downloadWaiters.get(wkey, [askers]);
            downloadWaiters.remove(wkey);
            // remembered only for the computer it came from
            if (gen == endpointGen && de.type == JSONType.null_ && d.type == JSONType.object && "path" in d)
                originals[rid] = d["path"].str;
            foreach (c; all)
                c(d, de);
        };
        JSONValue params = ["id": JSONValue(rid)];
        // the extension comes from the computer's record, so the file opens as what it is
        computer.request("photo.get", params, (r, e) {
            if (e.type != JSONType.null_)
            {
                cb(JSONValue(null), e);
                return;
            }
            string ext = ".jpg";
            if (r.type == JSONType.object && "path" in r && r["path"].type == JSONType.string && r["path"].str.extension.length)
                ext = r["path"].str.extension;
            immutable sha = r.type == JSONType.object && "hash" in r && r["hash"].type == JSONType.string ? r["hash"].str : "";
            // named by content as well as id: a kept file is reused only for the very same
            // photo — another computer (or a changed photo) with the same id names a new file
            immutable dest = buildPath(remoteFileDir, rid.to!string ~ (sha.length >= 16 ? "-" ~ sha[0 .. 16] : "") ~ ext);
            {
                // kept from an earlier run: the same size as the computer's is the same file (it
                // was verified piece by piece and by its whole hash when it landed)
                import std.file : exists, getSize;

                if (dest.exists && r.type == JSONType.object && "size" in r && r["size"].type == JSONType.integer
                    && cast(long) getSize(dest) == r["size"].integer)
                {
                    cb(JSONValue(["path": JSONValue(dest), "fileUrl": JSONValue(fileUrl(dest)), "size": r["size"]]),
                        JSONValue(null));
                    return;
                }
            }
            import photowagon.mobile.p2pbridge : P2pBridge;
            auto p2p = cast(P2pBridge) computer;
            void done(JSONValue d, JSONValue de)
            {
                if (de.type != JSONType.null_)
                {
                    cb(JSONValue(null), de);
                    return;
                }
                cb(JSONValue(["path": JSONValue(dest), "fileUrl": JSONValue(fileUrl(dest)), "size": d["size"]]), JSONValue(null));
            }
            if (p2p !is null && sha.length == 64)
                p2p.downloadFile(rid, dest, sha, &done);   // pieces: verified, any order, any source
            else
                computer.downloadFile(rid, dest, &done);
        });
    }

    // ---- sending to the computer ---------------------------------------------------

    /// Reads the file and hands it to the computer as `library.import`.
    private void upload(long id, ResultCb cb)
    {
        if (id >= remoteBase)
        {
            cb(JSONValue(null), error("bad_params", "already on the computer"));
            return;
        }
        auto ph = index.get(id);
        if (ph is null)
        {
            cb(JSONValue(null), error("not_found", "no such photo"));
            return;
        }
        if (!computer.connected)
        {
            cb(JSONValue(null), error("no_computer", "not connected to a computer"));
            return;
        }
        immutable withFacesPush = ph.facesScanned && !ph.facesGaveUp && !ph.facesSent;
        if (computer.canPush())
        {
            // the raw-bytes pipe, streamed from the file like the sync's own pushes: a video
            // read whole and base64'd would be gigabytes in memory
            // the file as it is NOW (one streamed pass): an index hash can predate an in-place
            // edit, and the computer would answer "existed" for the old bytes. The digest is
            // kept, so nothing reads this file again to offer or push it.
            string hash, pieces;
            long dgSize;
            try
            {
                import photowagon.core.sync.digest : digestFile, encodePieces;

                auto dg = digestFile(ph.path);
                hash = dg.sha;
                pieces = encodePieces(dg.pieces);
                dgSize = dg.size;
                index.setDigest(id, hash, pieces, dg.fingerprint, dg.size);
            }
            catch (Exception e)
            {
                cb(JSONValue(null), error("io", e.msg));
                return;
            }
            JSONValue meta = [
                "name": JSONValue(ph.path.baseName),
                "takenAt": JSONValue(isoTime(ph.takenTs)),
                "mtimeMs": JSONValue(ph.mtimeMs),
                "sha256": JSONValue(hash),
                "pieces": JSONValue(pieces),
                "size": JSONValue(dgSize),
            ];
            if (withFacesPush)
                meta["faces"] = facesToJson(ph.faces);
            immutable ticket = nextTicket++;
            manualUploads++;
            publishSync();   // busy: the service shows the send while it runs
            computer.uploadFile(ticket, ph.path, meta, (r, e) {
                manualUploads--;
                if (e.type == JSONType.null_)
                {
                    index.markSent(id, hash);
                    if (withFacesPush && imported(r))
                        index.markFacesSent(id);
                    pumpFaces();
                }
                else if (e.toString().canFind("file_changed") || e.toString().canFind("sha256 mismatch"))
                    index.clearDigest(id, hash);   // changed while it went: hashed again when next offered
                else
                    index.markFailed(id, hash);
                publishSync();
                cb(r, e);
            });
            return;
        }
        ubyte[] bytes;
        try
            bytes = cast(ubyte[]) read(ph.path);
        catch (Exception e)
        {
            cb(JSONValue(null), error("io", e.msg));
            return;
        }
        JSONValue params = [
            "name": JSONValue(ph.path.baseName),
            "takenAt": JSONValue(isoTime(ph.takenTs)),
            "mtimeMs": JSONValue(ph.mtimeMs),
            "base64": JSONValue(cast(string) Base64.encode(bytes)),
        ];
        immutable withFaces = ph.facesScanned && !ph.facesGaveUp && !ph.facesSent;
        if (withFaces)
            params["faces"] = facesToJson(ph.faces);   // on-device faces (or [] = none) → the computer stores them
        // keep the hash: faces computed later go on their own (library.faces) by sha256
        import std.digest : toHexString, LetterCase;
        import photowagon.core.util.fastsha : sha256Of;
        immutable sentHash = toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
        // these bytes ARE the photo now: its hash is what was just read (markSent only marks
        // the content the photo still has)
        index.setHash(id, sentHash);
        computer.request("library.import", params, (r, e) {
            if (e.type == JSONType.null_)
            {
                index.markSent(id, sentHash);
                if (withFaces && imported(r))
                    index.markFacesSent(id);   // a deduplicated upload ("existed") never read them
                pumpFaces();   // faces that finished meanwhile, or that the dedup left behind
            }
            else
                index.markFailed(id, sentHash);
            cb(r, e);
        });
    }

    // ---- faces and people: the computer's face database, seen from here ---------------

    private void forward(string method, JSONValue params, ResultCb cb)
    {
        if (!computer.connected)
        {
            cb(JSONValue(null), error("no_computer", "the computer is not connected"));
            return;
        }
        computer.request(method, params, cb);
    }

    /// The computer's people, portraits inline (its files are not reachable from here).
    private void people(ResultCb cb)
    {
        if (!computer.connected)
        {
            cb(JSONValue(["people": JSONValue(cast(JSONValue[]) [])]), JSONValue(null));
            return;
        }
        JSONValue params = ["inline": JSONValue(true)];
        computer.request("people.list", params, cb);
    }

    /// Faces of a photo: a computer photo by its id, one of ours by its hash (once it is
    /// there); nothing when the computer is away.
    private void faces(long id, ResultCb cb)
    {
        JSONValue none = ["photoId": JSONValue(id), "faces": JSONValue(cast(JSONValue[]) [])];
        if (!computer.connected)
        {
            cb(none, JSONValue(null));
            return;
        }
        void ask(long remoteId)
        {
            JSONValue params = ["id": JSONValue(remoteId), "inline": JSONValue(true)];
            computer.request("photo.faces", params, (r, e) {
                if (e.type != JSONType.null_ || r.type != JSONType.object)
                {
                    cb(none, JSONValue(null));
                    return;
                }
                r["photoId"] = id;   // the id the viewer asked with
                plog("faces: ", r["faces"].array.length, " for photo ", id, " (computer id ", remoteId, ")");
                cb(r, JSONValue(null));
            });
        }
        if (id >= remoteBase)
        {
            ask(id - remoteBase);
            return;
        }
        auto ph = index.get(id);
        if (ph is null || ph.hash.length == 0)
        {
            cb(none, JSONValue(null));
            return;
        }
        JSONValue byHash = ["sha256": JSONValue(ph.hash)];
        computer.request("library.byHash", byHash, (r, e) {
            if (e.type != JSONType.null_ || r.type != JSONType.object || !("id" in r))
            {
                cb(none, JSONValue(null));
                return;
            }
            ask(r["id"].integer);
        });
    }

    // ---- sync engine ------------------------------------------------------------------

    /// Whether sending is held back now: paused, or data saver on a metered network.
    private bool held() const
    {
        return syncPaused || (dataSaver && metered);
    }

    private bool readMetered()
    {
        try
            return meteredFile.length && meteredFile.exists && readText(meteredFile).length && readText(meteredFile)[0] == '1';
        catch (Exception)
            return false;
    }

    private static void setFlagFile(string path, bool on)
    {
        if (!path.length)
            return;
        try
        {
            import photowagon.mobile.atomicfile : writeAtomic;
            import std.file : remove;

            if (on)
                writeAtomic(path, "1");
            else if (path.exists)
                remove(path);
        }
        catch (Exception e)
            plog("sync: cannot save setting: ", e.msg);
    }

    /// Stop taking new photos (the one in flight finishes): the queue is dropped and the
    /// run's counters closed, so resuming starts a clean run from the next unsent photo.
    /// A "Send all now" run keeps its intent (manualRun): resuming continues it, and the
    /// service keeps holding it meanwhile.
    private void holdRun()
    {
        // the dropped photos leave the run's total (a pause + resume must not count them twice)
        sendTotal -= cast(long) sendQueue.length;
        if (sendTotal < 0)
            sendTotal = 0;
        sendQueue.length = 0;
            offeredHash = null;
        offeredHash = null;
        if (!busySending)
        {
            sent = sendTotal = sendFailed = skipped = declined = 0;
            index.saveNow();
        }
        publishSync();
    }

    private void setAutoSync(bool on)
    {
        autoSync = on;
        if (autoSyncFile.length)
        {
            try
            {
                if (on) { import photowagon.mobile.atomicfile : writeAtomic; writeAtomic(autoSyncFile, "1"); }
                else if (autoSyncFile.exists) { import std.file : remove; remove(autoSyncFile); }
            }
            catch (Exception e)
                plog("sync: cannot save setting: ", e.msg);
        }
    }

    JSONValue syncStatus()
    {
        immutable pending = index.unsentCount();
        return JSONValue([
            "enabled": JSONValue(autoSync),
            "connected": JSONValue(computer.connected),
            "active": JSONValue(busySending || sendQueue.length > 0),
            // sending work under way (hashing a batch, asking the computer, or pushing): the
            // only time the background service shows a notification
            "busy": JSONValue(busySending || negotiating || sendQueue.length > 0 || manualUploads > 0),
            // failures of the last finished run (the run's counters are reset when it ends)
            "runFailed": JSONValue(lastRunFailed),
            "pending": JSONValue(pending),
            "total": JSONValue(sendTotal),
            "done": JSONValue(sent + sendFailed),
            "sent": JSONValue(sent),
            "skipped": JSONValue(skipped),
            "failed": JSONValue(sendFailed),
            // failed for good (after its retries) — outlives the run; "Send all now" retries them
            "gaveUp": JSONValue(index.gaveUpCount()),
            // photos (not attempts) that failed and are not on the computer: what the UI shows
            "failedPhotos": JSONValue(index.failedPhotoCount()),
            // a "Send all now" run is going: CoreService keeps it alive like auto-sync would
            "manual": JSONValue(manualRun),
            "paused": JSONValue(syncPaused),
            "dataSaver": JSONValue(dataSaver),
            "metered": JSONValue(metered),
            // held back right now, and why: "paused" | "metered" | null
            "held": syncPaused ? JSONValue("paused") : dataSaver && metered ? JSONValue("metered") : JSONValue(null),
            "error": lastSyncError.length ? JSONValue(lastSyncError) : JSONValue(null),
        ]);
    }

    /// Tells the UI and the Android notifier (a file the Java side watches).
    private void publishSync()
    {
        auto st = syncStatus();
        emit("sync.status", st);
        if (syncStatusFile.length)
        {
            try
            {
                import photowagon.mobile.atomicfile : writeAtomic;

                // MainActivity / SyncService parse this from Java, possibly mid-write
                mkdirRecurse(syncStatusFile.dirName);
                writeAtomic(syncStatusFile, st.toString());
            }
            catch (Exception e)
                plog("sync: cannot write status: ", e.msg);
        }
    }

    /// Queue what is missing on the computer and start, if allowed and connected.
    private void startSync()
    {
        if ((!autoSync && !manualRun) || !computer.connected || held())
        {
            publishSync();
            return;
        }
        // a step is already in flight; it will carry on to the next batch by itself
        if (busySending || negotiating)
            return;
        if (sendTotal == 0 && sendQueue.length == 0)
        {
            sent = sendFailed = skipped = declined = 0;
            lastRunFailed = 0;
            lastSyncError = null;
        }
        if (sendQueue.length)
            pumpSend();
        else
            negotiateNextBatch();
    }

    /// Offer the computer a batch of hashes; it tells us what it has and what it refuses,
    /// and only the rest becomes `sendQueue`. Hashes missing from the index are computed
    /// off-thread first (onHashed continues here).
    private void negotiateNextBatch()
    {
        if (busySending || negotiating || !computer.connected)
            return;
        if (held())
        {
            holdRun();
            return;
        }
        auto ids = index.unsentIds();
        if (ids.length == 0)
        {
            manualRun = false;   // a "Send all now" run is complete
            pumpSend();   // nothing to offer — let pumpSend finalise the run
            return;
        }
        if (ids.length > offerBatchN)
            ids = ids[0 .. offerBatchN];
        negotiating = true;
        publishSync();   // "busy" out now: the service goes foreground while the batch is hashed
        pendingOfferIds = ids.dup;
        long[] needHash;
        string[] paths;
        foreach (id; ids)
        {
            auto p = index.get(id);
            // no digest yet, or an older index entry with a hash but no piece hashes: one
            // pass fills in all of it
            if (p !is null && (!p.hash.length || !p.pieces.length))
            {
                needHash ~= id;
                paths ~= p.path;
            }
        }
        if (needHash.length == 0)
        {
            offerBatch();
            return;
        }
        pendingHashIds = needHash;
        auto hb = new shared(HashBatch);
        hashing = hb;
        immutable(string)[] immPaths = paths.idup;
        import core.thread : Thread;
        auto t = new Thread({ useCrashStack(); hashFiles(hb, immPaths); });
        t.name = "hash";
        t.isDaemon = true;
        t.start();
        hashPoll.start();
    }

    private static void hashFiles(shared(HashBatch)* hb, immutable(string)[] paths)
    {
        import std.digest.sha : toHexString, LetterCase;
        import photowagon.core.util.fastsha : sha256Of;

        // Run behind the UI: hashing a 512-photo batch reads and digests gigabytes, and at
        // normal priority it starved the render thread — scrolling went to pieces during a
        // sync. A high nice value hands the phone's cores to the interface first; the sync
        // just takes a little longer in the background.
        version (Posix)
        {
            import core.sys.posix.sys.resource : setpriority, PRIO_PROCESS;

            setpriority(PRIO_PROCESS, 0, 12);
        }
        import photowagon.core.sync.digest : digestFile, encodePieces;

        shared(string)[] out_, pcs, fps;
        shared(long)[] szs;
        foreach (p; paths)
        {
            // One streamed pass per file (never the whole file in memory: a phone video is
            // hundreds of MB, and reading it at once sent the core past its memory limit): the
            // sha256, the piece hashes and the fingerprint together — computed once, kept in
            // the index, never read again to be offered or pushed.
            try
            {
                auto d = digestFile(p);
                out_ ~= cast(shared) d.sha;
                pcs ~= cast(shared) encodePieces(d.pieces);
                fps ~= cast(shared) d.fingerprint;
                szs ~= d.size;
            }
            catch (Exception)
            {
                out_ ~= cast(shared) "";
                pcs ~= cast(shared) "";
                fps ~= cast(shared) "";
                szs ~= 0L;
            }
        }
        hb.hashes = out_;
        hb.pieces = pcs;
        hb.fps = fps;
        hb.sizes = szs;
        hb.done = true;
    }

    private void onHashed()
    {
        auto hb = hashing;
        if (hb is null || !hb.done)
            return;
        hashPoll.stop();
        hashing = null;
        auto hashes = cast(string[]) hb.hashes;
        auto pcs = cast(string[]) hb.pieces;
        auto fps = cast(string[]) hb.fps;
        auto szs = cast(long[]) hb.sizes;
        foreach (i, id; pendingHashIds)
            if (i < hashes.length && hashes[i].length)
            {
                index.setDigest(id, hashes[i], i < pcs.length ? pcs[i] : null, i < fps.length ? fps[i] : null,
                    i < szs.length ? szs[i] : 0);
                // a hashed photo of ours is a file we can SERVE by sha256 (the piece protocol)
                import photowagon.mobile.p2pbridge : P2pBridge;

                if (auto p2p = cast(P2pBridge) computer)
                    if (auto ph = index.get(id))
                        p2p.registerLocal(hashes[i], ph.path);
            }
        pendingHashIds = null;
        offerBatch();
    }

    private void offerBatch()
    {
        JSONValue[] hashes;
        long[string] idOf;
        string[long] hashOf;   // what was offered for each photo (a recheck may change it later)
        foreach (id; pendingOfferIds)
        {
            auto p = index.get(id);
            if (p !is null && p.hash.length)
            {
                hashes ~= JSONValue(p.hash);
                idOf[p.hash] = id;
                hashOf[id] = p.hash;
            }
        }
        auto batch = pendingOfferIds.dup;
        pendingOfferIds = null;
        if (hashes.length == 0)
        {
            negotiating = false;
            foreach (id; batch)
                queueWanted(id);
            pumpSend();
            return;
        }
        JSONValue params = ["hashes": JSONValue(hashes)];
        plog("sync: offering ", hashes.length, " hashes to the computer");
        syncRequest(probeTimeoutMs, (cb) { computer.request("library.offer", params, cb); }, (r, e) {
            negotiating = false;
            if (e.type != JSONType.null_)
            {
                // the computer would not negotiate (offline, or an older build): send them all
                foreach (id; batch)
                    queueWanted(id);
                pumpSend();
                return;
            }
            bool[long] handled;
            if (r.type == JSONType.object && "have" in r && r["have"].type == JSONType.array)
                foreach (h; r["have"].array)
                    if (h.type == JSONType.string)
                        if (auto pid = h.str in idOf)
                        {
                            // only if the photo still IS that content: a recheck may have
                            // replaced its digest while the offer was out
                            if (auto ph = index.get(*pid))
                                if (ph.hash == h.str)
                                {
                                    skipped++;
                                    index.markSent(*pid, h.str);
                                }
                            handled[*pid] = true;
                        }
            if (r.type == JSONType.object && "refuse" in r && r["refuse"].type == JSONType.array)
                foreach (h; r["refuse"].array)
                    if (h.type == JSONType.string)
                        if (auto pid = h.str in idOf)
                        {
                            if (auto ph = index.get(*pid))
                                if (ph.hash == h.str)
                                {
                                    declined++;
                                    index.markDeclined(*pid);
                                }
                            handled[*pid] = true;
                        }
            long wanted;
            foreach (id; batch)
                // only what was offered: a photo whose hashing failed was not, and waits for a
                // later batch (sending it unoffered could bring back something the computer refuses)
                if (id !in handled && (id in hashOf) !is null)
                {
                    queueWanted(id, hashOf[id]);
                    wanted++;
                }
            plog("sync: computer has ", skipped, ", refuses ", declined, ", wants ", wanted, " of this batch");
            publishSync();
            pumpSend();
        });
    }

    /// `hash`: the content that was offered (the snapshot taken when the offer was built);
    /// the photo is sent only if it still is that content. null = no offer (an older computer
    /// that does not negotiate): the current hash.
    private void queueWanted(long id, string hash = null)
    {
        sendQueue ~= id;
        sendTotal++;
        if (hash.length)
            offeredHash[id] = hash;
        else if (auto ph = index.get(id))
            offeredHash[id] = ph.hash;
    }
    private string[long] offeredHash;

    private void pumpSend()
    {
        if (sending || uploads.length >= sendWindow)
            return;
        if (sendQueue.length == 0 && uploads.length)
            return;   // the last ones are still going: the run ends when they answer
        if (sendQueue.length == 0)
        {
            // the wanted photos of this batch are done; if more remain, offer the next batch
            if (!negotiating && computer.connected && index.unsentCount() > 0)
            {
                negotiateNextBatch();
                return;
            }
            if (sendTotal || skipped || declined)
            {
                emit("upload.done", JSONValue(["sent": JSONValue(sent), "failed": JSONValue(sendFailed), "total": JSONValue(sendTotal)]));
                plog("sync: done — ", sent, " sent, ", skipped, " already there, ", declined, " refused, ", sendFailed, " failed");
                emit("library.changed", JSONValue.emptyObject);
            }
            index.saveNow();   // the last marks must not wait for the timer: Android may kill us next
            lastRunFailed = sendFailed;
            offeredHash = null;
            sent = sendTotal = sendFailed = skipped = declined = 0;
            if (!held())   // a held run keeps its intent: Resume (or Wi-Fi) carries it on
                manualRun = false;   // a "Send all now" run is over; new photos wait for auto-sync
            publishSync();
            pumpFaces();   // the run is over (even one that found everything already there)
            return;
        }
        if (!computer.connected)
        {
            sendQueue.length = 0;
            uploads = null;
            offeredHash = null;   // resumes on the next connection (startSync)
            publishSync();
            return;
        }
        if (held())   // paused, or data saver on a metered network: the next one waits
        {
            holdRun();
            return;
        }
        if (uploads.length && !computer.canPush())
            return;   // the raw pipe went: the old one-at-a-time send waits for those in flight
        immutable id = sendQueue[0];
        sendQueue = sendQueue[1 .. $];
        auto ph = index.get(id);
        string offered;
        if (auto o = id in offeredHash)
        {
            offered = *o;
            offeredHash.remove(id);
        }
        // gone, or changed since the offer (a rescan or a recheck replaced its digest): not
        // this run's — it is offered again, as what it is now, in the next batch
        if (ph is null || (offered.length && ph.hash != offered))
        {
            if (ph !is null)
                sendTotal--;
            pumpSend();
            return;
        }
        plog("sync: photo ", id, " (", sent + sendFailed + uploads.length + 1, " of ", sendTotal, ") preparing");
        emit("upload.progress", JSONValue(["done": JSONValue(sent + sendFailed), "total": JSONValue(sendTotal), "id": JSONValue(id)]));
        // Raw-bytes pipe (libp2p): stream the file on its own stream, no base64 and no giant
        // JSON line; the metadata rides the normal request with a ticket the desktop pairs up.
        if (computer.canPush())
        {
            immutable ticket = nextTicket++;
            immutable phash = ph.hash;
            immutable ppath = ph.path;
            JSONValue meta = [
                "name": JSONValue(ph.path.baseName),
                "takenAt": JSONValue(isoTime(ph.takenTs)),
                "mtimeMs": JSONValue(ph.mtimeMs),
                "sha256": JSONValue(phash),
            ];
            // the manifest computed when the photo was hashed: the push checks each piece
            // it reads against it (only the piece — the file is not hashed again)
            if (ph.pieces.length)
            {
                meta["pieces"] = ph.pieces;
                if (ph.digestSize > 0)
                    meta["size"] = ph.digestSize;   // the size the manifest was made for: checked exactly
            }
            if (ph.facesScanned && !ph.facesGaveUp && !ph.facesSent)
            {
                meta["faces"] = facesToJson(ph.faces);
                facesInPayload[id] = true;
            }
            plog("sync: photo ", id, " pushing ", ph.path.baseName);
            immutable attempt = ++uploadAttempts;
            uploads[id] = Upload(phash, attempt);
            publishSync();
            bool current() { auto u = id in uploads; return u !is null && u.attempt == attempt; }
            // its own deadline, sized to the file: several pushes share the link, and on a
            // slow uplink (4G at ~100 KiB/s per push) a fixed 5 min cut a 100 MB video that
            // was moving fine — and the reconnect below took the whole link down with it. A
            // link that is really dead is the watchdog's (15 s of silence), not this.
            immutable long sizeHint = ph.digestSize > 0 ? ph.digestSize : 0;
            immutable long deadlineMs = uploadTimeoutMs + sizeHint / 16;   // + 1 s per 16 KiB
            later(deadlineMs > int.max ? int.max : cast(int) deadlineMs, () {
                if (!current())
                    return;
                plog("sync: no answer from the computer in time for photo ", id, " — reconnecting");
                finish(id, false, "timeout", phash, false);
                computer.reconnect();
            });
            computer.uploadFile(ticket, ppath, meta, (r2, e2) {
                if (!current())
                    return;   // timed out, or went with a dropped link
                finish(id, e2.type == JSONType.null_, e2.type == JSONType.null_ ? null : e2.toString(), phash, imported(r2));
            });
            pumpSend();   // the next one goes beside it (up to sendWindow)
            return;
        }
        sending = true;
        publishSync();
        // read + hash + base64 on a thread: 15 MB files would stall the UI here
        auto pr = new shared(Prepared);
        pr.id = id;
        pr.name = ph.path.baseName;
        pr.takenAt = isoTime(ph.takenTs);
        pr.mtimeMs = ph.mtimeMs;
        immutable withFaces = ph.facesScanned && !ph.facesGaveUp && !ph.facesSent;
        pr.knownHash = ph.hash;
        pr.facesJson = withFaces ? facesToJson(ph.faces).toString() : null;
        if (withFaces)
            facesInPayload[id] = true;
        inflight = pr;
        immutable path = ph.path;
        immutable knownHash = ph.hash;
        import core.thread : Thread;
        auto t = new Thread({ useCrashStack(); prepare(pr, path, knownHash); });
        t.name = "prepare";
        t.isDaemon = true;
        t.start();
        prepPoll.start();
    }

    private static void prepare(shared(Prepared)* pr, string path, string knownHash)
    {
        import std.digest.sha : toHexString, LetterCase;
        import photowagon.core.util.fastsha : sha256Of;
        try
        {
            auto bytes = cast(ubyte[]) read(path);
            // the hash of what was READ, always: bytes that differ from the offered hash are
            // other content (onPrepared cancels them as a changed file)
            immutable h = toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
            pr.hash = h;
            // the JSON is assembled here, once: base64 needs no escaping, so it is spliced
            // in as text and the Qt thread never touches these megabytes
            JSONValue head = [
                "name": JSONValue(cast(string) pr.name),
                "takenAt": JSONValue(cast(string) pr.takenAt),
                "mtimeMs": JSONValue(pr.mtimeMs),
                "sha256": JSONValue(h),
            ];
            auto text = head.toString();
            immutable facesPart = (cast(string) pr.facesJson).length ? `,"faces":` ~ cast(string) pr.facesJson : "";
            pr.paramsJson = text[0 .. $ - 1] ~ facesPart ~ `,"base64":"` ~ cast(string) Base64.encode(bytes) ~ `"}`;
        }
        catch (Exception e)
            pr.error = e.msg;
        pr.done = true;
    }

    /// Runs `req` with a deadline; a late answer (after the deadline or a new link) is dropped.
    private void syncRequest(int timeoutMs, void delegate(ResultCb) req, ResultCb cb)
    {
        immutable seq = ++syncRequestSeq;
        syncDeadline.setInterval(timeoutMs);
        syncDeadline.start();
        req((JSONValue r, JSONValue e) {
            if (seq != syncRequestSeq)
                return;
            syncDeadline.stop();
            cb(r, e);
        });
    }

    private void onSyncTimeout()
    {
        if (!sending && !negotiating)
            return;
        syncRequestSeq++;   // the pending callback is now a stranger
        plog("sync: no answer from the computer in time — reconnecting");
        if (sending)
            finish(inflightId, false, "timeout", inflightHash, false);
        negotiating = false;   // a stalled offer must not wedge the queue; startSync retries the batch
        computer.reconnect();
    }

    private long inflightId;
    private string inflightHash;   // the content being sent (completions and timeouts name it)

    /// Qt thread: the file is ready — ask the computer by hash, then send if needed.
    private void onPrepared()
    {
        auto pr = inflight;
        if (pr is null || !pr.done)
            return;
        prepPoll.stop();
        inflight = null;
        immutable id = pr.id;
        if (pr.error.length)
        {
            finish(id, false, pr.error, cast(string) pr.knownHash, false);
            return;
        }
        immutable hash = cast(string) pr.hash;
        immutable known = cast(string) pr.knownHash;
        if (known.length && hash != known)
        {
            finish(id, false, "file_changed: the bytes read are not the offered content", known, false);
            return;
        }
        if (!known.length)
        {
            // first hash: what completions are checked against — unless someone recorded
            // another meanwhile (a manual send read newer bytes): then this read is stale
            auto cur = index.get(id);
            if (cur is null || (cur.hash.length && cur.hash != hash))
            {
                finish(id, false, "file_changed: the photo changed while it was read", hash, false);
                return;
            }
            index.setHash(id, hash);
        }
        inflightId = id;
        inflightHash = hash;
        // The batch negotiation (library.offer) already established the computer wants this
        // one, so no per-photo probe: send the bytes straight away.
        immutable paramsJson = cast(string) pr.paramsJson;
        plog("sync: photo ", id, " sending");
        syncRequest(uploadTimeoutMs, (cb) { computer.requestRaw("library.import", paramsJson, cb); }, (r2, e2) {
            finish(id, e2.type == JSONType.null_, e2.type == JSONType.null_ ? null : e2.toString(), hash, imported(r2));
        });
    }

    // Photos whose faces went (or are going) with their upload, so a successful send also
    // marks the faces delivered.
    private bool[long] facesInPayload;
    private bool facesInFlight;
    private bool facesApiMissing;   // an older computer without library.faces: stop asking
    private MonoTime[long] facesRetryAt;   // a photo whose faces were not taken: skipped until then

    /// Faces computed AFTER their photo was sent (the face pass yields to the sync, so this is
    /// the usual order) go on their own: library.faces {sha256, faces}, one photo at a time,
    /// between uploads. Kicked when a face pass finishes, when the link comes up, and after
    /// each send.
    // Wakes pumpFaces when the earliest backed-off photo is due again: nothing else is
    // guaranteed to kick it on an otherwise idle, healthy link.
    private QTimer facesRetryTimer;

    private void armFacesRetry()
    {
        // forget photos no longer waiting (delivered, given up, deleted from the phone)
        bool[long] still;
        foreach (id; index.facesUnsentIds())
            still[id] = true;
        foreach (id; facesRetryAt.keys)
            if (id !in still)
                facesRetryAt.remove(id);
        if (facesRetryAt.length == 0)
            return;
        immutable now = MonoTime.currTime;
        auto earliest = MonoTime.max;
        foreach (at; facesRetryAt.byValue)
            if (at < earliest)
                earliest = at;
        // a floor: an overdue entry pumpFaces could not take yet (busy, offline) is retried
        // every 2 s, not re-armed at 0 ms in a spin
        enum long floorMs = 2000;
        immutable due = earliest <= now ? 0 : (earliest - now).total!"msecs";
        immutable ms = due < floorMs ? floorMs : due;
        if (facesRetryTimer is null)
        {
            facesRetryTimer = new QTimer(cast(cppq.QObject) null);
            facesRetryTimer.setSingleShot(true);
            facesRetryTimer.connectTimeout(() { pumpFaces(); armFacesRetry(); });
        }
        facesRetryTimer.start(cast(int)(ms < int.max ? ms : int.max));
    }

    private void pumpFaces()
    {
        // held (paused, or data saver on a metered network): faces wait with the photos —
        // resume / Wi-Fi calls startSync, whose run ends in pumpFaces again
        if (facesInFlight || facesApiMissing || busySending || negotiating || !computer.connected || held())
            return;
        immutable now = MonoTime.currTime;
        long id = -1;
        foreach (candidate; index.facesUnsentIds())   // the first one not backing off
            if (auto at = candidate in facesRetryAt)
            {
                if (now >= *at)
                {
                    facesRetryAt.remove(candidate);   // due: out of the backoff (a new failure puts it back)
                    id = candidate;
                    break;
                }
            }
            else
            {
                id = candidate;
                break;
            }
        if (id < 0)
            return;
        auto p = index.get(id);
        if (p is null)
            return;
        facesInFlight = true;
        JSONValue params = ["sha256": JSONValue(p.hash), "faces": facesToJson(p.faces)];
        computer.request("library.faces", params, (r, e) {
            facesInFlight = false;
            // a successful RPC is not a delivery: `taken` says whether the faces were stored
            immutable taken = e.type == JSONType.null_ && r.type == JSONType.object && "taken" in r
                && r["taken"].type == JSONType.true_;
            if (taken)
            {
                facesRetryAt.remove(id);
                index.markFacesSent(id);
                pumpFaces();
                return;
            }
            if (e.type == JSONType.null_)
            {
                immutable reason = r.type == JSONType.object && "reason" in r && r["reason"].type == JSONType.string ? r["reason"].str : "";
                if (reason == "no_vision")
                {
                    facesApiMissing = true;   // this computer stores no faces: stop asking it
                    plog("sync: the computer keeps no faces (no vision); not sending them");
                }
                else
                {
                    // "invalid" / "not_a_photo": retrying cannot change the answer
                    plog("sync: faces for photo ", id, " refused (", reason, "); the computer decides");
                    facesRetryAt.remove(id);
                    index.markFacesGaveUp(id);
                    pumpFaces();
                }
                return;
            }
            immutable code = e.type == JSONType.object && "code" in e && e["code"].type == JSONType.string ? e["code"].str : "";
            if (code == "unknown_method")
            {
                facesApiMissing = true;   // the computer will detect them itself
                plog("sync: the computer has no library.faces; it detects faces itself");
            }
            else
            {
                // not there (yet, or deleted on the computer), busy, refused: back off THIS
                // photo so it cannot block the others, and try it again later
                facesRetryAt[id] = MonoTime.currTime + 10.minutes;
                plog("sync: faces for photo ", id, " not taken (retry in 10 min): ", e.toString());
                armFacesRetry();
                pumpFaces();
            }
        });
    }

    /// Whether an import reply means the computer actually took THESE bytes (and with them the
    /// faces in the request) — not a deduplicated "existed", which reads nothing but the hash.
    private static bool imported(JSONValue r)
    {
        return !(r.type == JSONType.object && "existed" in r && r["existed"].type == JSONType.true_);
    }

    private void finish(long id, bool ok, string error, string hash, bool importedHere)
    {
        if (id in uploads)
            uploads.remove(id);
        else
            sending = false;
        plog("sync: photo ", id, ok ? " sent" : " failed");
        immutable facesWent = (id in facesInPayload) !is null;
        facesInPayload.remove(id);
        if (ok)
        {
            sent++;
            index.markSent(id, hash);
            if (facesWent && importedHere)
                index.markFacesSent(id);   // the upload carried them: drop the embeddings here
            // deduplicated: the faces were not read — pumpFaces sends them on their own
        }
        else if (error.canFind("file_changed") || error.canFind("sha256 mismatch"))
        {
            // A piece read for the push no longer matched the photo's manifest (or the
            // computer found the whole file different): the file changed since it was hashed.
            // The send is cancelled, the digest goes, and the photo is hashed again and
            // offered as what it is now — not counted as a failure.
            index.clearDigest(id, hash);
            plog("sync: photo ", id, " changed since it was hashed — hashing it again: ", error);
        }
        else
        {
            sendFailed++;
            lastSyncError = error;
            index.markFailed(id, hash);
            plog("sync: photo ", id, " failed: ", error);
        }
        pumpSend();
        pumpFaces();
    }
}

unittest
{
    auto a = parseJSON(`{"years":[{"year":2024,"count":2,"months":[{"month":5,"count":2,"days":[{"day":1,"count":2}]}]}]}`);
    auto b = parseJSON(`{"years":[{"year":2024,"count":1,"months":[{"month":5,"count":1,"days":[{"day":3,"count":1}]}]},{"year":2023,"count":1,"months":[{"month":1,"count":1,"days":[{"day":9,"count":1}]}]}]}`);
    auto m = LocalBridge.mergeDates(a, b);
    assert(m["years"].array.length == 2);
    assert(m["years"][0]["year"].integer == 2024 && m["years"][0]["count"].integer == 3);
    assert(m["years"][0]["months"][0]["days"][0]["day"].integer == 3); // newest day first
}
