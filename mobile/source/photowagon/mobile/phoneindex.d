// PhoneIndex — the phone's own photos: DCIM/ and Pictures/ scanned in D,
// capture time and orientation from the pure-D EXIF reader, thumbnails
// decoded by Qt (QImageReader, DCT-scaled, EXIF-rotated) into the data dir.
//
// Decoding runs on the Qt thread in time-bounded slices (a timer yields to the
// event loop between slices) — never on worker threads: QImageReader/QImage off
// the Qt thread loses the GL surface on Adreno (black window, app still alive).
// Video frames come from the Android platform via the JNI shim (videothumb.c).
// The index is a JSON file in the app's data dir; a rescan only decodes what is
// new or changed.
module photowagon.mobile.phoneindex;

import photowagon.mobile.plog : plog, timed, useCrashStack;

import qt.quick.qimagereader;
import qt.quick.qimage;
import qt.quick.qsize;
import qt.quick.qtimer;
import cppq = qt.quick.qobject;
import cxxrt : make;

import std.algorithm : sort, remove, SwapStrategy, startsWith;
import std.conv : to;
import std.digest.sha : sha1Of, toHexString, LetterCase;
import std.base64 : Base64;
import std.file : exists, mkdirRecurse, readText, write, isDir;
import std.json;
import std.path : buildPath, baseName;
import core.sync.mutex : Mutex;
import core.time : Duration, MonoTime, seconds;

import photowagon.core.indexer.scan : Candidate, scanImages;
import photowagon.core.library.calendar : dateRange, fileUrl, isoTime, localDate;
import photowagon.core.metadata.exifparse : readExifCore, parseExifTimestamp;
import photowagon.core.library.kind : classify, Signals;
import photowagon.core.thumbs.imagestats : ImageStats, statsOf;

// videothumb.c: a representative frame of a video, saved as a JPEG scaled to fit
// maxSize, via the Android MediaMetadataRetriever. Returns the duration in ms
// (>= 0) or -1 on failure. `env` is a JNIEnv* from QJniEnvironment.getJniEnv().
private extern(C) long pw_video_thumb(void* env, const(char)* videoPath, const(char)* outPath, int maxSize);

// facelite.c: on-device face detection + ArcFace-r100 512-d embeddings via LiteRT, so the
// phone enriches its own photos offline in the SAME embedding space as the desktop (they
// cluster together). Android only — the desktop test build has no libLiteRt, so every call
// is version(Android)-guarded and the desktop simply carries no phone-side faces.
enum faceEmbDim = 512;
struct DetectedFace
{
    float x, y, w, h;                 // box as fractions of the (rotated) image
    float score;
    float[faceEmbDim] embedding;      // r100 feature, L2-normalised
}
version (Android)
{
    // struct layout must match facelite.c's PwFace {float x,y,w,h,score; float embedding[512];}
    private extern(C) int pw_facelite_init(const(char)* yunetTflite, const(char)* r100Tflite);
    private extern(C) int pw_facelite_detect(const(ubyte)* rgb, int w, int h, int stride, DetectedFace* outFaces, int maxFaces);
}

// Faces persist in the phone index (base64 of the raw embedding floats) until the sync hands
// them to the computer, which stores them in its faces table instead of re-detecting.
JSONValue facesToJson(const DetectedFace[] faces)
{
    // Always an array: an EMPTY one is a completed scan that found nobody — the computer
    // records the photo as scanned instead of re-detecting it. Senders include the key only
    // for photos the pass has scanned (facesScanned).
    JSONValue[] arr;
    foreach (ref fc; faces)
        arr ~= JSONValue([
            "x": JSONValue(fc.x), "y": JSONValue(fc.y), "w": JSONValue(fc.w), "h": JSONValue(fc.h),
            "score": JSONValue(fc.score),
            "emb": JSONValue(cast(string) Base64.encode(cast(const(ubyte)[]) fc.embedding[])),
        ]);
    return JSONValue(arr);
}

private DetectedFace[] facesFromJson(JSONValue arr)
{
    // a whole number is written without a fraction ("0"), which parses back as an integer
    static float num(JSONValue v)
    {
        return v.type == JSONType.integer ? cast(float) v.integer : cast(float) v.floating;
    }
    DetectedFace[] faces;
    foreach (fe; arr.array)
    {
        DetectedFace fc;
        fc.x = num(fe["x"]); fc.y = num(fe["y"]);
        fc.w = num(fe["w"]); fc.h = num(fe["h"]);
        fc.score = num(fe["score"]);
        auto bytes = Base64.decode(fe["emb"].str);
        if (bytes.length == faceEmbDim * float.sizeof)
            (cast(ubyte*) fc.embedding.ptr)[0 .. bytes.length] = bytes[];
        faces ~= fc;
    }
    return faces;
}

/// Faces per photo the phone hands over: the computer's per-photo batch limit (parseFaceHits).
enum maxDeviceFaces = 64;

version (Android)
{
    /// The one thread that owns facelite: it initialises the models and runs every detection,
    /// one photo at a time (the model state is not shared with any other thread). The Qt
    /// thread submits a packed RGB image and later takes the result; neither side ever waits
    /// on the other except for the handful of instructions under the mutex.
    private final class FaceWorker
    {
        import core.sync.condition : Condition;
        import core.sync.mutex : Mutex;
        import core.thread : Thread;

        private Mutex m;
        private Condition cv;
        private Thread t;
        private string yunet, r100;
        private bool initDone, initOk;
        private bool busy;                 // a job submitted and not yet taken back
        private bool hasJob, hasResult;
        private long jobId, resId;
        private ubyte[] rgb;
        private int jw, jh;
        private DetectedFace[] resFaces;
        private bool resOk, resOverflow;

        this(string yunet, string r100)
        {
            this.yunet = yunet;
            this.r100 = r100;
            m = new Mutex;
            cv = new Condition(m);
            t = new Thread(&run);
            t.isDaemon = true;
            t.start();
        }

        /// Init finished and failed: the pass must stop.
        bool initFailed()
        {
            synchronized (m)
                return initDone && !initOk;
        }

        /// Ready for a new photo (initialised, nothing in flight).
        bool idle()
        {
            synchronized (m)
                return initDone && initOk && !busy;
        }

        void submit(long id, ubyte[] pixels, int w, int h)
        {
            synchronized (m)
            {
                if (busy || !initOk)
                    return;
                busy = true;
                hasJob = true;
                jobId = id;
                rgb = pixels;
                jw = w;
                jh = h;
                cv.notify();
            }
        }

        /// A finished photo, if there is one: its id, faces and whether detection succeeded.
        bool take(out long id, out DetectedFace[] faces, out bool ok, out bool overflow)
        {
            synchronized (m)
            {
                if (!hasResult)
                    return false;
                hasResult = false;
                busy = false;
                id = resId;
                faces = resFaces;
                ok = resOk;
                overflow = resOverflow;
                resFaces = null;
                return true;
            }
        }

        private void run()
        {
            import std.string : toStringz;

            immutable ok = pw_facelite_init(yunet.toStringz, r100.toStringz) == 0;
            synchronized (m)
            {
                initDone = true;
                initOk = ok;
            }
            if (!ok)
                return;
            plog("phone: on-device faces ready (YuNet + r100)");
            for (;;)
            {
                long id;
                ubyte[] px;
                int w, h;
                synchronized (m)
                {
                    while (!hasJob)
                        cv.wait();
                    hasJob = false;
                    id = jobId;
                    px = rgb;
                    rgb = null;
                    w = jw;
                    h = jh;
                }
                // As many as the computer accepts in one batch; a photo that FILLS the buffer
                // may hold more — that is not a complete scan (see applyFaces).
                auto buf = new DetectedFace[maxDeviceFaces];
                immutable n = pw_facelite_detect(px.ptr, w, h, w * 3, buf.ptr, cast(int) buf.length);
                synchronized (m)
                {
                    hasResult = true;
                    resId = id;
                    resOverflow = n >= cast(int) buf.length;
                    resOk = n >= 0 && !resOverflow;
                    resFaces = resOk && n > 0 ? buf[0 .. n] : null;
                }
            }
        }
    }
}

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
    bool declined;  // the computer turned this hash away (deleted there): never offer it again
    string hash;    // sha256 of the file, once computed (for the computer's dedupe)
    string pieces;  // its piece hashes (base64, core/sync/digest.d): the push's manifest, never re-read
    string fp;      // its fingerprint (size + 8 sampled 4 KiB blocks): "still the same file?"
    long digestSize;  // the size the digest (hash, pieces) was computed for
    int tries;      // failed sends; after `maxTries` the photo waits for a manual retry
    bool isVideo;   // a camera video: no frame thumbnail here (the computer makes one on sync)
    long durationMs;
    string kind;    // photo | screenshot | meme (kind.d); "" = not classified yet
    DetectedFace[] faces;   // on-device faces (bbox + r100 embedding), until synced to the computer
    bool facesScanned;      // the on-device face pass has run on this photo (even if 0 faces)
    bool facesSent;         // the computer has them: the embeddings are dropped here (index size)
    bool facesGaveUp;       // the pass could not finish this photo: send NO faces, the computer detects

    JSONValue toJson() const
    {
        return JSONValue([
            "id": JSONValue(id),
            "hash": hash.length ? JSONValue(hash) : JSONValue(null),
            "path": JSONValue(path),
            "fileUrl": JSONValue(fileUrl(path)),
            "thumbUrl": thumb is null ? JSONValue(null) : JSONValue(fileUrl(thumb)),
            "video": JSONValue(isVideo),
            "duration": JSONValue(durationMs),
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
            "kind": kind.length ? JSONValue(kind) : JSONValue("photo"),
        ]);
    }
}

struct PhoneFilter
{
    int year, month, day;
    string kind;   // "" any · "video" · "screenshot" · "photo" (neither)
    bool hideSent; // leave out the photos the computer already has ("Hide imported photos")
}

enum thumbEdge = 512;

final class PhoneIndex
{
    void delegate() onChanged;                          /// pages/dates are stale
    void delegate() onFacesReady;                       /// a photo's face pass finished: sync can hand them over
    void delegate(long done, long total) onProgress;   /// decoding progress
    void delegate(long added, long removed) onDone;
    void delegate(size_t found) onScanned;             /// a walk finished
    /// When this returns true, the decode slice yields for this tick: a sync push is in
    /// flight and heavy QImageReader work on the Qt thread would starve the socket (the
    /// video-push drops we saw) and jank the UI. Indexing resumes the moment the push ends.
    bool delegate() shouldYield;

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
        // Thumbnails live under the PERSISTENT data dir, not the cache dir: Android evicts
        // CacheLocation under storage pressure, and losing 2,900 thumbnails made every start
        // re-decode them all — the heap ballooned, the OS OOM-killed the app, it restarted and
        // re-decoded again, a spiral that also starved the photo sync of CPU. cacheDir is kept
        // in the signature for callers/tests but no longer holds anything we cannot rebuild.
        thumbDir = buildPath(dataDir, "thumbs");
        cast(void) cacheDir;
        mkdirRecurse(dataDir);
        mkdirRecurse(thumbDir);
        {
            import photowagon.mobile.atomicfile : sweepTemporaries;

            // what a killed process left half-written
            if (immutable n = sweepTemporaries(thumbDir) + sweepTemporaries(dataDir))
                plog("phone: removed ", n, " unfinished temporary file(s)");
        }
        lock = new Mutex;
        saver = new IndexSaver;
        load();
        version (Android)
            facesInit(dataDir);
        pump = new QTimer(cast(cppq.QObject) null);
        pump.setInterval(50);   // more breathing room between decode slices so scrolling/rendering
                                // stays smooth (a single big-image decode can blow a frame; a wider
                                // gap between ticks keeps the UI fluid). Indexing is a touch slower.
        pump.connectTimeout(&step);
    }

    private bool facesReady;              // on-device face models loaded (Android only)
    private string faceYunet, faceR100;   // extracted model paths

    // Initialise facelite with the bundled YuNet + r100 tflite models. CoreService extracts
    // them from the APK assets to <dataDir>/models (atomically, on a thread of its own: the
    // windowless service process has no Qt assets:/ engine, and a 120 MB copy on its main
    // thread risks an ANR) — so on a fresh install they may not be there yet: look again every
    // few seconds until they are. Android only — no libLiteRt on the desktop test build.
    version (Android)
    private void facesInit(string dataDir)
    {
        immutable mdir = buildPath(dataDir, "models");
        faceYunet = buildPath(mdir, "yunet.tflite");
        faceR100 = buildPath(mdir, "r100.tflite");
        if (faceYunet.exists && faceR100.exists)
        {
            // The worker initialises facelite on ITS thread and runs every detect there: the
            // model state is touched by exactly one thread. An init failure is reported by
            // faceWorker.initFailed and stops the pass (stepFaces).
            faceWorker = new FaceWorker(faceYunet, faceR100);
            facesReady = true;
            plog("phone: on-device faces starting (YuNet + r100 on the face worker)");
            facesPump = new QTimer(cast(cppq.QObject) null);
            facesPump.setInterval(1200);   // r100 is heavy; a relaxed cadence keeps it gentle
            facesPump.connectTimeout(&stepFaces);
            facesPump.start();
            if (facesWait !is null)
                facesWait.stop();
            return;
        }
        if (facesWait is null)
        {
            plog("phone: on-device face models not extracted yet — waiting for them");
            facesWait = new QTimer(cast(cppq.QObject) null);
            facesWait.setInterval(3000);
            facesWait.connectTimeout({
                if (++facesWaits > 200)   // ten minutes: the extraction failed
                {
                    facesWait.stop();
                    plog("phone: on-device faces unavailable (models missing) — computer detects on sync");
                    return;
                }
                facesInit(dataDir);
            });
            facesWait.start();
        }
    }

    version (Android) private QTimer facesWait;
    version (Android) private int facesWaits;

    version (Android) private FaceWorker faceWorker;

    // The decoded (EXIF-rotated) thumbnail as tightly packed RGB888 bytes the worker can own.
    // On the Qt thread (touching QImage off it loses the Adreno surface — same rule as decoding).
    version (Android)
    private static ubyte[] rgbOf(QImage img, out int w, out int h)
    {
        if (img.isNull())
            return null;
        // This is the face pass's private scratch image. Convert in place:
        // DSide's QImage-by-value return from convertToFormat is mis-bound (sret).
        if (img.format() != QImage.Format.Format_RGB888)
            img.convertTo(QImage.Format.Format_RGB888, 0);
        if (img.isNull())
            return null;
        w = img.width();
        h = img.height();
        if (w <= 0 || h <= 0)
            return null;
        immutable stride = cast(size_t) img.bytesPerLine();
        immutable row = cast(size_t) w * 3;
        auto src = img.constBits();
        auto rgb = new ubyte[row * h];
        foreach (y; 0 .. h)
            rgb[y * row .. (y + 1) * row] = src[y * stride .. y * stride + row];
        return rgb;
    }

    private QTimer facesPump;
    private QImageReader facesReader;
    private QImage facesImg;
    private bool facesDecodeReady;

    // Charging / plugged in? Reads /sys/class/power_supply. Anything we cannot read — no
    // status file, a denied directory — counts as NOT charging: on a phone the CPU r100 must
    // never run on battery because the status was unknown. (Faces only run on Android.)
    private static bool deviceCharging()
    {
        import std.file : dirEntries, SpanMode, exists, readText;
        import std.string : strip, toLower;

        bool sawBattery = false;
        try
            foreach (e; dirEntries("/sys/class/power_supply", SpanMode.shallow))
            {
                immutable sp = buildPath(e.name, "status");
                if (!sp.exists)
                    continue;
                immutable st = readText(sp).strip.toLower;
                if (st.length == 0)
                    continue;
                sawBattery = true;
                if (st == "charging" || st == "full")
                    return true;
            }
        catch (Exception)
        {
        }
        cast(void) sawBattery;
        return false;
    }

    // The on-device face pass — the lowest priority. It never starts a photo while thumbnails
    // are still decoding, while a sync push is in flight (shouldYield), or on battery. The
    // thumbnail is decoded HERE, on the Qt thread (QImage off it loses the Adreno surface);
    // YuNet + r100 run on the face worker's own thread — r100's CPU fallback takes ~1 s per
    // face, which on the Qt thread froze input and rendering. One photo in flight at a time.
    private void stepFaces()
    {
        if (!facesReady)
            return;
        version (Android)
        {
            long rid;
            DetectedFace[] rfaces;
            bool rok, roverflow;
            if (faceWorker.take(rid, rfaces, rok, roverflow))
                applyFaces(rid, rfaces, rok, roverflow);
            if (faceWorker.initFailed)
            {
                facesReady = false;
                if (facesPump !is null)
                    facesPump.stop();
                plog("phone: on-device faces unavailable (model init failed) — computer detects on sync");
                return;
            }
            if (!faceWorker.idle)
                return;   // a photo is being detected
        }
        if (pump.isActive() || (shouldYield !is null && shouldYield()) || !deviceCharging())
            return;
        PhonePhoto* target;
        foreach (ref p; photos)
            if (!p.facesScanned && !p.isVideo && (p.kind is null || p.kind == "photo")
                && p.thumb !is null && p.thumb.exists)
            {
                target = &p;
                break;
            }
        if (target is null)
        {
            if (facesPump !is null)
                facesPump.stop();
            return;
        }
        version (Android)
        {
            if (!facesDecodeReady)
            {
                facesReader = make!QImageReader();
                facesImg = new QImage();
                facesDecodeReady = true;
            }
            facesReader.setFileName(target.thumb);
            facesReader.setAutoTransform(true);
            auto natural = QSize.__make(-1, -1);
            facesReader.setScaledSize(natural);
            int w, h;
            ubyte[] rgb;
            if (facesReader.read(cast(QImage*) facesImg.ptr()) && !facesImg.isNull())
                rgb = rgbOf(facesImg, w, h);
            if (rgb is null)
            {
                applyFaces(target.id, null, false, false);   // an unreadable thumbnail: a failed try
                return;
            }
            faceWorker.submit(target.id, rgb, w, h);
        }
    }

    enum maxFaceTries = 3;
    private int[long] faceTries;   // failed face passes per photo (this run)

    /// A face pass finished for photo `id` (on the Qt thread). A failure (model error, an
    /// unreadable thumbnail) is NOT a completed scan: the photo is retried, and only after
    /// maxFaceTries is it recorded as scanned (with no faces) so it cannot block the pass.
    private void applyFaces(long id, DetectedFace[] found, bool ok, bool overflow)
    {
        foreach (ref p; photos)
            if (p.id == id)
            {
                if (!ok)
                {
                    immutable n = overflow ? maxFaceTries : ++faceTries[id];
                    if (n < maxFaceTries)
                        return;
                    plog("phone: face pass ", overflow ? "found too many faces" : "failed", " on ",
                        p.path.baseName, " — leaving it to the computer");
                    // Done from our side, with nothing to hand over: no "faces" key goes with the
                    // upload (an empty array would tell the computer "nobody here"), so the
                    // computer runs its own detection on it.
                    p.faces = null;
                    p.facesScanned = true;
                    p.facesGaveUp = true;
                    p.facesSent = true;
                }
                else
                {
                    p.faces = found;
                    p.facesScanned = true;
                    p.facesGaveUp = false;
                    p.facesSent = false;
                    plog("phone: faces on ", p.path.baseName, ": ", found.length);
                }
                faceTries.remove(id);
                byPath[p.path] = p;
                dirty = true;
                save();
                if (ok && onFacesReady)
                    onFacesReady();   // the sync hands them over (with the photo, or on their own)
                return;
            }
    }

    /// The computer took this photo's faces (with the upload, or a library.faces update): drop
    /// the embeddings here — 512 floats a face would otherwise grow the index forever.
    void markFacesSent(long id)
    {
        foreach (ref p; photos)
            if (p.id == id && p.facesScanned)
            {
                p.facesSent = true;
                p.faces = null;
                byPath[p.path] = p;
            }
        dirty = true;
        save();
    }

    /// The computer will never take this photo's faces (it is not a photo there, or the batch
    /// was refused): stop offering them; the computer's own pass decides.
    void markFacesGaveUp(long id)
    {
        foreach (ref p; photos)
            if (p.id == id)
            {
                p.facesGaveUp = true;
                p.facesSent = true;
                p.faces = null;
                byPath[p.path] = p;
            }
        dirty = true;
        save();
    }

    /// Photos already on the computer whose faces the computer does not have yet (the face pass
    /// ran after the photo was sent): the sync sends those faces on their own.
    long[] facesUnsentIds() const
    {
        long[] out_;
        foreach (ref p; photos)
            if (p.sent && p.facesScanned && !p.facesGaveUp && !p.facesSent && p.hash.length)
                out_ ~= p.id;
        return out_;
    }

    // (Re)start the face pass if there is anything to do — after a decode batch and at startup.
    private void kickFaces()
    {
        if (facesReady && facesPump !is null && !facesPump.isActive())
            facesPump.start();
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
    private Candidate[] work;       // under lock: candidates still to decode (drained on the Qt thread)
    private uint generation;
    private bool walking;           // under lock: a walk thread is running
    private bool walkDone;          // under lock: `walked` is ready
    private Candidate[] walked;     // under lock
    private long lastProgress;
    private MonoTime started;
    private long queued, processed, added;
    private long lastSaved;
    private MonoTime lastChange;    // the last library.changed while decoding

    enum maxWorkers = 3;

    // Decoding runs on the Qt thread (see stepTimed): QImageReader/QImage on a worker thread
    // loses the GL surface on some GPUs (Adreno). One reader/image, reused across the run.
    private QImageReader decodeReader;
    private QImage decodeImg;
    private bool decodeReady;

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
            // Re-decode unless the thumb is present AND under the persistent thumbDir: an old
            // entry pointing at the evicted cache dir must be regenerated into files/thumbs,
            // or the grid shows dark tiles (the "black screen") for images Android deleted.
            if (known && known.size == c.size && known.mtimeMs == c.mtimeMs && known.thumb !is null
                && known.thumb.startsWith(thumbDir) && known.thumb.exists && known.kind.length)
                continue;
            // a video whose frame could not be taken shows the grey tile: done, not retried on
            // every start (the retriever may hang on it again)
            if (known && known.size == c.size && known.mtimeMs == c.mtimeMs && known.isVideo
                && known.thumb is null && known.kind.length)
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
        }
        queued = todo.length;
        processed = 0;
        added = 0;
        lastSaved = 0;
        lastProgress = 0;
        started = MonoTime.currTime;
        plog("phone: ", found.length, " files, ", queued, " to decode, ", removed, " gone");
        if (onProgress) onProgress(0, queued);
        // Decoding happens on the Qt thread in stepTimed (the pump is already running); no
        // worker threads — QImageReader/QImage off the Qt thread loses the surface on Adreno.
        if (!queued)
        {
            if (dirty) saveNow();
            if (removed && onChanged) onChanged();
            if (onDone) onDone(0, removed);
        }
        if (onScanned) onScanned(found.length);
    }

    /// Qt thread, every few ms: process a finished walk, then decode a time-bounded slice of
    /// thumbnails HERE (not on worker threads — QImageReader/QImage off the Qt thread loses the
    /// GL surface on Adreno: the app keeps running but the window goes black). One reader/image,
    /// reused. The slice yields to the event loop so the surface and input keep flowing.
    private void step() { timed("index.step", 30, { stepTimed(); }); }

    private void stepTimed()
    {
        Candidate[] found;
        bool haveWalk, stillWalking;
        synchronized (lock)
        {
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

        // Yield the whole decode slice while a sync push is running — the push and the UI
        // come first (see shouldYield). The pump keeps ticking, so decoding resumes as soon
        // as the push finishes.
        if (work.length && !(shouldYield !is null && shouldYield()))
        {
            if (!decodeReady)
            {
                decodeReader = make!QImageReader();
                decodeImg = new QImage();
                decodeReady = true;
            }
            uint gen;
            synchronized (lock)
                gen = generation;
            immutable sliceStart = MonoTime.currTime;
            bool did;
            while (true)
            {
                Candidate c;
                synchronized (lock)
                {
                    if (work.length == 0)
                        break;
                    c = work[0];
                    work = work[1 .. $];
                }
                Decoded d;
                d.c = c;
                d.gen = gen;
                try
                {
                    d.p = decode(c, thumbDir, decodeReader, decodeImg);
                    // eight 4 KiB reads: what merge() compares to keep a known file's digest
                    import photowagon.core.sync.digest : fingerprintOf;

                    d.p.fp = fingerprintOf(c.path);
                }
                catch (Exception e)
                    d.error = e.msg;
                processed++;
                did = true;
                if (d.error.length)
                    plog("phone: ", d.c.path, ": ", d.error);
                else if (d.gen == generation)
                    merge(d);
                if ((MonoTime.currTime - sliceStart).total!"msecs" >= 12)
                    break;   // yield: keep a frame budget so the surface and events keep flowing
            }
            if (did && onProgress)
                onProgress(processed, queued);
            if (processed - lastProgress >= 100 || processed >= queued)
            {
                lastProgress = processed;
                import core.memory : GC;
                auto gs = GC.profileStats();
                plog("phone: decoded ", processed, "/", queued, " in ", (MonoTime.currTime - started).total!"msecs" / 1000.0,
                    " s; gc ", gs.numCollections, " collections, paused ", gs.totalPauseTime.total!"msecs", " ms, max ",
                    gs.maxPauseTime.total!"msecs", " ms; heap ", GC.stats().usedSize / 1048576, " MB");
            }
        }

        if (work.length == 0 && processed >= queued)
        {
            if (stillWalking)
                return;
            pump.stop();
            sortPhotos();
            saveNow();
            if (onChanged) onChanged();
            if (onDone) onDone(added, 0);
            kickFaces();
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
        // A known file seen again with another size or mtime: same content if its fingerprint
        // (size + 8 sampled blocks) still matches — the stored sha256 and piece hashes stay,
        // and the full check happens when it is next shown or sent. Otherwise it is new
        // content: the digest goes (computed again before the next offer) and it is unsent.
        if (auto known = d.c.path in byPath)
            if (known.size != d.c.size || known.mtimeMs != d.c.mtimeMs)
            {
                immutable same = known.fp.length && d.p.fp.length && known.fp == d.p.fp && known.size == d.c.size;
                if (!same)
                {
                    p.hash = null;
                    p.pieces = null;
                    p.sent = false;
                    p.declined = false;
                    p.tries = 0;
                }
            }
        if (d.p.fp.length)
            p.fp = d.p.fp;
        p.size = d.c.size;
        p.mtimeMs = d.c.mtimeMs;
        p.takenTs = d.p.takenTs;
        p.orientation = d.p.orientation;
        p.width = d.p.width;
        p.height = d.p.height;
        p.thumb = d.p.thumb;
        p.isVideo = d.p.isVideo;
        p.durationMs = d.p.durationMs;
        // Without this the kind was never kept: afterWalk re-decodes every photo whose kind is
        // empty, so EVERY start decoded the whole library again.
        p.kind = d.p.kind;
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
        // a video: no ffmpeg on the phone, so the frame comes from the Android platform
        // (MediaMetadataRetriever via the JNI shim). On failure it falls back to the grey tile
        // + play glyph, and the computer still makes its own frame thumbnail on sync.
        if (c.isVideo)
        {
            import photowagon.core.metadata.datefromname : dateFromPath;

            immutable named = dateFromPath(c.path);
            p.takenTs = named ? named : c.mtimeMs / 1000;
            p.isVideo = true;

            // The frame comes from the Android platform (MediaMetadataRetriever via the JNI
            // shim). The desktop test build has no JNI, so it falls back to the grey tile +
            // play glyph — exactly what the phone does when the retriever fails.
            version (Android)
            {
                immutable vthumb = buildPath(thumbDir,
                    toHexString!(LetterCase.lower)(sha1Of(c.path ~ "@" ~ c.mtimeMs.to!string)).idup ~ ".jpg");
                long dur = -1;
                {
                    import photowagon.mobile.atomicfile : publishAtomic;

                    // On a thread of its own, bounded: Android's retriever can hang on a file,
                    // and here (the core's Qt thread) that blocked the UI's connection for good.
                    cast(void) publishAtomic(vthumb, (string tmp) {
                        dur = videoFrameBounded(c.path, tmp, 512);
                        return dur >= 0;
                    });
                }
                // not tried at all (frames off for this run): no kind, so the next start
                // decodes it again — only a real failure keeps the grey tile for good
                if (dur == -2)
                {
                    p.thumb = null;
                    p.kind = null;
                    return p;
                }
                if (dur >= 0 && vthumb.exists)
                {
                    p.thumb = vthumb;
                    p.durationMs = dur;
                }
                else
                    p.thumb = null;
            }
            else
                p.thumb = null;
            p.kind = "photo";   // a camera video is real content — sync it, show it
            return p;
        }
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
        ImageStats stats;
        makeThumb(reader, img, c.path, thumbPath, p.orientation, w, h, stats);
        p.width = w;
        p.height = h;
        p.thumb = thumbPath;
        // photo / screenshot / meme — so the grid can hide stickers & banners and the sync
        // sends only real photos. WhatsApp strips EXIF, so a received photo has no camera and
        // the pixel stats decide: a real photo stays 'photo', a banner/sticker becomes 'meme'.
        Signals sig = {
            path: c.path, width: w, height: h,
            hasCamera: exif.found && exif.dateTimeOriginal.length > 0,
            stats: stats
        };
        p.kind = stats.ok ? cast(string) classify(sig) : "photo";
        return p;
    }

    /// Decodes `src` scaled so its longest edge is `thumbEdge`, rotated by EXIF,
    /// and writes a JPEG at `dst`. Reports the rotated full-size dimensions.
    private static void makeThumb(QImageReader reader, QImage img, string src, string dst, int orientation, out int width, out int height, out ImageStats stats)
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
        {
            // already thumbnailed: feed the kind classifier from the small cached JPEG, not a
            // full re-decode of the (up to 100 MP) original. This keeps the one-time migration
            // — when kinds were added, every cached photo needs classifying — cheap: decoding a
            // 512 px thumb is fast, decoding every original is what stalled the index.
            reader.setFileName(dst);
            auto natural = QSize.__make(-1, -1);   // invalid = no scaling; ref const needs an lvalue
            reader.setScaledSize(natural);         // read the thumb at its own (already small) size
            if (reader.read(cast(QImage*) img.ptr()) && !img.isNull())
                stats = statsFromQImage(img);
            return;
        }
        // fit the longest edge (of the raw image; the transform only swaps axes)
        int tw = rw, th = rh;
        if (rw >= rh && rw > thumbEdge) { tw = thumbEdge; th = cast(int)(cast(long) rh * thumbEdge / rw); }
        else if (rh > rw && rh > thumbEdge) { th = thumbEdge; tw = cast(int)(cast(long) rw * thumbEdge / rh); }
        auto target = QSize.__make(tw < 1 ? 1 : tw, th < 1 ? 1 : th);
        reader.setScaledSize(target);
        // read() returning QImage by value is mis-bound (sret); the pointer overload is safe
        if (!reader.read(cast(QImage*) img.ptr()) || img.isNull())
            throw new Exception("decode failed");
        stats = statsFromQImage(img);
        {
            import photowagon.mobile.atomicfile : publishAtomic;

            // atomically: the grid may be loading this very file (a re-decode after a change)
            if (!publishAtomic(dst, (string tmp) => img.save(tmp, "JPEG".ptr, 84)))
                throw new Exception("cannot write thumbnail");
        }
    }

    /// The kind classifier's pixel statistics, from the decoded thumbnail. The colour
    /// order (BGRA vs RGBA) does not matter here — every statistic is order-agnostic.
    private static ImageStats statsFromQImage(QImage img)
    {
        ImageStats none;
        if (img.isNull())
            return none;
        immutable w = img.width(), h = img.height();
        if (w <= 0 || h <= 0)
            return none;
        immutable fmt = img.format();
        int bands;
        if (fmt == QImage.Format.Format_RGB888)
            bands = 3;
        else if (fmt == QImage.Format.Format_RGB32 || fmt == QImage.Format.Format_ARGB32
                || fmt == QImage.Format.Format_ARGB32_Premultiplied || fmt == QImage.Format.Format_RGBX8888
                || fmt == QImage.Format.Format_RGBA8888 || fmt == QImage.Format.Format_RGBA8888_Premultiplied)
            bands = 4;
        else
            return none;   // an unusual format: skip stats, the photo stays 'photo'
        immutable bpl = cast(size_t) img.bytesPerLine();
        immutable rowBytes = cast(size_t) w * bands;
        auto bits = img.constBits();
        if (bits is null || bpl < rowBytes)
            return none;
        auto packed = new ubyte[rowBytes * h];   // tighten the (possibly padded) rows for statsOf
        foreach (y; 0 .. h)
            packed[y * rowBytes .. (y + 1) * rowBytes] = bits[y * bpl .. y * bpl + rowBytes];
        return statsOf(packed, w, h, bands);
    }

    private void sortPhotos()
    {
        photos.sort!((a, b) => a.takenTs != b.takenTs ? a.takenTs > b.takenTs : a.id > b.id);
    }

    // ---- queries -----------------------------------------------------------------

    // Sent to the computer only if it is a real photo (or a video). Memes, stickers and
    // screenshots stay on the phone. Not-yet-classified ("") counts as a photo so the first
    // sync is not stalled; the next scan reclassifies and then blocks the junk.
    private static bool syncable(ref const PhonePhoto p)
    {
        return p.kind.length == 0 || p.kind == "photo";
    }

    private bool matches(ref const PhonePhoto p, PhoneFilter f) const
    {
        // the grid hides stickers & banners (classified 'meme'); photos and screenshots stay
        if (p.kind == "meme")
            return false;
        if (f.hideSent && p.sent)
            return false;
        if (f.kind == "video" && !p.isVideo)
            return false;
        if (f.kind == "screenshot" && p.kind != "screenshot")
            return false;
        if (f.kind == "photo" && (p.isVideo || p.kind == "screenshot"))
            return false;
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
    /// The photos the computer has (delivered, by content hash): what "Free up space" may
    /// delete from the phone. Every kind, whatever the grid shows.
    const(PhonePhoto)[] onComputer() const
    {
        const(PhonePhoto)[] out_;
        foreach (ref p; photos)
            if (p.sent && p.hash.length)
                out_ ~= p;
        return out_;
    }

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
            if (p.kind == "meme")
                continue;   // the grid hides these (matches()): the date tree must agree
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
            if (!p.sent && !p.declined && p.tries < maxTries && syncable(p))
                out_ ~= p.id;
        return out_;
    }

    long unsentCount() const
    {
        long n;
        foreach (ref p; photos)
            if (!p.sent && !p.declined && p.tries < maxTries && syncable(p))
                n++;
        return n;
    }

    /// Photos that are not on the computer after at least one failed try (retrying or given
    /// up) — distinct photos, not attempts.
    long failedPhotoCount() const
    {
        long n;
        foreach (ref p; photos)
            if (!p.sent && !p.declined && p.tries > 0 && syncable(p))
                n++;
        return n;
    }

    /// Photos that failed maxTries times: no longer offered on their own, waiting for the
    /// user's "Send all now" (resetTries) — they must stay visible as failures until then.
    long gaveUpCount() const
    {
        long n;
        foreach (ref p; photos)
            if (!p.sent && !p.declined && p.tries >= maxTries && syncable(p))
                n++;
        return n;
    }

    /// The computer turned this hash away (the user deleted it there): stop offering it.
    void markDeclined(long id)
    {
        foreach (ref p; photos)
            if (p.id == id)
            {
                p.declined = true;
                byPath[p.path] = p;
            }
        dirty = true;
        save();
    }

    /// Record a hash computed off-thread, so the next sync negotiation can offer it
    /// without reading the file again.
    void setHash(long id, string hash)
    {
        if (!hash.length)
            return;
        foreach (ref p; photos)
            if (p.id == id)
            {
                if (p.hash != hash)
                {
                    // other content: the kept manifest and fingerprint described the old one,
                    // and whatever was sent or refused was the old one too
                    p.pieces = null;
                    p.fp = null;
                    p.digestSize = 0;
                    if (p.hash.length)
                    {
                        p.sent = false;
                        p.declined = false;
                        p.tries = 0;
                    }
                }
                p.hash = hash;
                byPath[p.path] = p;
            }
        dirty = true;
    }

    /// The file's content digest, computed once (core/sync/digest.d) and kept.
    void setDigest(long id, string sha, string pieces, string fp, long size)
    {
        if (!sha.length)
            return;
        foreach (ref p; photos)
            if (p.id == id)
            {
                if (p.hash.length && p.hash != sha)
                {
                    // the content changed under a digest we held: new photo, as far as the
                    // computer is concerned
                    p.sent = false;
                    p.declined = false;
                    p.tries = 0;
                }
                p.hash = sha;
                p.pieces = pieces;
                p.digestSize = size;
                if (fp.length)
                    p.fp = fp;
                byPath[p.path] = p;
            }
        dirty = true;
    }

    /// Forget a digest that turned out stale (a piece did not match while sending): it is
    /// computed again before the photo is offered next.
    void clearDigest(long id, string expected = null)
    {
        foreach (ref p; photos)
            if (p.id == id)
            {
                if (expected.length && p.hash != expected)
                    continue;   // a late report about content this photo no longer has
                p.hash = null;
                p.pieces = null;
                p.fp = null;
                p.digestSize = 0;
                // new content as far as the computer knows: offered again from scratch
                p.sent = false;
                p.declined = false;
                p.tries = 0;
                byPath[p.path] = p;
            }
        dirty = true;
    }

    void markSent(long id, string hash = null)
    {
        foreach (ref p; photos)
            if (p.id == id)
            {
                // the content that went must still be this photo's: a recheck or a rescan may
                // have replaced or dropped its digest while it was being sent — then it is not
                if (p.hash != hash)
                    continue;
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
                // a failure of OTHER content (a recheck replaced the digest meanwhile) is not
                // this photo's: neither a try nor its hash
                if (p.hash != hash)
                    continue;
                p.tries++;
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
                p.declined = "declined" in e ? e["declined"].boolean : false;
                p.hash = "hash" in e && e["hash"].type == JSONType.string ? e["hash"].str : null;
                p.pieces = "pieces" in e && e["pieces"].type == JSONType.string ? e["pieces"].str : null;
                p.fp = "fp" in e && e["fp"].type == JSONType.string ? e["fp"].str : null;
                p.digestSize = "dsize" in e && e["dsize"].type == JSONType.integer ? e["dsize"].integer : 0;
                p.tries = "tries" in e ? cast(int) e["tries"].integer : 0;
                p.isVideo = "video" in e ? e["video"].boolean : false;
                p.durationMs = "duration" in e ? e["duration"].integer : 0;
                p.kind = "kind" in e && e["kind"].type == JSONType.string ? e["kind"].str : null;
                if ("faces" in e && e["faces"].type == JSONType.array)
                    p.faces = facesFromJson(e["faces"]);
                p.facesScanned = "facesScanned" in e ? e["facesScanned"].boolean : false;
                p.facesSent = "facesSent" in e ? e["facesSent"].boolean : false;
                p.facesGaveUp = "facesGaveUp" in e ? e["facesGaveUp"].boolean : false;
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

    /// Writes the index right away (the end of a scan; a sync mark Android must not lose).
    /// Hands a snapshot to the save worker and returns: every change made before this call
    /// is on disk once the worker is done — see flush().
    void saveNow()
    {
        if (saveTimer !is null)
            saveTimer.stop();
        timed("index.save", 30, { saveTimed(); });
    }

    private IndexSaver saver;

    private void saveTimed()
    {
        if (!dirty)
            return;
        // Serialising 3,000+ photos to a 1.3 MB JSON string on the Qt thread blocked it for
        // 70–200 ms per save. On this device that stall during startup made Android release the
        // window surface — the app went black while still alive. Snapshot the photos here (cheap:
        // value types with immutable strings) and serialise + write on the save worker, so the
        // Qt thread stays responsive and the surface survives. A save already running does not
        // skip this one (it used to, and a change made during a save then waited for the next
        // change): the worker writes the latest snapshot after it.
        dirty = false;
        saver.submit(IndexSnapshot(photos.dup, nextId, indexFile));
    }

    /// Stop producing changes: the decode pump, the face pump and pending timed saves (the
    /// face worker finishes or drops the one photo it holds). Part of the core's shutdown.
    void stopProducers()
    {
        if (pump !is null)
            pump.stop();
        if (facesPump !is null)
            facesPump.stop();
        if (saveTimer !is null)
            saveTimer.stop();
    }

    /// Put the latest state on disk: write what is dirty and wait for the save worker, until
    /// `deadline`. True when everything changed so far is written.
    bool flush(MonoTime deadline)
    {
        if (dirty)
            saveTimed();
        return saver.flush(deadline);
    }
}

private struct IndexSnapshot
{
    PhonePhoto[] photos;
    long nextId;
    string file;
}

/// The index's one writer: a thread of its own that writes the LATEST snapshot handed to it
/// (older pending ones are superseded, never written), atomically. flush() waits for what
/// was submitted so far, with a deadline.
private final class IndexSaver
{
    import core.sync.condition : Condition;
    import core.sync.mutex : Mutex;
    import core.thread : Thread;

    private Mutex m;
    private Condition cv;
    private IndexSnapshot pending;
    private bool hasPending;
    private ulong submitted, written;   // under m: submission counter, the last one on disk
    private Thread thread;

    this()
    {
        m = new Mutex;
        cv = new Condition(m);
        thread = new Thread(&run);
        thread.name = "index-save";
        thread.isDaemon = true;   // a hard exit need not wait for it; shutdown() flushes first
        thread.start();
    }

    void submit(IndexSnapshot s)
    {
        synchronized (m)
        {
            pending = s;
            hasPending = true;
            ++submitted;
            cv.notifyAll();
        }
    }

    bool flush(MonoTime deadline)
    {
        synchronized (m)
        {
            immutable target = submitted;
            while (written < target)
            {
                immutable left = deadline - MonoTime.currTime;
                if (left <= Duration.zero)
                    return false;
                cv.wait(left);
            }
            return true;
        }
    }

    private void run()
    {
        useCrashStack();
        for (;;)
        {
            IndexSnapshot s;
            ulong seq;
            synchronized (m)
            {
                while (!hasPending)
                    cv.wait();
                s = pending;
                pending = IndexSnapshot.init;
                hasPending = false;
                seq = submitted;
            }
            immutable ok = writeSnapshot(s);
            synchronized (m)
            {
                if (ok)
                    written = seq;
                else if (!hasPending)
                {
                    // not on disk (full, I/O error): keep it and try again shortly, unless a
                    // newer snapshot arrived meanwhile; flush() keeps reporting false until then
                    pending = s;
                    hasPending = true;
                    cv.wait(2.seconds);
                }
                cv.notifyAll();
            }
        }
    }

    private static bool writeSnapshot(ref IndexSnapshot s)
    {
        import photowagon.mobile.atomicfile : writeAtomic;

        JSONValue[] arr;
        arr.reserve(s.photos.length);
        foreach (ref p; s.photos)
            arr ~= JSONValue([
                "id": JSONValue(p.id), "path": JSONValue(p.path), "size": JSONValue(p.size),
                "mtime": JSONValue(p.mtimeMs), "takenTs": JSONValue(p.takenTs), "w": JSONValue(p.width),
                "h": JSONValue(p.height), "o": JSONValue(p.orientation),
                "thumb": p.thumb is null ? JSONValue(null) : JSONValue(p.thumb), "sent": JSONValue(p.sent),
                "declined": JSONValue(p.declined), "hash": p.hash.length ? JSONValue(p.hash) : JSONValue(null),
                "pieces": p.pieces.length ? JSONValue(p.pieces) : JSONValue(null),
                "fp": p.fp.length ? JSONValue(p.fp) : JSONValue(null),
                "dsize": JSONValue(p.digestSize),
                "tries": JSONValue(p.tries), "video": JSONValue(p.isVideo), "duration": JSONValue(p.durationMs),
                "kind": p.kind.length ? JSONValue(p.kind) : JSONValue(null),
                "faces": facesToJson(p.faces), "facesScanned": JSONValue(p.facesScanned),
                "facesSent": JSONValue(p.facesSent), "facesGaveUp": JSONValue(p.facesGaveUp),
            ]);
        JSONValue j = ["nextId": JSONValue(s.nextId), "photos": JSONValue(arr)];
        try
        {
            writeAtomic(s.file, j.toString());
            return true;
        }
        catch (Exception e)
        {
            plog("phone: cannot save index: ", e.msg);
            return false;
        }
    }
}

// ---- video frames, off the calling thread and bounded ----------------------------------------
//
// pw_video_thumb (MediaMetadataRetriever through the JNI shim) can block indefinitely on some
// files. It runs on a thread of its own; the caller waits at most videoFrameLimit. A worker
// that did not come back is abandoned (it may be stuck in the platform for good) and the next
// frame gets a new one; after a few abandoned workers, video frames are off for this process.
version (Android)
{
    import core.sync.condition : Condition;
    import core.sync.mutex : Mutex;
    import core.thread : Thread;
    import core.time : Duration;

    private enum Duration videoFrameLimit = 6.seconds;
    private enum maxStuckGrabbers = 3;

    private final class FrameGrabber
    {
        Mutex m;
        Condition cv;
        string path, dest;
        int maxSize;
        bool hasJob, done;
        long result;
        Thread thread;

        this()
        {
            m = new Mutex;
            cv = new Condition(m);
            thread = new Thread(&run);
            thread.name = "video-frames";
            thread.isDaemon = true;
            thread.start();
        }

        private void run()
        {
            import std.string : toStringz;
            import qt.quick.qjnienvironment : QJniEnvironment;

            useCrashStack();
            for (;;)
            {
                string p, d;
                int ms;
                synchronized (m)
                {
                    while (!hasJob)
                        cv.wait();
                    p = path; d = dest; ms = maxSize;
                    hasJob = false;
                }
                long r = -1;
                try
                {
                    auto env = QJniEnvironment.getJniEnv();   // attaches this thread to the VM
                    r = pw_video_thumb(cast(void*) env, p.toStringz, d.toStringz, ms);
                }
                catch (Throwable)
                {
                }
                synchronized (m)
                {
                    result = r;
                    done = true;
                    cv.notifyAll();
                }
            }
        }
    }

    private __gshared FrameGrabber grabber;
    private __gshared int stuckGrabbers;

    /// The duration of the video (ms) with its frame written to `dest`, or -1 — within
    /// videoFrameLimit whatever the platform does.
    private long videoFrameBounded(string path, string dest, int maxSize)
    {
        if (stuckGrabbers >= maxStuckGrabbers)
            return -2;   // not tried (frames are off for this run): the caller retries next start
        if (grabber is null)
            grabber = new FrameGrabber;
        auto g = grabber;
        synchronized (g.m)
        {
            g.path = path; g.dest = dest; g.maxSize = maxSize;
            g.done = false;
            g.hasJob = true;
            g.cv.notifyAll();
            immutable deadline = MonoTime.currTime + videoFrameLimit;
            while (!g.done)
            {
                immutable left = deadline - MonoTime.currTime;
                if (left <= Duration.zero)
                    break;
                g.cv.wait(left);
            }
            if (g.done)
                return g.result;
        }
        // stuck in the platform: leave it there, the next video gets a fresh worker
        grabber = null;
        stuckGrabbers++;
        plog("phone: no frame from ", path, " within ", videoFrameLimit.total!"seconds", " s — grey tile",
            stuckGrabbers >= maxStuckGrabbers ? " (video frames off for this run)" : "");
        return -1;
    }
}
