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

import photowagon.mobile.plog : plog, timed;

import std.algorithm : min;
import std.base64 : Base64;
import std.conv : to;
import std.file : read, exists, readText, write, mkdirRecurse;
import std.json;
import std.path : baseName, buildPath, dirName;
import std.stdio : writeln, stdout;

import qt.quick.qtimer;
import cppq = qt.quick.qobject;

import photowagon.core.library.calendar : isoTime, localDate;
import photowagon.mobile.phoneindex : PhoneIndex, PhoneFilter, PhonePhoto;
import photowagon.mobile.tcpbridge : TcpBridge;
import photowagon.ui.transport : Bridge, ResultCb;

/// Computer photo ids are shifted by this in what the UI sees.
enum long remoteBase = 1_000_000_000L;

final class LocalBridge : Bridge
{
    private PhoneIndex index;
    private Bridge computer;
    private bool up;
    private QTimer rescan;        // until the permission lands, keep trying
    private int rescanTries;
    private bool permissionAsked;
    private QTimer askPermission;
    // ---- sync: every photo not on the computer yet goes there, in the background,
    // whenever a computer is connected. The queue is the index itself (sent / tries
    // per photo, saved after every step), so a crash or a kill loses nothing: the next
    // launch resumes. Reading + hashing + base64 of a file happens on a thread; the
    // computer is asked by hash first and the bytes go only when it lacks them.
    private bool autoSync;             // persisted: files/settings/autosync
    private string autoSyncFile;
    private string syncStatusFile;     // files/settings/sync-status, read by the Java notifier
    private long[] sendQueue;
    private long sent, sendTotal, sendFailed, skipped;
    private bool sending;
    private QTimer prepPoll;           // watches the preparation thread
    private shared(Prepared)* inflight;
    private string lastSyncError;

    private static struct Prepared
    {
        long id;
        string name;
        string takenAt;
        long mtimeMs;
        string hash;
        string base64;
        string error;
        bool done;
    }

    // ---- merged paging state --------------------------------------------------------
    private JSONValue pageParams;      // the filter of the current listing (no offset/limit)
    private PhoneFilter localFilter;
    private bool remoteOnly;           // album / person / favorites: the phone has no such thing
    private long localOff, remoteOff;
    private long remoteTotal = -1;     // -1 = not asked yet
    private bool remoteDone;
    private JSONValue[] localBuf, remoteBuf;
    private JSONValue[] served;        // everything handed out so far, merged order
    private bool[string] localKeys;    // "name|size" of local photos, for dedupe
    private long dupes;
    private string[long] thumbCache;   // remote id → data: URL

    this(PhoneIndex index, Bridge computer, string settingsDir = null)
    {
        this.index = index;
        this.computer = computer;
        if (settingsDir.length)
        {
            autoSyncFile = buildPath(settingsDir, "autosync");
            syncStatusFile = buildPath(settingsDir, "sync-status");
            autoSync = autoSyncFile.exists;
        }
        prepPoll = new QTimer(cast(cppq.QObject) null);
        prepPoll.setInterval(50);
        prepPoll.connectTimeout(&onPrepared);
        index.onChanged = () { emit("library.changed", JSONValue.emptyObject); };
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
        computer.onConnected = (bool ok) {
            emit("computer.link", JSONValue(["connected": JSONValue(ok), "endpoint": JSONValue(computer.endpoint)]));
            emit("library.changed", JSONValue.emptyObject); // the merged timeline changed shape
            if (ok) startSync();
            else publishSync();
        };
        computer.onEvent = (string ev, JSONValue data) {
            if (ev == "library.changed" || ev == "index.done")
                emit("library.changed", JSONValue.emptyObject);
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
            if (found > 0 || rescanTries > 60)
            {
                rescan.stop();
                return;
            }
            // nothing readable: the permission is missing. Ask once the window has had
            // its first frames (asking during Qt's startup left the window black), then
            // keep looking for a while.
            if (!permissionAsked)
            {
                permissionAsked = true;
                askPermission = new QTimer(cast(cppq.QObject) null);
                askPermission.setSingleShot(true);
                askPermission.setInterval(900);
                askPermission.connectTimeout({
                    import qt.quick.qdesktopservices : QDesktopServices;
                    import qt.quick.qurl : QUrl;
                    auto u = QUrl("pwperm://request", QUrl.ParsingMode.TolerantMode);
                    QDesktopServices.openUrl(u);
                });
                askPermission.start();
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
    override void setEndpoint(string host, ushort port) { computer.setEndpoint(host, port); }

    private void emit(string ev, JSONValue data)
    {
        if (onEvent)
            onEvent(ev, data);
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
        return f;
    }

    // ---- requests -------------------------------------------------------------------

    override void request(string method, JSONValue params, ResultCb cb)
    {
        try
        {
            switch (method)
            {
            case "library.page":    timed("library.page", 30, { page(params, cb); }); return;
            case "library.dates":   timed("library.dates", 30, { dates(cb); }); return;
            case "photo.get":       get(num(params, "id"), cb); return;
            case "photo.upload":    upload(num(params, "id"), cb); return;
            case "album.list":      albums(cb); return;
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
        case "photo.neighbours":
            {
                immutable id = num(p, "id");
                long prev, next;
                foreach (i, ref it; served)
                    if (it["id"].integer == id)
                    {
                        if (i > 0) prev = served[i - 1]["id"].integer;
                        if (i + 1 < served.length) next = served[i + 1]["id"].integer;
                        break;
                    }
                return JSONValue(["prev": prev ? JSONValue(prev) : JSONValue(null), "next": next ? JSONValue(next) : JSONValue(null)]);
            }
        case "p2p.status":
            return JSONValue(["peerId": JSONValue(null), "addrs": JSONValue(cast(JSONValue[]) []), "peers": JSONValue(cast(JSONValue[]) []), "off": JSONValue(true)]);
        case "library.sendAll":       // turns the automatic sync on and starts it now
            {
                setAutoSync(true);
                index.resetTries();
                immutable n = index.unsentCount();
                startSync();
                return JSONValue(["queued": JSONValue(n)]);
            }
        case "library.autoSync":      // {on}
            {
                setAutoSync(p.type == JSONType.object && "on" in p && p["on"].type == JSONType.true_);
                if (autoSync) startSync();
                else { sendQueue.length = 0; publishSync(); }
                return syncStatus();
            }
        case "library.syncStatus":
            return syncStatus();
        default:
            throw new Exception("not available on the phone: " ~ method);
        }
    }

    // ---- the merged timeline -----------------------------------------------------------

    private void page(JSONValue p, ResultCb cb)
    {
        immutable offset = num(p, "offset");
        immutable limit = cast(size_t) num(p, "limit", 60);
        if (offset == 0 || served.length == 0)
            resetPaging(p);
        fillPage(limit, cb);
    }

    private void resetPaging(JSONValue p)
    {
        pageParams = JSONValue.emptyObject;
        foreach (key; ["year", "month", "day", "albumId", "personId", "rootId", "favorites"])
            if (p.type == JSONType.object)
                if (auto v = key in p)
                    pageParams[key] = *v;
        localFilter = filterOf(p);
        remoteOnly = num(p, "albumId") || num(p, "personId") || flag(p, "favorites");
        localOff = remoteOff = 0;
        remoteTotal = -1;
        remoteDone = !computer.connected;
        localBuf.length = 0;
        remoteBuf.length = 0;
        served.length = 0;
        dupes = 0;
        localKeys = null;
        foreach (ref ph; index.page(PhoneFilter.init, 0, long.max))
            localKeys[ph.path.baseName ~ "|" ~ ph.size.to!string] = true;
    }

    private void fillPage(size_t limit, ResultCb cb)
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
            computer.request("library.page", params, (r, e) {
                if (e.type != JSONType.null_)
                    remoteDone = true;
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
                        if (key in localKeys)
                        {
                            dupes++;
                            continue; // the local copy stands for it
                        }
                        remoteBuf ~= toPhoneItem(it);
                    }
                }
                mergeAndAnswer(limit, cb);
            });
            return;
        }
        mergeAndAnswer(limit, cb);
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

    private void mergeAndAnswer(size_t limit, ResultCb cb)
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
        long total = remoteOnly ? 0 : index.count(localFilter);
        if (remoteTotal > 0)
            total += remoteTotal - dupes;
        if (total < served.length)
            total = served.length;
        immutable totalFinal = total;
        withRemoteThumbs(out_, () {
            cb(JSONValue(["total": JSONValue(totalFinal), "offset": JSONValue(served.length), "items": JSONValue(out_)]), JSONValue(null));
        });
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
                it["thumbUrl"] = *t;
            else
                want ~= JSONValue(rid);
        }
        if (want.length == 0 || !computer.connected)
        {
            done();
            return;
        }
        JSONValue params = JSONValue.emptyObject;
        params["ids"] = JSONValue(want);
        computer.request("library.thumbs", params, (r, e) {
            if (e.type == JSONType.null_ && "thumbs" in r)
                foreach (key, b64; r["thumbs"].object)
                    thumbCache[key.to!long] = "data:image/jpeg;base64," ~ b64.str;
            foreach (ref it; items)
                if (it["id"].integer >= remoteBase)
                    if (auto t = (it["id"].integer - remoteBase) in thumbCache)
                        it["thumbUrl"] = *t;
            // also patch what was served, so neighbours/viewer see the thumbs
            foreach (ref it; served)
                if (it["id"].integer >= remoteBase && it["thumbUrl"].type == JSONType.null_)
                    if (auto t = (it["id"].integer - remoteBase) in thumbCache)
                        it["thumbUrl"] = *t;
            done();
        });
    }

    private void dates(ResultCb cb)
    {
        auto local = index.dates();
        if (!computer.connected)
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
                cb(ph.toJson(), JSONValue(null));
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
                if (e2.type == JSONType.null_)
                    item["fileUrl"] = "data:" ~ f["mime"].str ~ ";base64," ~ f["base64"].str;
                else if (item["thumbUrl"].type == JSONType.string)
                    item["fileUrl"] = item["thumbUrl"];
                cb(item, JSONValue(null));
            });
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
        computer.request("library.import", params, (r, e) {
            if (e.type == JSONType.null_)
                index.markSent(id);
            else
                index.markFailed(id);
            cb(r, e);
        });
    }

    // ---- sync engine ------------------------------------------------------------------

    private void setAutoSync(bool on)
    {
        autoSync = on;
        if (autoSyncFile.length)
        {
            try
            {
                if (on) write(autoSyncFile, "1");
                else if (autoSyncFile.exists) { import std.file : remove; remove(autoSyncFile); }
            }
            catch (Exception e)
                plog("sync: cannot save setting: ", e.msg);
        }
    }

    JSONValue syncStatus()
    {
        immutable pending = index.unsentCount() + (sending ? 0 : 0);
        return JSONValue([
            "enabled": JSONValue(autoSync),
            "connected": JSONValue(computer.connected),
            "active": JSONValue(sending || sendQueue.length > 0),
            "pending": JSONValue(pending),
            "total": JSONValue(sendTotal),
            "done": JSONValue(sent + sendFailed + skipped),
            "sent": JSONValue(sent),
            "skipped": JSONValue(skipped),
            "failed": JSONValue(sendFailed),
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
                mkdirRecurse(syncStatusFile.dirName);
                write(syncStatusFile, st.toString());
            }
            catch (Exception e)
                plog("sync: cannot write status: ", e.msg);
        }
    }

    /// Queue what is missing on the computer and start, if allowed and connected.
    private void startSync()
    {
        if (!autoSync || !computer.connected)
        {
            publishSync();
            return;
        }
        bool[long] queued;
        foreach (id; sendQueue) queued[id] = true;
        auto ids = index.unsentIds();
        long added;
        foreach (id; ids)
            if (id !in queued && !(sending && inflight !is null && inflight.id == id))
            {
                sendQueue ~= id;
                added++;
            }
        if (!sending && sendQueue.length && sendTotal == 0)
        {
            sent = sendFailed = skipped = 0;
            lastSyncError = null;
        }
        sendTotal += added;
        publishSync();
        pumpSend();
    }

    private void pumpSend()
    {
        if (sending)
            return;
        if (sendQueue.length == 0)
        {
            if (sendTotal)
            {
                emit("upload.done", JSONValue(["sent": JSONValue(sent), "failed": JSONValue(sendFailed), "total": JSONValue(sendTotal)]));
                plog("sync: done — ", sent, " sent, ", skipped, " already there, ", sendFailed, " failed");
                emit("library.changed", JSONValue.emptyObject);
            }
            sent = sendTotal = sendFailed = skipped = 0;
            publishSync();
            return;
        }
        if (!computer.connected)
        {
            sendQueue.length = 0;   // resumes on the next connection (startSync)
            publishSync();
            return;
        }
        immutable id = sendQueue[0];
        sendQueue = sendQueue[1 .. $];
        auto ph = index.get(id);
        if (ph is null)
        {
            pumpSend();
            return;
        }
        sending = true;
        emit("upload.progress", JSONValue(["done": JSONValue(sent + sendFailed + skipped), "total": JSONValue(sendTotal), "id": JSONValue(id)]));
        publishSync();
        // read + hash + base64 on a thread: 15 MB files would stall the UI here
        auto pr = new shared(Prepared);
        pr.id = id;
        pr.name = ph.path.baseName;
        pr.takenAt = isoTime(ph.takenTs);
        pr.mtimeMs = ph.mtimeMs;
        inflight = pr;
        immutable path = ph.path;
        immutable knownHash = ph.hash;
        import core.thread : Thread;
        auto t = new Thread({ prepare(pr, path, knownHash); });
        t.isDaemon = true;
        t.start();
        prepPoll.start();
    }

    private static void prepare(shared(Prepared)* pr, string path, string knownHash)
    {
        import std.digest.sha : sha256Of, toHexString, LetterCase;
        try
        {
            auto bytes = cast(ubyte[]) read(path);
            immutable h = knownHash.length ? knownHash : toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
            pr.hash = h;
            pr.base64 = cast(string) Base64.encode(bytes);
        }
        catch (Exception e)
            pr.error = e.msg;
        pr.done = true;
    }

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
            finish(id, false, pr.error, null);
            return;
        }
        immutable hash = cast(string) pr.hash;
        JSONValue probe = ["name": JSONValue(cast(string) pr.name), "sha256": JSONValue(hash), "probe": JSONValue(true)];
        computer.request("library.import", probe, (r, e) {
            if (e.type == JSONType.null_ && r.type == JSONType.object && "existed" in r && r["existed"].type == JSONType.true_)
            {
                skipped++;
                index.markSent(id, hash);
                sending = false;
                pumpSend();
                return;
            }
            JSONValue params = [
                "name": JSONValue(cast(string) pr.name),
                "takenAt": JSONValue(cast(string) pr.takenAt),
                "mtimeMs": JSONValue(pr.mtimeMs),
                "sha256": JSONValue(hash),
                "base64": JSONValue(cast(string) pr.base64),
            ];
            computer.request("library.import", params, (r2, e2) {
                finish(id, e2.type == JSONType.null_, e2.type == JSONType.null_ ? null : e2.toString(), hash);
            });
        });
    }

    private void finish(long id, bool ok, string error, string hash)
    {
        sending = false;
        if (ok)
        {
            sent++;
            index.markSent(id, hash);
        }
        else
        {
            sendFailed++;
            lastSyncError = error;
            index.markFailed(id, hash);
            plog("sync: photo ", id, " failed: ", error);
        }
        pumpSend();
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
