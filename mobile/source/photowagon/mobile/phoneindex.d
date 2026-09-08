// PhoneIndex — the phone's own photos: DCIM/ and Pictures/ scanned in D,
// capture time and orientation from the pure-D EXIF reader, thumbnails
// decoded by Qt (QImageReader, DCT-scaled, EXIF-rotated) into the cache dir.
//
// Work happens on the Qt thread, one photo per zero-interval timer tick, so
// the UI stays responsive and no Qt object is ever touched off-thread. The
// index is a JSON file in the app's data dir; a rescan only decodes what is
// new or changed.
module photowagon.mobile.phoneindex;

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
import std.stdio : writeln, stdout;

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

    JSONValue toJson() const
    {
        return JSONValue([
            "id": JSONValue(id),
            "hash": JSONValue(null),
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

    private string[] roots;
    private string indexFile;
    private string thumbDir;
    private PhonePhoto[] photos;     // newest first
    private PhonePhoto[string] byPath;
    private long nextId = 1;
    private Candidate[] queue;
    private long queued, processed, added;
    private QTimer pump;
    private bool dirty;

    this(string[] roots, string dataDir, string cacheDir)
    {
        this.roots = roots;
        indexFile = buildPath(dataDir, "phone-index.json");
        thumbDir = buildPath(cacheDir, "thumbs");
        mkdirRecurse(dataDir);
        mkdirRecurse(thumbDir);
        load();
        pump = new QTimer(cast(cppq.QObject) null);
        pump.setInterval(0);
        pump.connectTimeout(&step);
    }

    string[] rootPaths() const { return roots.dup; }
    size_t length() const { return photos.length; }
    bool busy() const { return queue.length > processed - (queued - queue.length); }
    bool scanning() { return pump.isActive(); }

    // ---- scanning ------------------------------------------------------------

    /// Walks the roots now (fast) and starts decoding what is new, one per tick.
    /// Returns how many files were found; 0 with no readable root usually means
    /// the permission is not granted yet.
    size_t scan()
    {
        Candidate[] found;
        foreach (r; roots)
        {
            if (!r.exists || !r.isDir)
                continue;
            found ~= scanImages(r);
        }
        bool[string] seen;
        queue.length = 0;
        foreach (ref c; found)
        {
            seen[c.path] = true;
            auto known = c.path in byPath;
            if (known && known.size == c.size && known.mtimeMs == c.mtimeMs && known.thumb !is null && known.thumb.exists)
                continue;
            queue ~= c;
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
        queued = queue.length;
        processed = 0;
        added = 0;
        writeln("phone: ", found.length, " files, ", queue.length, " to decode, ", removed, " gone"); stdout.flush();
        if (onProgress) onProgress(0, queued);
        if (queue.length)
            pump.start();
        else
        {
            if (dirty) save();
            if (removed && onChanged) onChanged();
            if (onDone) onDone(0, removed);
        }
        return found.length;
    }

    private void step()
    {
        if (queue.length == 0)
        {
            pump.stop();
            sortPhotos();
            save();
            if (onChanged) onChanged();
            if (onDone) onDone(added, 0);
            return;
        }
        auto c = queue[0];
        queue = queue[1 .. $];
        processed++;
        try
            index(c);
        catch (Exception e)
        {
            writeln("phone: ", c.path, ": ", e.msg); stdout.flush();
        }
        if (onProgress) onProgress(processed, queued);
        if (processed % 25 == 0)
        {
            sortPhotos();
            save();
            if (onChanged) onChanged();
        }
    }

    private void index(Candidate c)
    {
        PhonePhoto p;
        if (auto known = c.path in byPath)
            p = *known;
        else
        {
            p.id = nextId++;
            p.path = c.path;
        }
        p.size = c.size;
        p.mtimeMs = c.mtimeMs;

        auto exif = readExifCore(c.path);
        p.orientation = exif.found ? exif.orientation : 1;
        p.takenTs = exif.found && exif.dateTimeOriginal.length ? parseExifTimestamp(exif.dateTimeOriginal) : 0;
        if (p.takenTs == 0)
            p.takenTs = c.mtimeMs / 1000;

        immutable thumbPath = buildPath(thumbDir, toHexString!(LetterCase.lower)(sha1Of(c.path ~ "@" ~ c.mtimeMs.to!string)).idup ~ ".jpg");
        int w, h;
        makeThumb(c.path, thumbPath, p.orientation, w, h);
        p.width = w;
        p.height = h;
        p.thumb = thumbPath;

        if (c.path !in byPath)
        {
            photos ~= p;
            added++;
        }
        else
            foreach (ref q; photos)
                if (q.path == c.path)
                    q = p;
        byPath[c.path] = p;
        dirty = true;
    }

    /// Decodes `src` scaled so its longest edge is `thumbEdge`, rotated by EXIF,
    /// and writes a JPEG at `dst`. Reports the rotated full-size dimensions.
    private static void makeThumb(string src, string dst, int orientation, out int width, out int height)
    {
        auto reader = make!QImageReader();
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
        auto img = new QImage();
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

    long[] unsentIds() const
    {
        long[] out_;
        foreach (ref p; photos)
            if (!p.sent)
                out_ ~= p.id;
        return out_;
    }

    void markSent(long id)
    {
        foreach (ref p; photos)
            if (p.id == id)
            {
                p.sent = true;
                byPath[p.path] = p;
            }
        dirty = true;
        save();
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
                photos ~= p;
                byPath[p.path] = p;
            }
            sortPhotos();
        }
        catch (Exception e)
        {
            writeln("phone: index unreadable, starting over: ", e.msg); stdout.flush();
            photos.length = 0;
            byPath = null;
            nextId = 1;
        }
    }

    private void save()
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
                "thumb": p.thumb is null ? JSONValue(null) : JSONValue(p.thumb), "sent": JSONValue(p.sent),
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
            writeln("phone: cannot save index: ", e.msg); stdout.flush();
        }
    }
}
