// LocalBridge — the phone's own library behind the same method names the
// desktop core answers (docs/ipc.md), so `Library` and the QML do not know
// they are on a phone. A TcpBridge inside it reaches the computer, used only
// to send photos there (`photo.upload`, `library.sendAll` → `library.import`).
module photowagon.mobile.localbridge;

import std.base64 : Base64;
import std.conv : to;
import std.file : read;
import std.json;
import std.path : baseName;
import std.stdio : writeln, stdout;

import qt.quick.qtimer;
import cppq = qt.quick.qobject;

import photowagon.core.library.calendar : isoTime;
import photowagon.mobile.phoneindex : PhoneIndex, PhoneFilter, PhonePhoto;
import photowagon.mobile.tcpbridge : TcpBridge;
import photowagon.ui.transport : Bridge, ResultCb;

final class LocalBridge : Bridge
{
    private PhoneIndex index;
    private TcpBridge computer;
    private bool up;
    private QTimer rescan;        // until the permission lands, keep trying
    private int rescanTries;
    private long[] sendQueue;
    private long sent, sendTotal, sendFailed;
    private bool sending;

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
        };
        computer.onEvent = (string ev, JSONValue data) { /* the computer's events are not ours to show */ };
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
        if (index.scan() == 0)
            rescan.start();   // permission dialog probably still open
    }

    /// The first scan finds nothing while the permission dialog is up; poll a while.
    private void retryScan()
    {
        if (++rescanTries > 60 || index.scan() > 0)
            rescan.stop();
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

    // ---- requests, answered here ----------------------------------------------------

    override void request(string method, JSONValue params, ResultCb cb)
    {
        JSONValue result;
        try
            result = handle(method, params, cb);
        catch (Exception e)
        {
            cb(JSONValue(null), error("internal", e.msg));
            return;
        }
        if (result.type != JSONType.null_ || method != "photo.upload")
            cb(result, JSONValue(null));
    }

    private static JSONValue error(string code, string message)
    {
        return JSONValue(["code": JSONValue(code), "message": JSONValue(message)]);
    }

    private static PhoneFilter filterOf(JSONValue p)
    {
        PhoneFilter f;
        if (p.type != JSONType.object)
            return f;
        if (auto y = "year" in p) f.year = cast(int) y.integer;
        if (auto m = "month" in p) f.month = cast(int) m.integer;
        if (auto d = "day" in p) f.day = cast(int) d.integer;
        return f;
    }

    private static long num(JSONValue p, string key, long def = 0)
    {
        if (p.type != JSONType.object) return def;
        auto v = key in p;
        return v && v.type == JSONType.integer ? v.integer : def;
    }

    private JSONValue handle(string method, JSONValue p, ResultCb cb)
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
        case "library.page":
            {
                auto f = filterOf(p);
                immutable offset = num(p, "offset");
                immutable limit = num(p, "limit", 60);
                JSONValue[] items;
                foreach (ref ph; index.page(f, offset, limit))
                    items ~= ph.toJson();
                return JSONValue(["total": JSONValue(index.count(f)), "offset": JSONValue(offset), "items": JSONValue(items)]);
            }
        case "library.dates":
            return index.dates();
        case "photo.get":
            {
                auto ph = index.get(num(p, "id"));
                if (ph is null)
                    throw new Exception("no such photo");
                return ph.toJson();
            }
        case "photo.neighbours":
            {
                auto nb = index.neighbours(num(p, "id"), filterOf(p));
                return JSONValue(["prev": nb[0] ? JSONValue(nb[0]) : JSONValue(null), "next": nb[1] ? JSONValue(nb[1]) : JSONValue(null)]);
            }
        case "album.list":
            return JSONValue(["albums": JSONValue(cast(JSONValue[]) [])]);
        case "p2p.status":
            return JSONValue(["peerId": JSONValue(null), "addrs": JSONValue(cast(JSONValue[]) []), "peers": JSONValue(cast(JSONValue[]) []), "off": JSONValue(true)]);
        case "photo.upload":
            upload(num(p, "id"), cb);
            return JSONValue(null);
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

    // ---- sending to the computer ---------------------------------------------------

    /// Reads the file and hands it to the computer as `library.import`.
    private void upload(long id, ResultCb cb)
    {
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
                writeln("phone: send ", id, " failed: ", e.toString()); stdout.flush();
                if (!computer.connected)
                {
                    sendQueue.length = 0; // stop hammering; the user can retry
                }
            }
            pumpSend();
        });
    }
}
