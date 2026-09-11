// PhoneIndex — the phone's own photos: DCIM/ and Pictures/ scanned in D,
// capture time and orientation from the pure-D EXIF reader, thumbnails
// decoded by Qt (QImageReader, DCT-scaled, EXIF-rotated) into the cache dir.
//
// Decoding runs on a few worker threads (value types and files only); the Qt
// thread merges their results from a timer, so the UI stays responsive and no
// QObject is ever touched off-thread. The index is a JSON file in the app's
// data dir; a rescan only decodes what is new or changed.
module photowagon.mobile.phoneindex;

import photowagon.mobile.plog : plog, timed, useCrashStack;

import qt.quick.qimagereader;
import qt.quick.qimage;
import qt.quick.qsize;
import qt.quick.qtimer;
import cppq = qt.quick.qobject;
import cxxrt : make;

import std.algorithm : sort, remove, SwapStrategy;
import std.conv : to;
import std.digest.sha : sha1Of, toHexString, LetterCase;
import std.file : exists, mkdirRecurse, readText, write, isDir;
import std.json;
import std.path : buildPath, baseName;
import core.sync.mutex : Mutex;
import core.time : MonoTime, seconds;

import photowagon.core.indexer.scan : Candidate, scanImages;
import photowagon.core.library.calendar : dateRange, fileUrl, isoTime, localDate;
import photowagon.core.metadata.exifparse : readExifCore, parseExifTimestamp;

struct PhonePhoto
{
    long id;
    string path;
    long size;
    long mtimeMs;
    long takenTs;
    int width;
    int height;
    int orientation = 1;
    string thumb;   // absolute path of the cached JPEG, or null
    bool sent;      // already delivered to the computer
    string hash;    // sha256 of the file, once computed (for the computer's dedupe)
    int tries;      // failed sends; after `maxTries` the photo waits for a manual retry

    JSONValue toJson() const
    {
        return JSONValue([
            "id": JSONValue(id),
            "hash": hash.length ? JSONValue(hash) : JSONValue(null),
            "path": JSONValue(path),
            "fileUrl": JSONValue(fileUrl(path)),
            "thumbUrl": thumb is null ? JSONValue(null) : JSONValue(fileUrl(thumb)),
            "takenAt": JSONValue(isoTime(takenTs)),
            "takenTs": JSONValue(takenTs),
            "width": JSONValue(width),
            "height": JSONValue(height),
            "orientation": JSONValue(orientation),
            "camera": JSONValue(null),
            "lat": JSONValue(null),
            "lon": JSONValue(null),
            "size": JSONValue(size),
            "remote": JSONValue(false),
            "sent": JSONValue(sent),
        ]);
    }
}

struct PhoneFilter
{
    int year, month, day;
}

enum thumbEdge = 512;

final class PhoneIndex
{
    void delegate() onChanged;                          /// pages/dates are stale
    void delegate(long done, long total) onProgress;   /// decoding progress
    void delegate(long added, long removed) onDone;
    void delegate(size_t found) onScanned;             /// a walk finished

    private string[] roots;
    private string indexFile;
    private string thumbDir;
    private PhonePhoto[] photos;     // newest first
    private PhonePhoto[string] byPath;
    private long nextId = 1;
    private QTimer pump;
    private bool dirty;

    this(string[] roots, string dataDir, string cacheDir)
    {
        this.roots = roots;
        indexFile = buildPath(dataDir, "phone-index.json");
        thumbDir = buildPath(cacheDir, "thumbs");
        mkdirRecurse(dataDir);
        mkdirRecurse(thumbDir);
        lock = new Mutex;
        load();
        pump = new QTimer(cast(cppq.QObject) null);
        pump.setInterval(30);
        pump.connectTimeout(&step);
    }

    string[] rootPaths() const { return roots.dup; }
    size_t length() const { return photos.length; }
    bool busy() const { return processed < queued; }
    bool scanning() { return pump.isActive(); }

    // ---- scanning ------------------------------------------------------------
    //
    // The walk is quick and happens here; decoding is the slow part (a 108 MP
    // photo takes a good fraction of a second), so it runs on worker threads
    // that only touch value types (QImageReader, QImage) and files. The Qt
    // thread drains their results from a timer and is the only one to touch
    // `photos`, the index file and the callbacks.

    private struct Decoded
    {
        Candidate c;
        PhonePhoto p;      // takenTs, orientation, width, height, thumb
        string error;
        uint gen;          // the scan this belongs to; older ones are dropped
    }

    private Mutex lock;
    private Candidate[] work;       // under lock: what the workers still have to decode
    private Decoded[] results;      // under lock: decoded, not yet merged
    private uint generation;
    private int workers;            // under lock: threads alive
    private bool walking;           // under lock: a walk thread is running
    private bool walkDone;          // under lock: `walked` is ready
    private Candidate[] walked;     // under lock
    private long lastProgress;
    private MonoTime started;
    private long queued, processed, added;
    private long lastSaved;
    private MonoTime lastChange;    // the last library.changed while decoding

    enum maxWorkers = 3;

    /// Walks the roots on a thread (2,900 files take 2–3 s on the phone) and,
    /// back on the Qt thread, starts decoding what is new on the workers.
    /// `onScanned(found)` follows; 0 with no readable root usually means the
    /// permission is not granted yet.
    void scan()
    {
        import core.thread : Thread;

        synchronized (lock)
        {
            if (walking)
                return;
            walking = true;
        }
        auto t = new Thread(&walk);
        t.name = "walk";
        t.isDaemon = true;
        t.start();
        pump.start();
    }

    private void walk()
    {
        useCrashStack();
        Candidate[] found;
        try
        {
            foreach (r; roots)
            {
                if (!r.exists || !r.isDir)
                    continue;
                found ~= scanImages(r);
            }
        }
        catch (Exception e)
            plog("phone: walk: ", e.msg);
        synchronized (lock)
        {
            walked = found;
            walkDone = true;
        }
    }

    /// Qt thread: what the walk found against what we know.
    private void afterWalk(Candidate[] found)
    {
        bool[string] seen;
        Candidate[] todo;
        foreach (ref c; found)
        {
            seen[c.path] = true;
            auto known = c.path in byPath;
            if (known && known.size == c.size && known.mtimeMs == c.mtimeMs && known.thumb !is null && known.thumb.exists)
                continue;
            todo ~= c;
        }
        long removed;
        foreach (ref p; photos.dup)
            if (p.path !in seen)
            {
                removed++;
                byPath.remove(p.path);
            }
        if (removed)
        {
            photos = photos.remove!(p => p.path !in seen, SwapStrategy.stable);
            dirty = true;
        }
        synchronized (lock)
        {
            generation++;
            work = todo;
            results.length = 0;
        }
        queued = todo.length;
        processed = 0;
        added = 0;
        lastSaved = 0;
        lastProgress = 0;
        started = MonoTime.currTime;
        plog("phone: ", found.length, " files, ", queued, " to decode, ", removed, " gone");
        if (onProgress) onProgress(0, queued);
        if (queued)
            startWorkers();
        else
        {
            if (dirty) saveNow();
            if (removed && onChanged) onChanged();
            if (onDone) onDone(0, removed);
        }
        if (onScanned) onScanned(found.length);
    }

    private void startWorkers()
    {
        import core.thread : Thread;
        import std.parallelism : totalCPUs;

        immutable want = cast(int) (totalCPUs > 1 ? (totalCPUs - 1 < maxWorkers ? totalCPUs - 1 : maxWorkers) : 1);
        synchronized (lock)
        {
            while (workers < want)
            {
                workers++;
                auto t = new Thread(&worker);
                t.name = "decode";
                t.isDaemon = true;
                t.start();
            }
        }
    }

    /// One worker: takes candidates until there are none, decodes each, posts the result.
    /// One reader and one image for the whole run: the binding never frees a QImage or
    /// a QImageReader (no deleter yet), so one per photo leaked the decoded pixels and an
    /// open file each — 2,000 photos were a gigabyte and a half. Reused, Qt releases the
    /// previous pixels on the next read() and the previous file on the next setFileName().
    private void worker()
    {
        useCrashStack();
        auto reader = make!QImageReader();
        auto img = new QImage();
        for (;;)
        {
            Candidate c;
            uint gen;
            synchronized (lock)
            {
                if (work.length == 0)
                {
                    workers--;
                    return;
                }
                c = work[0];
                work = work[1 .. $];
                gen = generation;
            }
            Decoded d;
            d.c = c;
            d.gen = gen;
            try
                d.p = decode(c, thumbDir, reader, img);
            catch (Exception e)
                d.error = e.msg;
            synchronized (lock)
                results ~= d;
        }
    }

    /// Qt thread, every few ms while decoding: merges what the workers produced.
    private void step() { timed("index.step", 30, { stepTimed(); }); }

    private void stepTimed()
    {
        Decoded[] batch;
        Candidate[] found;
        bool haveWalk, stillWalking;
        synchronized (lock)
        {
            batch = results;
            results = null;
            if (walkDone)
            {
                found = walked;
                walked = null;
                walkDone = false;
                walking = false;
                haveWalk = true;
            }
            stillWalking = walking;
        }
        if (haveWalk)
            afterWalk(found);
        foreach (ref d; batch)
        {
            if (d.gen != generation)
                continue;
            processed++;
            if (d.error.length)
                plog("phone: ", d.c.path, ": ", d.error);
            else
                merge(d);
        }
        if (batch.length && onProgress)
            onProgress(processed, queued);
        if (processed - lastProgress >= 100 || (batch.length && processed >= queued))
        {
            lastProgress = processed;
            import core.memory : GC;
            auto gs = GC.profileStats();
            plog("phone: decoded ", processed, "/", queued, " in ", (MonoTime.currTime - started).total!"msecs" / 1000.0,
                " s; gc ", gs.numCollections, " collections, paused ", gs.totalPauseTime.total!"msecs", " ms, max ",
                gs.maxPauseTime.total!"msecs", " ms; heap ", GC.stats().usedSize / 1048576, " MB");
        }
        if (processed >= queued)
        {
            if (stillWalking)
                return;
            pump.stop();
            sortPhotos();
            saveNow();
            if (onChanged) onChanged();
            if (onDone) onDone(added, 0);
            return;
        }
        // Tell the UI at most every 3 s: each library.changed rebuilds the whole page.
        if (processed - lastSaved >= 25 && MonoTime.currTime - lastChange >= 3.seconds)
        {
            lastSaved = processed;
            lastChange = MonoTime.currTime;
            sortPhotos();
            save();
            if (onChanged) onChanged();
        }
    }

    private void merge(ref Decoded d)
    {
        PhonePhoto p;
        if (auto known = d.c.path in byPath)
            p = *known;
        else
        {
            p.id = nextId++;
            p.path = d.c.path;
        }
        p.size = d.c.size;
        p.mtimeMs = d.c.mtimeMs;
        p.takenTs = d.p.takenTs;
        p.orientation = d.p.orientation;
        p.width = d.p.width;
        p.height = d.p.height;
        p.thumb = d.p.thumb;
        if (d.c.path !in byPath)
        {
            photos ~= p;
            added++;
        }
        else
            foreach (ref q; photos)
                if (q.path == d.c.path)
                    q = p;
        byPath[d.c.path] = p;
        dirty = true;
    }

    /// Worker thread: EXIF and the thumbnail of one file. Touches no shared state.
    private static PhonePhoto decode(Candidate c, string thumbDir, QImageReader reader, QImage img)
    {
        PhonePhoto p;
        auto exif = readExifCore(c.path);
        p.orientation = exif.found ? exif.orientation : 1;
        p.takenTs = exif.found && exif.dateTimeOriginal.length ? parseExifTimestamp(exif.dateTimeOriginal) : 0;
        if (p.takenTs == 0)
        {
            import photowagon.core.metadata.datefromname : dateFromPath;
            immutable named = dateFromPath(c.path);
            p.takenTs = named ? named : c.mtimeMs / 1000;
        }
        immutable thumbPath = buildPath(thumbDir, toHexString!(LetterCase.lower)(sha1Of(c.path ~ "@" ~ c.mtimeMs.to!string)).idup ~ ".jpg");
        int w, h;
        makeThumb(reader, img, c.path, thumbPath, p.orientation, w, h);
        p.width = w;
        p.height = h;
        p.thumb = thumbPath;
        return p;
    }

    /// Decodes `src` scaled so its longest edge is `thumbEdge`, rotated by EXIF,
    /// and writes a JPEG at `dst`. Reports the rotated full-size dimensions.
    private static void makeThumb(QImageReader reader, QImage img, string src, string dst, int orientation, out int width, out int height)
    {
        reader.setFileName(src);
        reader.setAutoTransform(true);
        auto raw = reader.size();
        int rw = raw.width, rh = raw.height;
        if (rw <= 0 || rh <= 0)
            throw new Exception("cannot read image header");
        immutable swap = orientation >= 5;
        width = swap ? rh : rw;
        height = swap ? rw : rh;
        if (dst.exists)
            return;
        // fit the longest edge (of the raw image; the transform only swaps axes)
        int tw = rw, th = rh;
        if (rw >= rh && rw > thumbEdge) { tw = thumbEdge; th = cast(int)(cast(long) rh * thumbEdge / rw); }
        else if (rh > rw && rh > thumbEdge) { th = thumbEdge; tw = cast(int)(cast(long) rw * thumbEdge / rh); }
        auto target = QSize.__make(tw < 1 ? 1 : tw, th < 1 ? 1 : th);
        reader.setScaledSize(target);
        // read() returning QImage by value is mis-bound (sret); the pointer overload is safe
        if (!reader.read(cast(QImage*) img.ptr()) || img.isNull())
            throw new Exception("decode failed");
        if (!img.save(dst, "JPEG".ptr, 84))
            throw new Exception("cannot write thumbnail");
    }

    private void sortPhotos()
    {
        photos.sort!((a, b) => a.takenTs != b.takenTs ? a.takenTs > b.takenTs : a.id > b.id);
    }

    // ---- queries -----------------------------------------------------------------

    private bool matches(ref const PhonePhoto p, PhoneFilter f) const
    {
        if (f.year == 0)
            return true;
        auto r = dateRange(f.year, f.month, f.day);
        return p.takenTs >= r[0] && p.takenTs < r[1];
    }

    long count(PhoneFilter f) const
    {
        long n;
        foreach (ref p; photos)
            if (matches(p, f))
                n++;
        return n;
    }

    const(PhonePhoto)[] page(PhoneFilter f, long offset, long limit) const
    {
        const(PhonePhoto)[] out_;
        long i;
        foreach (ref p; photos)
        {
            if (!matches(p, f))
                continue;
            if (i++ < offset)
                continue;
            out_ ~= p;
            if (out_.length >= limit)
                break;
        }
        return out_;
    }

    const(PhonePhoto)* get(long id) const
    {
        foreach (ref p; photos)
            if (p.id == id)
                return &p;
        return null;
    }

    /// prev = the newer neighbour in display order, next = the older one; 0 = none.
    long[2] neighbours(long id, PhoneFilter f) const
    {
        long prev, next;
        bool found;
        foreach (ref p; photos)
        {
            if (!matches(p, f))
                continue;
            if (found)
            {
                next = p.id;
                break;
            }
            if (p.id == id)
                found = true;
            else
                prev = p.id;
        }
        return found ? [prev, next] : [0L, 0L];
    }

    /// Same shape as the core's library.dates.
    JSONValue dates() const
    {
        JSONValue[] years;
        int curY = -1, curM = -1, curD = -1;
        foreach (ref p; photos) // newest first, so groups are contiguous
        {
            auto d = localDate(p.takenTs);
            if (d[0] != curY)
            {
                years ~= JSONValue(["year": JSONValue(d[0]), "count": JSONValue(0), "months": JSONValue(cast(JSONValue[]) [])]);
                curY = d[0]; curM = -1; curD = -1;
            }
            auto year = &years[$ - 1];
            if (d[1] != curM)
            {
                (*year)["months"].array ~= JSONValue(["month": JSONValue(d[1]), "count": JSONValue(0), "days": JSONValue(cast(JSONValue[]) [])]);
                curM = d[1]; curD = -1;
            }
            auto month = &(*year)["months"].array[$ - 1];
            if (d[2] != curD)
            {
                (*month)["days"].array ~= JSONValue(["day": JSONValue(d[2]), "count": JSONValue(0)]);
                curD = d[2];
            }
            auto day = &(*month)["days"].array[$ - 1];
            (*day)["count"] = JSONValue((*day)["count"].integer + 1);
            (*month)["count"] = JSONValue((*month)["count"].integer + 1);
            (*year)["count"] = JSONValue((*year)["count"].integer + 1);
        }
        return JSONValue(["years": JSONValue(years)]);
    }

    enum maxTries = 3;

    /// Not on the computer yet and not given up on, oldest first (a backup fills in order).
    long[] unsentIds() const
    {
        long[] out_;
        foreach_reverse (ref p; photos)
            if (!p.sent && p.tries < maxTries)
                out_ ~= p.id;
        return out_;
    }

    long unsentCount() const
    {
        long n;
        foreach (ref p; photos)
            if (!p.sent && p.tries < maxTries)
                n++;
        return n;
    }

    void markSent(long id, string hash = null)
    {
        foreach (ref p; photos)
            if (p.id == id)
            {
                p.sent = true;
                p.tries = 0;
                if (hash.length) p.hash = hash;
                byPath[p.path] = p;
            }
        dirty = true;
        save();
    }

    /// A send failed: remember, so a broken file does not block the queue forever.
    void markFailed(long id, string hash = null)
    {
        foreach (ref p; photos)
            if (p.id == id)
            {
                p.tries++;
                if (hash.length) p.hash = hash;
                byPath[p.path] = p;
            }
        dirty = true;
        save();
    }

    /// Give the failed ones another chance (the user asked).
    void resetTries()
    {
        foreach (ref p; photos)
            if (p.tries)
            {
                p.tries = 0;
                byPath[p.path] = p;
                dirty = true;
            }
        if (dirty) save();
    }

    // ---- persistence -----------------------------------------------------------------

    private void load()
    {
        if (!indexFile.exists)
            return;
        try
        {
            auto j = parseJSON(readText(indexFile));
            nextId = j["nextId"].integer;
            foreach (e; j["photos"].array)
            {
                PhonePhoto p;
                p.id = e["id"].integer;
                p.path = e["path"].str;
                p.size = e["size"].integer;
                p.mtimeMs = e["mtime"].integer;
                p.takenTs = e["takenTs"].integer;
                p.width = cast(int) e["w"].integer;
                p.height = cast(int) e["h"].integer;
                p.orientation = cast(int) e["o"].integer;
                p.thumb = e["thumb"].type == JSONType.string ? e["thumb"].str : null;
                p.sent = "sent" in e ? e["sent"].boolean : false;
                p.hash = "hash" in e && e["hash"].type == JSONType.string ? e["hash"].str : null;
                p.tries = "tries" in e ? cast(int) e["tries"].integer : 0;
                photos ~= p;
                byPath[p.path] = p;
            }
            sortPhotos();
        }
        catch (Exception e)
        {
            plog("phone: index unreadable, starting over: ", e.msg);
            photos.length = 0;
            byPath = null;
            nextId = 1;
        }
    }

    private QTimer saveTimer;

    /// Writes the index soon (half a second after the last change): the sync marks a
    /// photo every couple of seconds, and each write is 60–100 ms of JSON on the Qt thread.
    private void save()
    {
        if (saveTimer is null)
        {
            saveTimer = new QTimer(cast(cppq.QObject) null);
            saveTimer.setSingleShot(true);
            saveTimer.setInterval(500);
            saveTimer.connectTimeout(&saveNow);
        }
        saveTimer.start();
    }

    /// Writes the index right away (the end of a scan; the app going away).
    void saveNow()
    {
        if (saveTimer !is null)
            saveTimer.stop();
        timed("index.save", 30, { saveTimed(); });
    }

    private void saveTimed()
    {
        if (!dirty)
            return;
        JSONValue[] arr;
        arr.reserve(photos.length);
        foreach (ref p; photos)
            arr ~= JSONValue([
                "id": JSONValue(p.id), "path": JSONValue(p.path), "size": JSONValue(p.size),
                "mtime": JSONValue(p.mtimeMs), "takenTs": JSONValue(p.takenTs), "w": JSONValue(p.width),
                "h": JSONValue(p.height), "o": JSONValue(p.orientation),
                "thumb": p.thumb is null ? JSONValue(null) : JSONValue(p.thumb), "sent": JSONValue(p.sent), "hash": p.hash.length ? JSONValue(p.hash) : JSONValue(null), "tries": JSONValue(p.tries),
            ]);
        JSONValue j = ["nextId": JSONValue(nextId), "photos": JSONValue(arr)];
        try
        {
            write(indexFile ~ ".tmp", j.toString());
            import std.file : rename;
            rename(indexFile ~ ".tmp", indexFile);
            dirty = false;
        }
        catch (Exception e)
        {
            plog("phone: cannot save index: ", e.msg);
        }
    }
}
