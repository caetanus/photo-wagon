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
import std.file : read;
import std.json;
import std.path : baseName;
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
    private TcpBridge computer;
    private bool up;
    private QTimer rescan;        // until the permission lands, keep trying
    private int rescanTries;
    private bool permissionAsked;
    private QTimer askPermission;
    private long[] sendQueue;
    private long sent, sendTotal, sendFailed;
    private bool sending;

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

    this(PhoneIndex index, TcpBridge computer)
    {
        this.index = index;
        this.computer = computer;
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
        };
        computer.onConnected = (bool ok) {
            emit("computer.link", JSONValue(["connected": JSONValue(ok), "endpoint": JSONValue(computer.endpoint)]));
            emit("library.changed", JSONValue.emptyObject); // the merged timeline changed shape
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
        case "library.sendAll":
            {
                auto ids = index.unsentIds();
                foreach (id; ids)
                    sendQueue ~= id;
                sendTotal += ids.length;
                pumpSend();
                return JSONValue(["queued": JSONValue(ids.length)]);
            }
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
            cb(r, e);
        });
    }

    private void pumpSend()
    {
        if (sending)
            return;
        if (sendQueue.length == 0)
        {
            if (sendTotal)
                emit("upload.done", JSONValue(["sent": JSONValue(sent), "failed": JSONValue(sendFailed), "total": JSONValue(sendTotal)]));
            sent = sendTotal = sendFailed = 0;
            emit("library.changed", JSONValue.emptyObject);
            return;
        }
        immutable id = sendQueue[0];
        sendQueue = sendQueue[1 .. $];
        sending = true;
        emit("upload.progress", JSONValue(["done": JSONValue(sent + sendFailed), "total": JSONValue(sendTotal), "id": JSONValue(id)]));
        upload(id, (r, e) {
            sending = false;
            if (e.type == JSONType.null_)
                sent++;
            else
            {
                sendFailed++;
                plog("phone: send ", id, " failed: ", e.toString());
                if (!computer.connected)
                    sendQueue.length = 0; // stop hammering; the user can retry
            }
            pumpSend();
        });
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
