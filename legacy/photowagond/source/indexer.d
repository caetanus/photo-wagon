module indexer;

import core.sys.posix.sys.stat : stat, stat_t;
import etc.c.sqlite3;

import std.algorithm : canFind, sort;
import std.array : appender;
import std.conv : to;
import std.datetime : DateTime;
import std.datetime.systime : Clock, SysTime;
import std.digest : toHexString;
import std.digest.sha : sha1Of;
import std.file : SpanMode, dirEntries, exists, isDir, mkdirRecurse;
import std.format : format;
import std.path : buildPath, extension;
import std.process : environment;
import std.string : fromStringz, indexOf, replace, split, splitLines, strip, toLower, toStringz;
import std.typecons : Nullable;

import log;

// ---------------------------------------------------------------------------
// C library bindings (gexiv2, libvips, glib)
// ---------------------------------------------------------------------------
extern (C)
{
    void g_object_unref(void* object);
    void g_free(void* mem);
    void g_error_free(void* error);

    // GLib log handler — used to suppress VIPS module-load warnings
    alias GLogFunc = void function(const char*, int, const char*, void*);
    uint g_log_set_handler(const char* log_domain, int log_levels, GLogFunc log_func, void* user_data);

    void* gexiv2_metadata_new();
    void gexiv2_metadata_free(void* self);
    int gexiv2_metadata_open_path(void* self, const char* path, void** error);
    char* gexiv2_metadata_try_get_tag_string(void* self, const char* tag, void** error);

    int vips_init(const char* argv0);
    void* vips_image_new_from_file(const char* name, ...);
    int vips_image_get_width(void* image);
    int vips_image_get_height(void* image);
    int vips_thumbnail(const char* filename, void** out_, int width, ...);
    int vips_jpegsave(void* in_, const char* filename, ...);
}

// ---------------------------------------------------------------------------
// C library bindings (OpenCV face_opencv shim)
// ---------------------------------------------------------------------------
extern (C)
{
    struct CFaceResult
    {
        int x, y, w, h;
        int image_width, image_height;
        float score;
        float[128] embedding;
    }

    int face_init(const char* yunet_path, const char* sface_path);
    int face_detect(const char* image_path, CFaceResult* out_faces, int max_faces);
    float face_cosine_similarity(const float* a, const float* b);
}

// ---------------------------------------------------------------------------
// Structs
// ---------------------------------------------------------------------------

struct PhotoMetadata
{
    string city;
    SysTime dateTime;
    bool usedFallback;
}

struct PhotoItem
{
    string sourcePath;
    string thumbPath;
    string screenPath;
    string subtitle;
    int sourceWidth;
    int sourceHeight;
    SysTime dateTime;
    string monthTitle;
}

struct FaceDetection
{
    int x, y, w, h;
    int imageWidth, imageHeight;
    float score;
    float[128] embedding;
    string fingerprintHex;
}

struct FaceRecord
{
    long id;
    string sourcePath, thumbPath;
    int x, y, w, h;
    int imageWidth, imageHeight;
    string personName, fingerprintHex;
}

struct FingerprintRecord
{
    long fingerprintId;
    string fingerprintHex, personName;
    string sourcePath, thumbPath;
    int x, y, w, h;
    int imageWidth, imageHeight;
    int faceCount;
}

struct ImageDimensions
{
    int width = 1;
    int height = 1;
}

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

private immutable string[] IMAGE_EXTENSIONS = [
    ".jpg", ".jpeg", ".png", ".heic", ".heif", ".webp", ".bmp", ".tif", ".tiff"
];

private immutable string[] DATE_KEYS = [
    "Exif.Photo.DateTimeOriginal",
    "Exif.Photo.DateTimeDigitized",
    "Exif.Image.DateTime",
    "Xmp.exif.DateTimeOriginal",
    "Xmp.xmp.CreateDate",
    "Xmp.photoshop.DateCreated"
];

private immutable string[] CITY_KEYS = [
    "Xmp.photoshop.City",
    "Iptc.Application2.City",
    "Xmp.iptc.Location"
];

private enum size_t MAX_SCANNED_ENTRIES = 250_000;
private enum size_t MAX_INDEXED_IMAGES = 50_000;
private enum size_t MAX_FACE_SCAN_IMAGES = 25_000;
private enum size_t MAX_FACE_MATCHES = 1_000;
private immutable string FACE_DB_NAME = "faces.sqlite";

// ---------------------------------------------------------------------------
// Init
// ---------------------------------------------------------------------------

private __gshared bool gVipsInitDone = false;

// GLib log levels
private enum int G_LOG_LEVEL_WARNING = 1 << 4;
private enum int G_LOG_LEVEL_CRITICAL = 1 << 3;
private enum int G_LOG_FLAG_RECURSION = 1 << 0;
private enum int G_LOG_FLAG_FATAL = 1 << 1;

private extern (C) void silentLogHandler(const char*, int, const char*, void*) nothrow
{
    // Intentionally empty — suppress VIPS module-load warnings.
}

void ensureVipsInit()
{
    if (!gVipsInitDone)
    {
        // Suppress "unable to load vips-openslide.so" GLib warning.
        g_log_set_handler("VIPS".ptr, G_LOG_LEVEL_WARNING | G_LOG_FLAG_RECURSION | G_LOG_FLAG_FATAL,
            &silentLogHandler, null);
        vips_init("photowagond".ptr);
        gVipsInitDone = true;
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

string defaultCacheRoot()
{
    auto home = environment.get("HOME", ".");
    auto cacheRoot = buildPath(home, ".cache", "photo-wagon");
    if (!exists(cacheRoot))
        mkdirRecurse(cacheRoot);
    return cacheRoot;
}

bool isImageFile(const string filePath)
{
    return IMAGE_EXTENSIONS.canFind(extension(filePath).toLower());
}

private string thumbnailKey(const string path, const long size, const long mtimeMs)
{
    return toHexString(sha1Of(path ~ "|" ~ to!string(size) ~ "|" ~ to!string(mtimeMs))).idup;
}

long fileModifiedMs(const string filePath)
{
    stat_t st = void;
    if (stat(toStringz(filePath), &st) != 0)
        return cast(long) Clock.currTime().toUnixTime() * 1_000;
    return cast(long) st.st_mtime * 1_000;
}

// ---------------------------------------------------------------------------
// Thumbnails (libvips C API)
// ---------------------------------------------------------------------------

private string ensureDerivedImage(
    const string sourcePath, const string cacheRoot,
    const string key, const string variant,
    const int maxEdge, const int quality)
{
    const shard = key[0 .. 2];
    const shardDir = buildPath(cacheRoot, shard);
    if (!exists(shardDir))
        mkdirRecurse(shardDir);

    const outName = key[0 .. 8] ~ "-" ~ variant ~ ".jpg";
    const outPath = buildPath(shardDir, outName);
    if (exists(outPath))
        return outPath;

    ensureVipsInit();

    void* thumb = null;
    if (vips_thumbnail(toStringz(sourcePath), &thumb, maxEdge, cast(void*) null) != 0)
        return "";
    if (thumb is null)
        return "";
    scope (exit)
        g_object_unref(thumb);

    if (vips_jpegsave(thumb, toStringz(outPath), "Q".ptr, quality, cast(void*) null) != 0)
        return "";
    return outPath;
}

ImageDimensions dimensionsFromVips(const string sourcePath)
{
    ImageDimensions dim;
    ensureVipsInit();
    auto img = vips_image_new_from_file(toStringz(sourcePath), cast(void*) null);
    if (img is null)
        return dim;
    scope (exit)
        g_object_unref(img);
    const w = vips_image_get_width(img);
    const h = vips_image_get_height(img);
    if (w > 0)
        dim.width = w;
    if (h > 0)
        dim.height = h;
    return dim;
}

// ---------------------------------------------------------------------------
// EXIF metadata (gexiv2 C API)
// ---------------------------------------------------------------------------

private Nullable!SysTime parseExifDateTime(const string value)
{
    auto text = value.strip();
    if (text.length < 10)
        return Nullable!SysTime();

    auto sanitized = text.dup;
    if (sanitized.length >= 10)
    {
        sanitized[4] = '-';
        sanitized[7] = '-';
    }
    if (sanitized.length == 10)
        sanitized ~= " 00:00:00";

    if (sanitized.length >= 19)
    {
        try
        {
            return Nullable!SysTime(SysTime(DateTime(
                    sanitized[0 .. 4].to!int, sanitized[5 .. 7].to!int, sanitized[8 .. 10].to!int,
                    sanitized[11 .. 13].to!int, sanitized[14 .. 16].to!int, sanitized[17 .. 19]
                    .to!int)));
        }
        catch (Exception)
        {
        }
    }
    return Nullable!SysTime();
}

PhotoMetadata readPhotoMetadata(const string filePath, const long fallbackMtimeMs)
{
    PhotoMetadata metadata;

    auto exivMeta = gexiv2_metadata_new();
    if (exivMeta !is null)
    {
        scope (exit)
            gexiv2_metadata_free(exivMeta);
        void* openError = null;
        if (gexiv2_metadata_open_path(exivMeta, toStringz(filePath), &openError) != 0)
        {
            foreach (key; DATE_KEYS)
            {
                if (metadata.dateTime != SysTime.init)
                    break;
                void* tagError = null;
                auto val = gexiv2_metadata_try_get_tag_string(exivMeta, toStringz(key), &tagError);
                if (val !is null)
                {
                    const parsed = parseExifDateTime(fromStringz(val).idup);
                    g_free(val);
                    if (!parsed.isNull)
                        metadata.dateTime = parsed.get;
                }
                if (tagError !is null)
                    g_error_free(tagError);
            }
            foreach (key; CITY_KEYS)
            {
                if (metadata.city.length > 0)
                    break;
                void* tagError = null;
                auto val = gexiv2_metadata_try_get_tag_string(exivMeta, toStringz(key), &tagError);
                if (val !is null)
                {
                    auto city = fromStringz(val).idup.strip();
                    g_free(val);
                    if (city.length > 0)
                        metadata.city = city;
                }
                if (tagError !is null)
                    g_error_free(tagError);
            }
        }
        if (openError !is null)
            g_error_free(openError);
    }

    if (metadata.dateTime == SysTime.init)
    {
        metadata.dateTime = SysTime.fromUnixTime(fallbackMtimeMs / 1_000);
        metadata.usedFallback = true;
    }
    return metadata;
}

// ---------------------------------------------------------------------------
// JSON helpers
// ---------------------------------------------------------------------------

string jsonEscape(const string value)
{
    auto b = appender!string();
    foreach (ch; value)
    {
        switch (ch)
        {
        case '"':
            b.put("\\\"");
            break;
        case '\\':
            b.put("\\\\");
            break;
        case '\n':
            b.put("\\n");
            break;
        case '\r':
            b.put("\\r");
            break;
        case '\t':
            b.put("\\t");
            break;
        default:
            if (ch < 0x20)
                b.put(format("\\u%04x", cast(int) ch));
            else
                b.put(ch);
        }
    }
    return b.data;
}

string toFileUrl(string path)
{
    path = path.replace("%", "%25").replace("#", "%23").replace("?", "%3F").replace(" ", "%20");
    return "file://" ~ path;
}

// ---------------------------------------------------------------------------
// SQLite helpers
// ---------------------------------------------------------------------------

private string sqlEscape(string value)
{
    return value.replace("'", "''");
}

private extern (C) int sqliteCollectRowsCallback(void* ud, int cols, char** vals, char**)
{
    auto output = cast(string*) ud;
    if (output is null)
        return 0;
    foreach (i; 0 .. cols)
    {
        if (i > 0)
            *output ~= "\t";
        if (vals[i]!is null)
            *output ~= fromStringz(vals[i]);
    }
    *output ~= "\n";
    return 0;
}

sqlite3* openSqliteDb(const string dbPath)
{
    sqlite3* db = null;
    auto rc = sqlite3_open_v2(toStringz(dbPath), &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null);
    if (rc != SQLITE_OK || db is null)
    {
        if (db !is null)
            sqlite3_close(db);
        return null;
    }
    return db;
}

bool runSqlCommandDb(sqlite3* db, const string sql)
{
    char* err = null;
    auto rc = sqlite3_exec(db, toStringz(sql), null, null, &err);
    if (err !is null)
        sqlite3_free(err);
    return rc == SQLITE_OK;
}

string querySqlOutputDb(sqlite3* db, const string sql)
{
    string output;
    char* err = null;
    auto rc = sqlite3_exec(db, toStringz(sql), &sqliteCollectRowsCallback, &output, &err);
    if (err !is null)
        sqlite3_free(err);
    return rc == SQLITE_OK ? output : "";
}

long sqlCountOrZeroDb(sqlite3* db, const string sql)
{
    auto output = querySqlOutputDb(db, sql).strip();
    if (output.length == 0)
        return 0;
    try
    {
        return output.to!long;
    }
    catch (Exception)
    {
        return 0;
    }
}

bool ensureFaceSchemaDb(sqlite3* db)
{
    return runSqlCommandDb(db,
        "CREATE TABLE IF NOT EXISTS face_photos (id INTEGER PRIMARY KEY AUTOINCREMENT,"
            ~ "source_path TEXT NOT NULL UNIQUE, source_mtime_ms INTEGER NOT NULL, analyzed_at_ms INTEGER NOT NULL);"
            ~ "CREATE TABLE IF NOT EXISTS face_fingerprints (id INTEGER PRIMARY KEY AUTOINCREMENT,"
            ~ "fingerprint_hex TEXT NOT NULL UNIQUE, person_name TEXT, embedding TEXT);"
            ~ "CREATE TABLE IF NOT EXISTS faces (id INTEGER PRIMARY KEY AUTOINCREMENT,"
            ~ "photo_id INTEGER NOT NULL, source_path TEXT NOT NULL, thumb_path TEXT NOT NULL,"
            ~ "x INTEGER NOT NULL, y INTEGER NOT NULL, w INTEGER NOT NULL, h INTEGER NOT NULL,"
            ~ "image_width INTEGER NOT NULL, image_height INTEGER NOT NULL,"
            ~ "fingerprint_hex TEXT NOT NULL, person_name TEXT, embedding TEXT,"
            ~ "FOREIGN KEY(photo_id) REFERENCES face_photos(id) ON DELETE CASCADE);"
            ~ "CREATE INDEX IF NOT EXISTS idx_face_fingerprints_hex ON face_fingerprints(fingerprint_hex);"
            ~ "CREATE INDEX IF NOT EXISTS idx_faces_person_name ON faces(person_name);"
            ~ "CREATE INDEX IF NOT EXISTS idx_faces_fingerprint_hex ON faces(fingerprint_hex);"
            ~ "CREATE INDEX IF NOT EXISTS idx_faces_source_path ON faces(source_path);"
            ~ "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;");
}

string faceDbPath()
{
    return buildPath(defaultCacheRoot(), FACE_DB_NAME);
}

// ---------------------------------------------------------------------------
// Comparator
// ---------------------------------------------------------------------------

private bool compareItems(ref const PhotoItem a, ref const PhotoItem b)
{
    if (a.dateTime.stdTime != b.dateTime.stdTime)
        return a.dateTime.stdTime > b.dateTime.stdTime;
    return a.sourcePath < b.sourcePath;
}

private string monthName(int m)
{
    static immutable n = [
        "", "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ];
    return (m >= 1 && m <= 12) ? n[m] : "Unknown";
}

private string humanizedMonthFrom(SysTime dt)
{
    auto local = dt.toLocalTime();
    return monthName(local.month) ~ " " ~ to!string(local.year);
}

// ---------------------------------------------------------------------------
// Face model init
// ---------------------------------------------------------------------------

private __gshared bool gFaceModelsLoaded = false;

void initFaceModels()
{
    if (gFaceModelsLoaded)
        return;

    // Try to find models relative to the binary, then in well-known paths.
    auto home = environment.get("HOME", ".");
    immutable string[] searchDirs = [
        buildPath(home, "lab/photo-wagon/models"),
        buildPath(home, ".local/share/photo-wagon/models"),
        "/usr/share/photo-wagon/models",
    ];

    string yunetPath, sfacePath;
    foreach (dir; searchDirs)
    {
        auto y = buildPath(dir, "face_detection_yunet_2023mar.onnx");
        auto s = buildPath(dir, "face_recognition_sface_2021dec.onnx");
        if (exists(y) && exists(s))
        {
            yunetPath = y;
            sfacePath = s;
            break;
        }
    }

    if (yunetPath.length == 0)
    {
        log.warn("face models not found — face detection disabled");
        return;
    }

    if (face_init(toStringz(yunetPath), toStringz(sfacePath)) == 0)
    {
        gFaceModelsLoaded = true;
        log.info("face models loaded (YuNet + SFace)");
    }
    else
    {
        log.err("failed to initialize face models");
    }
}

// ---------------------------------------------------------------------------
// Face detection (YuNet DNN + SFace 128-d embedding)
// ---------------------------------------------------------------------------

FaceDetection[] detectFacesForImage(const string sourcePath, const long mtimeMs)
{
    if (!gFaceModelsLoaded)
        return [];

    enum MAX_FACES_PER_IMAGE = 32;
    CFaceResult[MAX_FACES_PER_IMAGE] buf;
    auto n = face_detect(toStringz(sourcePath), buf.ptr, MAX_FACES_PER_IMAGE);
    if (n <= 0)
        return [];

    FaceDetection[] results;
    foreach (i; 0 .. n)
    {
        FaceDetection d;
        d.x = buf[i].x;
        d.y = buf[i].y;
        d.w = buf[i].w;
        d.h = buf[i].h;
        d.imageWidth = buf[i].image_width;
        d.imageHeight = buf[i].image_height;
        d.score = buf[i].score;
        d.embedding = buf[i].embedding;
        // fingerprintHex is assigned later during clustering
        results ~= d;
    }
    return results;
}

// ---------------------------------------------------------------------------
// Face fingerprint clustering (cosine similarity on 128-d embeddings)
// ---------------------------------------------------------------------------

private enum float COSINE_SAME_PERSON_THRESHOLD = 0.363f;

/**
 * Find the best-matching fingerprint in the DB for the given embedding.
 * Returns the fingerprint_hex if similarity >= threshold, or "" if no match.
 */
private string findMatchingFingerprint(sqlite3* db, ref const float[128] embedding)
{
    // Load all existing fingerprint embeddings from the DB.
    string bestHex;
    float bestSim = COSINE_SAME_PERSON_THRESHOLD;

    // Use a callback to iterate fingerprints.
    auto output = querySqlOutputDb(db,
        "SELECT fingerprint_hex, embedding FROM face_fingerprints WHERE embedding IS NOT NULL;");

    foreach (line; output.splitLines())
    {
        auto t = line.strip();
        if (t.length == 0)
            continue;
        // Columns: fingerprint_hex \t hex-encoded-embedding
        auto tabPos = t.indexOf('\t');
        if (tabPos < 0)
            continue;
        auto hex = t[0 .. tabPos];
        auto blobHex = t[tabPos + 1 .. $];
        if (blobHex.length < 128 * 8) // 128 floats * 8 hex chars each
            continue;

        // Decode the blob hex back to float[128]
        float[128] stored;
        if (!decodeEmbeddingHex(blobHex, stored))
            continue;

        auto sim = face_cosine_similarity(embedding.ptr, stored.ptr);
        if (sim > bestSim)
        {
            bestSim = sim;
            bestHex = hex.idup;
        }
    }
    return bestHex;
}

private string encodeEmbeddingHex(ref const float[128] emb)
{
    // Encode 128 floats (512 bytes) as hex string
    auto b = appender!string();
    const ubyte* raw = cast(const ubyte*) emb.ptr;
    foreach (i; 0 .. 512)
        b.put(format("%02x", raw[i]));
    return b.data;
}

private bool decodeEmbeddingHex(const string hex, ref float[128] emb)
{
    if (hex.length < 1024) // 512 bytes * 2 hex chars
        return false;
    ubyte* raw = cast(ubyte*) emb.ptr;
    foreach (i; 0 .. 512)
    {
        try
        {
            raw[i] = hex[i * 2 .. i * 2 + 2].to!ubyte(16);
        }
        catch (Exception)
        {
            return false;
        }
    }
    return true;
}

// ---------------------------------------------------------------------------
// Face DB operations
// ---------------------------------------------------------------------------

bool syncFacesForImage(sqlite3* db, const string sourcePath, const string thumbPath, const long mtimeMs)
{
    auto esc = sqlEscape(sourcePath);
    auto existing = querySqlOutputDb(db,
        "SELECT source_mtime_ms FROM face_photos WHERE source_path='" ~ esc ~ "' LIMIT 1;").strip();
    if (existing.length > 0 && existing == to!string(mtimeMs))
        return true;

    auto detections = detectFacesForImage(sourcePath, mtimeMs);
    auto now = to!string(cast(long) Clock.currTime().toUnixTime() * 1_000);

    runSqlCommandDb(db,
        "INSERT INTO face_photos (source_path, source_mtime_ms, analyzed_at_ms) VALUES ('"
            ~ esc ~ "'," ~ to!string(mtimeMs) ~ "," ~ now
            ~ ") ON CONFLICT(source_path) DO UPDATE SET source_mtime_ms=excluded.source_mtime_ms, analyzed_at_ms=excluded.analyzed_at_ms;");

    auto photoId = querySqlOutputDb(db,
        "SELECT id FROM face_photos WHERE source_path='" ~ esc ~ "' LIMIT 1;").strip();
    if (photoId.length == 0)
        return false;

    runSqlCommandDb(db, "DELETE FROM faces WHERE source_path='" ~ esc ~ "';");

    foreach (ref det; detections)
    {
        // Cluster: find best matching fingerprint by embedding similarity
        auto matchHex = findMatchingFingerprint(db, det.embedding);
        auto embHex = encodeEmbeddingHex(det.embedding);

        if (matchHex.length == 0)
        {
            // New person — create a new fingerprint using a SHA-1 of the embedding
            matchHex = toHexString(sha1Of(
                    sourcePath ~ "|" ~ to!string(
                    det.x) ~ "|" ~ to!string(det.y)
                    ~ "|" ~ to!string(
                    det.w) ~ "|" ~ to!string(det.h)
                    ~ "|" ~ embHex[0 .. 64])).idup;
            runSqlCommandDb(db,
                "INSERT OR IGNORE INTO face_fingerprints (fingerprint_hex, embedding) VALUES ('"
                    ~ sqlEscape(
                        matchHex) ~ "','" ~ embHex ~ "');");
        }

        det.fingerprintHex = matchHex;

        // Get person_name from the fingerprint (may be NULL)
        auto personName = querySqlOutputDb(db,
            "SELECT COALESCE(person_name,'') FROM face_fingerprints WHERE fingerprint_hex='"
                ~ sqlEscape(
                    matchHex) ~ "' LIMIT 1;").strip();

        runSqlCommandDb(db,
            "INSERT INTO faces (photo_id, source_path, thumb_path, x, y, w, h, image_width, image_height, fingerprint_hex, person_name, embedding) VALUES ("
                ~ photoId ~ ",'" ~ esc ~ "','" ~ sqlEscape(
                    thumbPath) ~ "',"
                ~ to!string(det.x) ~ "," ~ to!string(
                    det.y) ~ ","
                ~ to!string(det.w) ~ "," ~ to!string(
                    det.h) ~ ","
                ~ to!string(det.imageWidth > 0 ? det.imageWidth
                    : 1) ~ ","
                ~ to!string(det.imageHeight > 0 ? det.imageHeight
                    : 1) ~ ",'"
                ~ sqlEscape(matchHex) ~ "','"
                ~ sqlEscape(
                    personName) ~ "','" ~ embHex ~ "');");
    }
    return true;
}

void scanLibraryFaces(const string rootPath,
    void delegate(size_t scanned, long unknownCount) nothrow progressCb = null)
{
    if (!exists(rootPath) || !isDir(rootPath))
        return;
    auto cacheRoot = defaultCacheRoot();
    auto dbp = faceDbPath();
    auto db = openSqliteDb(dbp);
    if (db is null)
        return;
    scope (exit)
        sqlite3_close(db);
    if (!ensureFaceSchemaDb(db))
        return;

    runSqlCommandDb(db, "BEGIN TRANSACTION;");
    size_t count = 0, batch = 0;
    foreach (entry; dirEntries(rootPath, SpanMode.depth, true))
    {
        if (!entry.isFile || !isImageFile(entry.name))
            continue;
        auto mtimeMs = fileModifiedMs(entry.name);
        auto key = thumbnailKey(entry.name, cast(long) entry.size, mtimeMs);
        auto thumbPath = ensureDerivedImage(entry.name, cacheRoot, key, "thumb", 512, 82);
        syncFacesForImage(db, entry.name, thumbPath.length == 0 ? entry.name : thumbPath, mtimeMs);
        count++;
        batch++;
        if (batch >= 50)
        {
            runSqlCommandDb(db, "COMMIT;");
            runSqlCommandDb(db, "BEGIN TRANSACTION;");
            batch = 0;

            // Report progress every batch
            if (progressCb !is null)
            {
                try
                {
                    auto ukCount = sqlCountOrZeroDb(db,
                        "SELECT COUNT(*) FROM face_fingerprints WHERE person_name IS NULL OR TRIM(person_name)='';");
                    progressCb(count, ukCount);
                }
                catch (Exception)
                {
                }
            }
        }
        if (count >= MAX_FACE_SCAN_IMAGES)
            break;
    }
    runSqlCommandDb(db, "COMMIT;");
    log.info("face scan complete — %s images", count);
}

// ---------------------------------------------------------------------------
// JSON endpoints
// ---------------------------------------------------------------------------

string unnamedFacesJson()
{
    auto dbp = faceDbPath();
    auto db = openSqliteDb(dbp);
    if (db is null)
        return "{\"faces\":[]}";
    scope (exit)
        sqlite3_close(db);
    if (!ensureFaceSchemaDb(db))
        return "{\"faces\":[]}";

    auto output = querySqlOutputDb(db,
        "SELECT id, source_path, thumb_path, x, y, w, h, image_width, image_height, "
            ~ "COALESCE(person_name,''), fingerprint_hex FROM faces "
            ~ "WHERE person_name IS NULL OR TRIM(person_name)='' ORDER BY id DESC LIMIT " ~ to!string(
                MAX_FACE_MATCHES) ~ ";");

    auto b = appender!string();
    b.put("{\"faces\":[");
    bool first = true;
    foreach (line; output.splitLines())
    {
        auto t = line.strip();
        if (t.length == 0)
            continue;
        auto c = t.split("\t");
        if (c.length < 11)
            continue;
        if (!first)
            b.put(",");
        b.put("{\"faceId\":");
        b.put(c[0]);
        b.put(",\"sourceUrl\":\"");
        b.put(jsonEscape(toFileUrl(c[1])));
        b.put("\",\"thumbUrl\":\"");
        b.put(jsonEscape(toFileUrl(c[2])));
        b.put("\",\"x\":");
        b.put(c[3]);
        b.put(",\"y\":");
        b.put(c[4]);
        b.put(",\"w\":");
        b.put(c[5]);
        b.put(",\"h\":");
        b.put(c[6]);
        b.put(",\"imageWidth\":");
        b.put(c[7]);
        b.put(",\"imageHeight\":");
        b.put(c[8]);
        b.put(",\"personName\":\"");
        b.put(jsonEscape(c[9]));
        b.put("\",\"fingerprint\":\"");
        b.put(jsonEscape(c[10]));
        b.put("\"}");
        first = false;
    }
    b.put("]}");
    return b.data;
}

string peopleFingerprintsJson()
{
    auto dbp = faceDbPath();
    auto db = openSqliteDb(dbp);
    if (db is null)
        return "{\"fingerprints\":[]}";
    scope (exit)
        sqlite3_close(db);
    if (!ensureFaceSchemaDb(db))
        return "{\"fingerprints\":[]}";

    auto output = querySqlOutputDb(db,
        "SELECT fp.id, fp.fingerprint_hex, COALESCE(fp.person_name,''), "
            ~ "f.source_path, f.thumb_path, f.x, f.y, f.w, f.h, f.image_width, f.image_height, "
            ~ "(SELECT COUNT(*) FROM faces f2 WHERE f2.fingerprint_hex = fp.fingerprint_hex) "
            ~ "FROM face_fingerprints fp "
            ~ "JOIN faces f ON f.id = (SELECT MIN(id) FROM faces fs WHERE fs.fingerprint_hex = fp.fingerprint_hex) "
            ~ "ORDER BY fp.id DESC LIMIT " ~ to!string(MAX_FACE_MATCHES) ~ ";");

    auto b = appender!string();
    b.put("{\"fingerprints\":[");
    bool first = true;
    foreach (line; output.splitLines())
    {
        auto t = line.strip();
        if (t.length == 0)
            continue;
        auto c = t.split("\t");
        if (c.length < 12)
            continue;
        if (!first)
            b.put(",");
        b.put("{\"fingerprintId\":");
        b.put(c[0]);
        b.put(",\"personName\":\"");
        b.put(jsonEscape(c[2]));
        b.put("\",\"fingerprint\":\"");
        b.put(jsonEscape(c[1]));
        b.put("\",\"sourceUrl\":\"");
        b.put(jsonEscape(toFileUrl(c[3])));
        b.put("\",\"thumbUrl\":\"");
        b.put(jsonEscape(toFileUrl(c[4])));
        b.put("\",\"x\":");
        b.put(c[5]);
        b.put(",\"y\":");
        b.put(c[6]);
        b.put(",\"w\":");
        b.put(c[7]);
        b.put(",\"h\":");
        b.put(c[8]);
        b.put(",\"imageWidth\":");
        b.put(c[9]);
        b.put(",\"imageHeight\":");
        b.put(c[10]);
        b.put(",\"faceCount\":");
        b.put(c[11]);
        b.put("}");
        first = false;
    }
    b.put("]}");
    return b.data;
}

/// Return JSON array of faces detected in a given photo, by source path.
string facesForPhotoJson(const string sourcePath)
{
    auto dbp = faceDbPath();
    auto db = openSqliteDb(dbp);
    if (db is null)
        return "{\"faces\":[]}";
    scope (exit)
        sqlite3_close(db);
    if (!ensureFaceSchemaDb(db))
        return "{\"faces\":[]}";

    auto esc = sqlEscape(sourcePath);
    auto output = querySqlOutputDb(db,
        "SELECT f.id, f.x, f.y, f.w, f.h, f.image_width, f.image_height, "
            ~ "COALESCE(f.person_name,''), f.fingerprint_hex, "
            ~ "COALESCE(fp.person_name,'') "
            ~ "FROM faces f "
            ~ "LEFT JOIN face_fingerprints fp ON fp.fingerprint_hex = f.fingerprint_hex "
            ~ "WHERE f.source_path='" ~ esc ~ "' ORDER BY f.x;");

    auto b = appender!string();
    b.put("{\"faces\":[");
    bool first = true;
    foreach (line; output.splitLines())
    {
        auto t = line.strip();
        if (t.length == 0)
            continue;
        auto c = t.split("\t");
        if (c.length < 10)
            continue;
        if (!first)
            b.put(",");
        // Use fingerprint-level name if the per-face name is empty
        auto faceName = c[7];
        auto fpName = c[9];
        auto displayName = (faceName.length > 0) ? faceName : fpName;
        b.put("{\"faceId\":");
        b.put(c[0]);
        b.put(",\"x\":");
        b.put(c[1]);
        b.put(",\"y\":");
        b.put(c[2]);
        b.put(",\"w\":");
        b.put(c[3]);
        b.put(",\"h\":");
        b.put(c[4]);
        b.put(",\"imageWidth\":");
        b.put(c[5]);
        b.put(",\"imageHeight\":");
        b.put(c[6]);
        b.put(",\"personName\":\"");
        b.put(jsonEscape(displayName));
        b.put("\",\"fingerprint\":\"");
        b.put(jsonEscape(c[8]));
        b.put("\"}");
        first = true == false; // always false after first
        first = false;
    }
    b.put("]}");
    return b.data;
}

/// Return a mapping from source_path → comma-separated person names for all photos with faces.
/// Used to enrich the index with face labels without per-photo queries.
string[string] allPhotoFaceNames()
{
    string[string] result;
    auto dbp = faceDbPath();
    auto db = openSqliteDb(dbp);
    if (db is null)
        return result;
    scope (exit)
        sqlite3_close(db);
    if (!ensureFaceSchemaDb(db))
        return result;

    auto output = querySqlOutputDb(db,
        "SELECT f.source_path, COALESCE(NULLIF(fp.person_name,''), NULLIF(f.person_name,''), '') "
            ~ "FROM faces f "
            ~ "LEFT JOIN face_fingerprints fp ON fp.fingerprint_hex = f.fingerprint_hex "
            ~ "ORDER BY f.source_path, f.x;");

    string lastPath;
    string[] names;
    foreach (line; output.splitLines())
    {
        auto t = line.strip();
        if (t.length == 0)
            continue;
        auto tabPos = t.indexOf('\t');
        if (tabPos < 0)
            continue;
        auto path = t[0 .. tabPos];
        auto name = t[tabPos + 1 .. $].strip();

        if (path != lastPath && lastPath.length > 0)
        {
            result[lastPath] = joinNames(names);
            names.length = 0;
        }
        lastPath = path;
        if (name.length > 0)
            names ~= name;
    }
    if (lastPath.length > 0)
        result[lastPath] = joinNames(names);

    return result;
}

private string joinNames(string[] names)
{
    if (names.length == 0)
        return "";
    // Deduplicate and join
    bool[string] seen;
    auto b = appender!string();
    bool first = true;
    foreach (n; names)
    {
        if (n in seen)
            continue;
        seen[n] = true;
        if (!first)
            b.put(", ");
        b.put(n);
        first = false;
    }
    return b.data;
}

long unknownPeopleCount()
{
    auto dbp = faceDbPath();
    auto db = openSqliteDb(dbp);
    if (db is null)
        return 0;
    scope (exit)
        sqlite3_close(db);
    return sqlCountOrZeroDb(db,
        "SELECT COUNT(*) FROM face_fingerprints WHERE person_name IS NULL OR TRIM(person_name)='';");
}

string faceDbStatusJson()
{
    auto dbp = faceDbPath();
    bool dbExists = exists(dbp);
    auto db = openSqliteDb(dbp);
    bool schemaReady = db !is null && ensureFaceSchemaDb(db);
    long faces, fps, unknown, photos;
    if (schemaReady)
    {
        faces = sqlCountOrZeroDb(db, "SELECT COUNT(*) FROM faces;");
        fps = sqlCountOrZeroDb(db, "SELECT COUNT(*) FROM face_fingerprints;");
        unknown = sqlCountOrZeroDb(db, "SELECT COUNT(*) FROM face_fingerprints WHERE person_name IS NULL OR TRIM(person_name)='';");
        photos = sqlCountOrZeroDb(db, "SELECT COUNT(*) FROM face_photos;");
    }
    if (db !is null)
        sqlite3_close(db);
    auto b = appender!string();
    b.put("{\"ok\":");
    b.put(schemaReady ? "true" : "false");
    b.put(",\"dbExists\":");
    b.put(dbExists ? "true" : "false");
    b.put(",\"faces\":");
    b.put(to!string(faces));
    b.put(",\"fingerprints\":");
    b.put(to!string(fps));
    b.put(",\"unknownPeople\":");
    b.put(to!string(unknown));
    b.put(",\"photos\":");
    b.put(to!string(photos));
    b.put("}");
    return b.data;
}

bool setFaceNameInDb(long faceId, string name)
{
    auto dbp = faceDbPath();
    auto db = openSqliteDb(dbp);
    if (db is null)
        return false;
    scope (exit)
        sqlite3_close(db);
    if (!ensureFaceSchemaDb(db))
        return false;
    auto hex = querySqlOutputDb(db,
        "SELECT fingerprint_hex FROM faces WHERE id=" ~ to!string(faceId) ~ " LIMIT 1;").strip();
    if (hex.length == 0)
        return false;
    auto eHex = sqlEscape(hex), eName = sqlEscape(name);
    return runSqlCommandDb(db, "UPDATE face_fingerprints SET person_name='" ~ eName ~ "' WHERE fingerprint_hex='" ~ eHex ~ "';")
        && runSqlCommandDb(db, "UPDATE faces SET person_name='" ~ eName ~ "' WHERE fingerprint_hex='" ~ eHex ~ "';");
}

bool setFingerprintNameInDb(long fpId, string name)
{
    auto dbp = faceDbPath();
    auto db = openSqliteDb(dbp);
    if (db is null)
        return false;
    scope (exit)
        sqlite3_close(db);
    if (!ensureFaceSchemaDb(db))
        return false;
    auto eName = sqlEscape(name);
    if (!runSqlCommandDb(db, "UPDATE face_fingerprints SET person_name='" ~ eName ~ "' WHERE id=" ~ to!string(
            fpId) ~ ";"))
        return false;
    return runSqlCommandDb(db,
        "UPDATE faces SET person_name='" ~ eName ~ "' WHERE fingerprint_hex=(SELECT fingerprint_hex FROM face_fingerprints WHERE id=" ~ to!string(
            fpId) ~ " LIMIT 1);");
}

// ---------------------------------------------------------------------------
// Photo index
// ---------------------------------------------------------------------------

string buildIndexJson(const string rootPath)
{
    if (!exists(rootPath) || !isDir(rootPath))
        return `{"sections":[],"flat":[],"dateTree":[],"count":0}`;

    auto cacheRoot = defaultCacheRoot();
    PhotoItem[] items;
    size_t metaCount, fallbackCount, scanned;

    foreach (entry; dirEntries(rootPath, SpanMode.depth, true))
    {
        scanned++;
        if (scanned > MAX_SCANNED_ENTRIES)
            break;
        if (!entry.isFile || !isImageFile(entry.name))
            continue;

        auto mtimeMs = fileModifiedMs(entry.name);
        auto key = thumbnailKey(entry.name, cast(long) entry.size, mtimeMs);
        auto thumbPath = ensureDerivedImage(entry.name, cacheRoot, key, "thumb", 512, 82);
        auto screenPath = ensureDerivedImage(entry.name, cacheRoot, key, "screen", 1920, 88);
        auto metadata = readPhotoMetadata(entry.name, mtimeMs);
        if (metadata.usedFallback)
            fallbackCount++;
        else
            metaCount++;

        auto dim = dimensionsFromVips(entry.name);
        PhotoItem item;
        item.sourcePath = entry.name;
        item.thumbPath = thumbPath.length == 0 ? entry.name : thumbPath;
        item.screenPath = screenPath.length == 0 ? entry.name : screenPath;
        item.sourceWidth = dim.width;
        item.sourceHeight = dim.height;
        item.dateTime = metadata.dateTime;
        item.monthTitle = humanizedMonthFrom(item.dateTime);
        item.subtitle = metadata.city.length == 0 ? item.monthTitle : metadata.city;
        items ~= item;
        if (items.length >= MAX_INDEXED_IMAGES)
            break;
    }

    items.sort!compareItems();

    // Load face names for enrichment.
    auto faceNames = allPhotoFaceNames();

    // Build JSON using appender
    int[int][int] yearMonthCounts;
    int[] years;
    auto b = appender!string();
    b.put("{\"sections\":[");
    string currentMonth;
    size_t flatIndex;
    bool firstSection = true, sectionOpen = false, firstItem = true;

    foreach (item; items)
    {
        auto local = item.dateTime.toLocalTime();
        auto year = cast(int) local.year;
        auto month = cast(int) local.month;
        if (year !in yearMonthCounts)
        {
            yearMonthCounts[year] = null;
            years ~= year;
        }
        yearMonthCounts[year][month] = yearMonthCounts[year].get(month, 0) + 1;

        if (currentMonth != item.monthTitle)
        {
            if (sectionOpen)
                b.put("]}");
            if (!firstSection)
                b.put(",");
            b.put("{\"title\":\"");
            b.put(jsonEscape(item.monthTitle));
            b.put("\",\"items\":[");
            currentMonth = item.monthTitle;
            firstSection = false;
            sectionOpen = true;
            firstItem = true;
        }
        if (!firstItem)
            b.put(",");
        auto people = (item.sourcePath in faceNames) ? faceNames[item.sourcePath] : "";
        b.put("{\"thumbUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.thumbPath)));
        b.put("\",\"screenUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.screenPath)));
        b.put("\",\"sourceUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.sourcePath)));
        b.put("\",\"subtitle\":\"");
        b.put(jsonEscape(item.subtitle));
        b.put("\",\"people\":\"");
        b.put(jsonEscape(people));
        b.put("\",\"sourceWidth\":");
        b.put(to!string(item.sourceWidth > 0 ? item.sourceWidth : 1));
        b.put(",\"sourceHeight\":");
        b.put(to!string(item.sourceHeight > 0 ? item.sourceHeight : 1));
        b.put(",\"flatIndex\":");
        b.put(to!string(flatIndex));
        b.put("}");
        firstItem = false;
        flatIndex++;
    }
    if (sectionOpen)
        b.put("]}");
    b.put("],\"flat\":[");

    bool firstFlat = true;
    for (size_t i = 0; i < items.length; i++)
    {
        auto item = items[i];
        if (!firstFlat)
            b.put(",");
        auto people = (item.sourcePath in faceNames) ? faceNames[item.sourcePath] : "";
        b.put("{\"thumbUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.thumbPath)));
        b.put("\",\"screenUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.screenPath)));
        b.put("\",\"sourceUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.sourcePath)));
        b.put("\",\"subtitle\":\"");
        b.put(jsonEscape(item.subtitle));
        b.put("\",\"people\":\"");
        b.put(jsonEscape(people));
        b.put("\",\"sourceWidth\":");
        b.put(to!string(item.sourceWidth > 0 ? item.sourceWidth : 1));
        b.put(",\"sourceHeight\":");
        b.put(to!string(item.sourceHeight > 0 ? item.sourceHeight : 1));
        b.put(",\"flatIndex\":");
        b.put(to!string(i));
        b.put("}");
        firstFlat = false;
    }
    b.put("],\"dateTree\":[");

    years.sort!((a, bv) => a > bv);
    bool firstYear = true;
    foreach (year; years)
    {
        if (!firstYear)
            b.put(",");
        b.put("{\"year\":");
        b.put(to!string(year));
        b.put(",\"months\":[");
        int[] months;
        foreach (m, _; yearMonthCounts[year])
            months ~= m;
        months.sort!((a, bv) => a > bv);
        bool firstMonth = true;
        foreach (m; months)
        {
            if (!firstMonth)
                b.put(",");
            b.put("{\"month\":\"");
            b.put(monthName(m));
            b.put("\",\"monthNum\":");
            b.put(to!string(m));
            b.put(",\"count\":");
            b.put(to!string(yearMonthCounts[year][m]));
            b.put("}");
            firstMonth = false;
        }
        b.put("]}");
        firstYear = false;
    }
    b.put("],\"count\":");
    b.put(to!string(items.length));
    b.put("}");

    log.info("index %s files (%s exif, %s fallback)", items.length, metaCount, fallbackCount);
    return b.data;
}

// ---------------------------------------------------------------------------
// Fast dates-only scan (no EXIF, no thumbnails — just fs stat)
// ---------------------------------------------------------------------------

string buildDatesJson(const string rootPath)
{
    if (!exists(rootPath) || !isDir(rootPath))
        return `{"dateTree":[],"count":0}`;

    int[int][int] yearMonthCounts;
    int[] years;
    int total;

    foreach (entry; dirEntries(rootPath, SpanMode.depth, true))
    {
        if (total >= MAX_SCANNED_ENTRIES)
            break;
        total++;
        if (!entry.isFile || !isImageFile(entry.name))
            continue;

        auto mtimeMs = fileModifiedMs(entry.name);
        auto dt = SysTime.fromUnixTime(mtimeMs / 1_000);
        auto local = dt.toLocalTime();
        auto year = cast(int) local.year;
        auto month = cast(int) local.month;
        if (year !in yearMonthCounts)
        {
            yearMonthCounts[year] = null;
            years ~= year;
        }
        yearMonthCounts[year][month] = yearMonthCounts[year].get(month, 0) + 1;
    }

    int imageCount;
    foreach (yr; years)
        foreach (_, cnt; yearMonthCounts[yr])
            imageCount += cnt;

    auto b = appender!string();
    b.put("{\"dateTree\":[");
    years.sort!((a, bv) => a > bv);
    bool firstYear = true;
    foreach (year; years)
    {
        if (!firstYear)
            b.put(",");
        b.put("{\"year\":");
        b.put(to!string(year));
        b.put(",\"months\":[");
        int[] months;
        foreach (m, _; yearMonthCounts[year])
            months ~= m;
        months.sort!((a, bv) => a > bv);
        bool firstMonth = true;
        foreach (m; months)
        {
            if (!firstMonth)
                b.put(",");
            b.put("{\"month\":\"");
            b.put(monthName(m));
            b.put("\",\"monthNum\":");
            b.put(to!string(m));
            b.put(",\"count\":");
            b.put(to!string(yearMonthCounts[year][m]));
            b.put("}");
            firstMonth = false;
        }
        b.put("]}");
        firstYear = false;
    }
    b.put("],\"count\":");
    b.put(to!string(imageCount));
    b.put("}");
    log.info("dates scan — %s images", imageCount);
    return b.data;
}

// ---------------------------------------------------------------------------
// Paginated index  (offset / limit)
// Returns one page of sections + flat items for the requested range.
// ---------------------------------------------------------------------------

string buildIndexPageJson(const string rootPath, const int offset, const int limit)
{
    if (!exists(rootPath) || !isDir(rootPath))
        return `{"sections":[],"flat":[],"count":0,"offset":0,"limit":0,"total":0}`;

    // Collect and sort all paths with minimal work (only stat, no EXIF yet).
    struct PathEntry
    {
        string path;
        long size;
        long mtimeMs;
    }

    PathEntry[] entries;
    size_t scanned;

    foreach (entry; dirEntries(rootPath, SpanMode.depth, true))
    {
        scanned++;
        if (scanned > MAX_SCANNED_ENTRIES)
            break;
        if (!entry.isFile || !isImageFile(entry.name))
            continue;
        PathEntry pe;
        pe.path = entry.name;
        pe.size = cast(long) entry.size;
        pe.mtimeMs = fileModifiedMs(entry.name);
        entries ~= pe;
        if (entries.length >= MAX_INDEXED_IMAGES)
            break;
    }

    // Sort by mtime descending (newest first), tie-break by path.
    entries.sort!((a, bv) => a.mtimeMs != bv.mtimeMs ? a.mtimeMs > bv.mtimeMs : a.path < bv.path);

    const total = cast(int) entries.length;
    const safeOffset = (offset >= 0 && offset < total) ? offset : 0;
    const safeLimit = (limit > 0) ? limit : 200;
    const end = (safeOffset + safeLimit > total) ? total : safeOffset + safeLimit;

    // Now do full processing (EXIF, thumbnails) only for the requested page.
    auto cacheRoot = defaultCacheRoot();
    PhotoItem[] items;

    foreach (i; safeOffset .. end)
    {
        auto pe = entries[i];
        auto key = thumbnailKey(pe.path, pe.size, pe.mtimeMs);
        auto thumbPath = ensureDerivedImage(pe.path, cacheRoot, key, "thumb", 512, 82);
        auto screenPath = ensureDerivedImage(pe.path, cacheRoot, key, "screen", 1920, 88);
        auto metadata = readPhotoMetadata(pe.path, pe.mtimeMs);
        auto dim = dimensionsFromVips(pe.path);

        PhotoItem item;
        item.sourcePath = pe.path;
        item.thumbPath = thumbPath.length == 0 ? pe.path : thumbPath;
        item.screenPath = screenPath.length == 0 ? pe.path : screenPath;
        item.sourceWidth = dim.width;
        item.sourceHeight = dim.height;
        item.dateTime = metadata.dateTime;
        item.monthTitle = humanizedMonthFrom(item.dateTime);
        item.subtitle = metadata.city.length == 0 ? item.monthTitle : metadata.city;
        items ~= item;
    }

    // Load face names for photos in this page (one bulk query, not per-photo).
    auto faceNames = allPhotoFaceNames();

    // Build JSON — sections + flat for this page.
    auto b = appender!string();
    b.put("{\"sections\":[");
    string currentMonth;
    bool firstSection = true, sectionOpen = false, firstItem = true;

    foreach (idx, item; items)
    {
        if (currentMonth != item.monthTitle)
        {
            if (sectionOpen)
                b.put("]}");
            if (!firstSection)
                b.put(",");
            b.put("{\"title\":\"");
            b.put(jsonEscape(item.monthTitle));
            b.put("\",\"items\":[");
            currentMonth = item.monthTitle;
            firstSection = false;
            sectionOpen = true;
            firstItem = true;
        }
        if (!firstItem)
            b.put(",");
        auto flatIdx = safeOffset + cast(int) idx;
        auto people = (item.sourcePath in faceNames) ? faceNames[item.sourcePath] : "";
        b.put("{\"thumbUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.thumbPath)));
        b.put("\",\"screenUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.screenPath)));
        b.put("\",\"sourceUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.sourcePath)));
        b.put("\",\"subtitle\":\"");
        b.put(jsonEscape(item.subtitle));
        b.put("\",\"people\":\"");
        b.put(jsonEscape(people));
        b.put("\",\"sourceWidth\":");
        b.put(to!string(item.sourceWidth > 0 ? item.sourceWidth : 1));
        b.put(",\"sourceHeight\":");
        b.put(to!string(item.sourceHeight > 0 ? item.sourceHeight : 1));
        b.put(",\"flatIndex\":");
        b.put(to!string(flatIdx));
        b.put("}");
        firstItem = false;
    }
    if (sectionOpen)
        b.put("]}");
    b.put("],\"flat\":[");

    bool firstFlat = true;
    foreach (idx, item; items)
    {
        if (!firstFlat)
            b.put(",");
        auto flatIdx = safeOffset + cast(int) idx;
        auto people = (item.sourcePath in faceNames) ? faceNames[item.sourcePath] : "";
        b.put("{\"thumbUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.thumbPath)));
        b.put("\",\"screenUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.screenPath)));
        b.put("\",\"sourceUrl\":\"");
        b.put(jsonEscape(toFileUrl(item.sourcePath)));
        b.put("\",\"subtitle\":\"");
        b.put(jsonEscape(item.subtitle));
        b.put("\",\"people\":\"");
        b.put(jsonEscape(people));
        b.put("\",\"sourceWidth\":");
        b.put(to!string(item.sourceWidth > 0 ? item.sourceWidth : 1));
        b.put(",\"sourceHeight\":");
        b.put(to!string(item.sourceHeight > 0 ? item.sourceHeight : 1));
        b.put(",\"flatIndex\":");
        b.put(to!string(flatIdx));
        b.put("}");
        firstFlat = false;
    }
    b.put("],\"count\":");
    b.put(to!string(items.length));
    b.put(",\"offset\":");
    b.put(to!string(safeOffset));
    b.put(",\"limit\":");
    b.put(to!string(safeLimit));
    b.put(",\"total\":");
    b.put(to!string(total));
    b.put("}");

    log.dbg("page [%s..%s) of %s", safeOffset, end, total);
    return b.data;
}
