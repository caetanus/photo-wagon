module indexer.indexer_service;

import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy;
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
import std.string : fromStringz, replace, split, splitLines, strip, toLower, toStringz;
import std.typecons : Nullable;

extern (C) void photo_wagon_log_from_d(const char* message);

// C library bindings (gexiv2, libvips, glib) — replaces subprocess calls
private extern (C)
{
    // GLib
    void g_object_unref(void* object);
    void g_free(void* mem);
    void g_error_free(void* error);

    // gexiv2 — EXIF/XMP/IPTC metadata
    void* gexiv2_metadata_new();
    void gexiv2_metadata_free(void* self);
    int gexiv2_metadata_open_path(void* self, const char* path, void** error);
    char* gexiv2_metadata_try_get_tag_string(void* self, const char* tag, void** error);

    // libvips — image dimensions + thumbnail
    int vips_init(const char* argv0);
    void* vips_image_new_from_file(const char* name, ...);
    int vips_image_get_width(void* image);
    int vips_image_get_height(void* image);
    int vips_thumbnail(const char* filename, void** out_, int width, ...);
    int vips_jpegsave(void* in_, const char* filename, ...);
}

private __gshared bool gVipsInitDone = false;

private void ensureVipsInit()
{
    if (!gVipsInitDone)
    {
        vips_init("photo-wagon".ptr);
        gVipsInitDone = true;
    }
}

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
    int x;
    int y;
    int w;
    int h;
    int imageWidth;
    int imageHeight;
    string fingerprintHex;
}

struct FaceRecord
{
    long id;
    string sourcePath;
    string thumbPath;
    int x;
    int y;
    int w;
    int h;
    int imageWidth;
    int imageHeight;
    string personName;
    string fingerprintHex;
}

struct FingerprintRecord
{
    long fingerprintId;
    string fingerprintHex;
    string personName;
    string sourcePath;
    string thumbPath;
    int x;
    int y;
    int w;
    int h;
    int imageWidth;
    int imageHeight;
    int faceCount;
}

struct ImageDimensions
{
    int width;
    int height;
}

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

private string defaultCacheRoot()
{
    auto home = environment.get("HOME", ".");
    auto cacheRoot = buildPath(home, ".cache", "photo-wagon");
    if (!exists(cacheRoot))
    {
        mkdirRecurse(cacheRoot);
    }
    return cacheRoot;
}

private bool isImageFile(const string filePath)
{
    return IMAGE_EXTENSIONS.canFind(extension(filePath).toLower());
}

private string thumbnailKey(const string path, const long size, const long mtimeMs)
{
    return toHexString(sha1Of(path ~ "|" ~ to!string(size) ~ "|" ~ to!string(mtimeMs))).idup;
}

private long fileModifiedMs(const string filePath)
{
    stat_t st = void;
    if (stat(toStringz(filePath), &st) != 0)
    {
        return cast(long) Clock.currTime().toUnixTime() * 1_000;
    }
    return cast(long) st.st_mtime * 1_000;
}

private string ensureDerivedImage(
    const string sourcePath,
    const string cacheRoot,
    const string key,
    const string variant,
    const int maxEdge,
    const int quality
)
{
    const shard = key[0 .. 2];
    const shardDir = buildPath(cacheRoot, shard);
    if (!exists(shardDir))
    {
        mkdirRecurse(shardDir);
    }

    const outName = key[0 .. 8] ~ "-" ~ variant ~ ".jpg";
    const outPath = buildPath(shardDir, outName);
    if (exists(outPath))
    {
        return outPath;
    }

    ensureVipsInit();

    void* thumb = null;
    if (vips_thumbnail(toStringz(sourcePath), &thumb, maxEdge, cast(void*) null) != 0)
    {
        return "";
    }
    if (thumb is null)
    {
        return "";
    }
    scope (exit)
        g_object_unref(thumb);

    if (vips_jpegsave(thumb, toStringz(outPath), "Q".ptr, quality, cast(void*) null) != 0)
    {
        return "";
    }

    return outPath;
}

private ImageDimensions dimensionsFromVips(const string sourcePath)
{
    ImageDimensions dimensions;
    dimensions.width = 1;
    dimensions.height = 1;

    ensureVipsInit();

    auto img = vips_image_new_from_file(toStringz(sourcePath), cast(void*) null);
    if (img is null)
    {
        return dimensions;
    }
    scope (exit)
        g_object_unref(img);

    const w = vips_image_get_width(img);
    const h = vips_image_get_height(img);
    if (w > 0)
    {
        dimensions.width = w;
    }
    if (h > 0)
    {
        dimensions.height = h;
    }

    return dimensions;
}

private Nullable!SysTime parseExifDateTime(const string value)
{
    auto text = value.strip();
    if (text.length < 10)
    {
        return Nullable!SysTime();
    }

    auto sanitized = text.dup;
    if (sanitized.length >= 10)
    {
        sanitized[4] = '-';
        sanitized[7] = '-';
    }
    if (sanitized.length == 10)
    {
        sanitized ~= " 00:00:00";
    }

    if (sanitized.length >= 19)
    {
        try
        {
            const dt = DateTime(
                sanitized[0 .. 4].to!int,
                sanitized[5 .. 7].to!int,
                sanitized[8 .. 10].to!int,
                sanitized[11 .. 13].to!int,
                sanitized[14 .. 16].to!int,
                sanitized[17 .. 19].to!int
            );
            return Nullable!SysTime(SysTime(dt));
        }
        catch (Exception)
        {
        }
    }

    return Nullable!SysTime();
}

private PhotoMetadata readPhotoMetadata(const string filePath, const long fallbackMtimeMs)
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
                {
                    break;
                }
                void* tagError = null;
                auto val = gexiv2_metadata_try_get_tag_string(
                    exivMeta, toStringz(key), &tagError
                );
                if (val !is null)
                {
                    const parsed = parseExifDateTime(fromStringz(val).idup);
                    g_free(val);
                    if (!parsed.isNull)
                    {
                        metadata.dateTime = parsed.get;
                    }
                }
                if (tagError !is null)
                {
                    g_error_free(tagError);
                }
            }

            foreach (key; CITY_KEYS)
            {
                if (metadata.city.length > 0)
                {
                    break;
                }
                void* tagError = null;
                auto val = gexiv2_metadata_try_get_tag_string(
                    exivMeta, toStringz(key), &tagError
                );
                if (val !is null)
                {
                    const city = fromStringz(val).idup.strip();
                    g_free(val);
                    if (city.length > 0)
                    {
                        metadata.city = city;
                    }
                }
                if (tagError !is null)
                {
                    g_error_free(tagError);
                }
            }
        }
        if (openError !is null)
        {
            g_error_free(openError);
        }
    }

    if (metadata.dateTime == SysTime.init)
    {
        metadata.dateTime = SysTime.fromUnixTime(fallbackMtimeMs / 1_000);
        metadata.usedFallback = true;
    }

    return metadata;
}

private string monthName(const int month)
{
    static immutable names = [
        "", "January", "February", "March", "April", "May", "June",
        "July", "August", "September", "October", "November", "December"
    ];
    if (month < 1 || month > 12)
    {
        return "Unknown";
    }
    return names[month];
}

private string humanizedMonthFrom(const SysTime dateTime)
{
    const local = dateTime.toLocalTime();
    return monthName(local.month) ~ " " ~ to!string(local.year);
}

private string jsonEscape(const string value)
{
    auto builder = appender!string();
    foreach (ch; value)
    {
        switch (ch)
        {
        case '"':
            builder.put("\\\"");
            break;
        case '\\':
            builder.put("\\\\");
            break;
        case '\b':
            builder.put("\\b");
            break;
        case '\f':
            builder.put("\\f");
            break;
        case '\n':
            builder.put("\\n");
            break;
        case '\r':
            builder.put("\\r");
            break;
        case '\t':
            builder.put("\\t");
            break;
        default:
            if (ch < 0x20)
            {
                builder.put(format("\\u%04x", cast(int) ch));
            }
            else
            {
                builder.put(ch);
            }
        }
    }
    return builder.data;
}

private string toFileUrl(string path)
{
    path = path.replace("%", "%25");
    path = path.replace("#", "%23");
    path = path.replace("?", "%3F");
    path = path.replace(" ", "%20");
    return "file://" ~ path;
}

private bool compareItems(ref const PhotoItem left, ref const PhotoItem right)
{
    if (left.dateTime.stdTime > right.dateTime.stdTime)
    {
        return true;
    }
    if (left.dateTime.stdTime < right.dateTime.stdTime)
    {
        return false;
    }
    return left.sourcePath < right.sourcePath;
}

private string sqlEscape(string value)
{
    return value.replace("'", "''");
}

private extern (C) int sqliteCollectRowsCallback(
    void* userData,
    int columnCount,
    char** columnValues,
    char**
)
{
    auto output = cast(string*) userData;
    if (output is null)
    {
        return 0;
    }

    foreach (index; 0 .. columnCount)
    {
        if (index > 0)
        {
            *output ~= "\t";
        }

        const value = columnValues[index];
        if (value !is null)
        {
            *output ~= fromStringz(value);
        }
    }
    *output ~= "\n";

    return 0;
}

private sqlite3* openSqliteDb(const string dbPath)
{
    sqlite3* db = null;
    const rc = sqlite3_open_v2(
        toStringz(dbPath),
        &db,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE,
        null
    );
    if (rc != SQLITE_OK || db is null)
    {
        if (db !is null)
        {
            sqlite3_close(db);
        }
        return null;
    }
    return db;
}

private bool runSqlCommand(const string dbPath, const string sql)
{
    auto db = openSqliteDb(dbPath);
    if (db is null)
    {
        return false;
    }

    scope (exit)
    {
        sqlite3_close(db);
    }

    char* errorMessage = null;
    const rc = sqlite3_exec(db, toStringz(sql), null, null, &errorMessage);
    if (errorMessage !is null)
    {
        sqlite3_free(errorMessage);
    }
    return rc == SQLITE_OK;
}

private string querySqlOutput(const string dbPath, const string sql)
{
    auto db = openSqliteDb(dbPath);
    if (db is null)
    {
        return "";
    }

    scope (exit)
    {
        sqlite3_close(db);
    }

    string output;
    char* errorMessage = null;
    const rc = sqlite3_exec(
        db,
        toStringz(sql),
        &sqliteCollectRowsCallback,
        &output,
        &errorMessage
    );
    if (errorMessage !is null)
    {
        sqlite3_free(errorMessage);
    }

    if (rc != SQLITE_OK)
    {
        return "";
    }

    return output;
}

private bool runSqlCommandDb(sqlite3* db, const string sql)
{
    char* errorMessage = null;
    const rc = sqlite3_exec(db, toStringz(sql), null, null, &errorMessage);
    if (errorMessage !is null)
    {
        sqlite3_free(errorMessage);
    }
    return rc == SQLITE_OK;
}

private string querySqlOutputDb(sqlite3* db, const string sql)
{
    string output;
    char* errorMessage = null;
    const rc = sqlite3_exec(
        db,
        toStringz(sql),
        &sqliteCollectRowsCallback,
        &output,
        &errorMessage
    );
    if (errorMessage !is null)
    {
        sqlite3_free(errorMessage);
    }
    if (rc != SQLITE_OK)
    {
        return "";
    }
    return output;
}

private long sqlCountOrZeroDb(sqlite3* db, const string sql)
{
    const output = querySqlOutputDb(db, sql).strip();
    if (output.length == 0)
    {
        return 0;
    }
    try
    {
        return output.to!long;
    }
    catch (Exception)
    {
        return 0;
    }
}

private bool ensureFaceSchemaDb(sqlite3* db)
{
    if (!runSqlCommandDb(db,
            "CREATE TABLE IF NOT EXISTS face_photos ("
            ~ "id INTEGER PRIMARY KEY AUTOINCREMENT,"
            ~ "source_path TEXT NOT NULL UNIQUE,"
            ~ "source_mtime_ms INTEGER NOT NULL,"
            ~ "analyzed_at_ms INTEGER NOT NULL"
            ~ ");"
            ~ "CREATE TABLE IF NOT EXISTS face_fingerprints ("
            ~ "id INTEGER PRIMARY KEY AUTOINCREMENT,"
            ~ "fingerprint_hex TEXT NOT NULL UNIQUE,"
            ~ "person_name TEXT"
            ~ ");"
            ~ "CREATE TABLE IF NOT EXISTS faces ("
            ~ "id INTEGER PRIMARY KEY AUTOINCREMENT,"
            ~ "photo_id INTEGER NOT NULL,"
            ~ "source_path TEXT NOT NULL,"
            ~ "thumb_path TEXT NOT NULL,"
            ~ "x INTEGER NOT NULL,"
            ~ "y INTEGER NOT NULL,"
            ~ "w INTEGER NOT NULL,"
            ~ "h INTEGER NOT NULL,"
            ~ "image_width INTEGER NOT NULL,"
            ~ "image_height INTEGER NOT NULL,"
            ~ "fingerprint_hex TEXT NOT NULL,"
            ~ "person_name TEXT,"
            ~ "FOREIGN KEY(photo_id) REFERENCES face_photos(id) ON DELETE CASCADE"
            ~ ");"
            ~ "CREATE INDEX IF NOT EXISTS idx_face_fingerprints_hex ON face_fingerprints(fingerprint_hex);"
            ~ "CREATE INDEX IF NOT EXISTS idx_faces_person_name ON faces(person_name);"
            ~ "CREATE INDEX IF NOT EXISTS idx_faces_fingerprint_hex ON faces(fingerprint_hex);"
            ~ "CREATE INDEX IF NOT EXISTS idx_faces_source_path ON faces(source_path);"
            ~ "PRAGMA journal_mode=WAL;"
            ~ "PRAGMA synchronous=NORMAL;"))
    {
        return false;
    }
    return true;
}

private string faceDbPath(const string cacheRoot)
{
    return buildPath(cacheRoot, FACE_DB_NAME);
}

private bool ensureFaceSchema(const string dbPath)
{
    const schemaSql =
        "CREATE TABLE IF NOT EXISTS face_photos ("
        ~ "id INTEGER PRIMARY KEY AUTOINCREMENT,"
        ~ "source_path TEXT NOT NULL UNIQUE,"
        ~ "source_mtime_ms INTEGER NOT NULL,"
        ~ "analyzed_at_ms INTEGER NOT NULL"
        ~ ");"
        ~ "CREATE TABLE IF NOT EXISTS face_fingerprints ("
        ~ "id INTEGER PRIMARY KEY AUTOINCREMENT,"
        ~ "fingerprint_hex TEXT NOT NULL UNIQUE,"
        ~ "person_name TEXT"
        ~ ");"
        ~ "CREATE TABLE IF NOT EXISTS faces ("
        ~ "id INTEGER PRIMARY KEY AUTOINCREMENT,"
        ~ "photo_id INTEGER NOT NULL,"
        ~ "source_path TEXT NOT NULL,"
        ~ "thumb_path TEXT NOT NULL,"
        ~ "x INTEGER NOT NULL,"
        ~ "y INTEGER NOT NULL,"
        ~ "w INTEGER NOT NULL,"
        ~ "h INTEGER NOT NULL,"
        ~ "image_width INTEGER NOT NULL,"
        ~ "image_height INTEGER NOT NULL,"
        ~ "fingerprint_hex TEXT NOT NULL,"
        ~ "person_name TEXT,"
        ~ "FOREIGN KEY(photo_id) REFERENCES face_photos(id) ON DELETE CASCADE"
        ~ ");"
        ~ "CREATE INDEX IF NOT EXISTS idx_face_fingerprints_hex ON face_fingerprints(fingerprint_hex);"
        ~ "CREATE INDEX IF NOT EXISTS idx_faces_person_name ON faces(person_name);"
        ~ "CREATE INDEX IF NOT EXISTS idx_faces_fingerprint_hex ON faces(fingerprint_hex);"
        ~ "CREATE INDEX IF NOT EXISTS idx_faces_source_path ON faces(source_path);"
        ~ "PRAGMA journal_mode=WAL;"
        ~ "PRAGMA synchronous=NORMAL;";

    return runSqlCommand(dbPath, schemaSql);
}

private FaceDetection[] detectFacesForImage(const string sourcePath, const long sourceMtimeMs)
{
    FaceDetection[] detections;

    const dimensions = dimensionsFromVips(sourcePath);
    const imageWidth = dimensions.width;
    const imageHeight = dimensions.height;
    if (imageWidth <= 1 || imageHeight <= 1)
    {
        return detections;
    }

    const minEdge = imageWidth < imageHeight ? imageWidth : imageHeight;
    const faceEdge = cast(int)((minEdge * 35) / 100);
    const boundedFaceEdge = faceEdge < 64 ? 64 : (faceEdge > minEdge ? minEdge : faceEdge);

    FaceDetection detection;
    detection.imageWidth = imageWidth;
    detection.imageHeight = imageHeight;
    detection.w = boundedFaceEdge;
    detection.h = boundedFaceEdge;
    detection.x = (imageWidth - detection.w) / 2;
    detection.y = (imageHeight - detection.h) / 2;
    detection.fingerprintHex = toHexString(
        sha1Of(
            sourcePath
            ~ "|"
            ~ to!string(
            sourceMtimeMs)
            ~ "|"
            ~ to!string(imageWidth)
            ~ "|"
            ~ to!string(
            imageHeight)
            ~ "|"
            ~ to!string(detection.x)
            ~ "|"
            ~ to!string(
            detection.y)
            ~ "|"
            ~ to!string(detection.w)
            ~ "|"
            ~ to!string(detection.h)
    )
    ).idup;

    detections ~= detection;

    return detections;
}

private bool syncFacesForImage(
    sqlite3* db,
    const string sourcePath,
    const string thumbPath,
    const long mtimeMs
)
{
    const escapedSourcePath = sqlEscape(sourcePath);
    const existingMtime = querySqlOutputDb(
        db,
        "SELECT source_mtime_ms FROM face_photos WHERE source_path='" ~ escapedSourcePath ~ "' LIMIT 1;"
    ).strip();
    if (existingMtime.length > 0 && existingMtime == to!string(mtimeMs))
    {
        return true;
    }

    const detections = detectFacesForImage(sourcePath, mtimeMs);

    const upsertPhotoSql =
        "INSERT INTO face_photos (source_path, source_mtime_ms, analyzed_at_ms) VALUES ('"
        ~ escapedSourcePath
        ~ "',"
        ~ to!string(
            mtimeMs)
        ~ ","
        ~ to!string(cast(long) Clock.currTime().toUnixTime() * 1_000)
        ~ ") ON CONFLICT(source_path) DO UPDATE SET source_mtime_ms=excluded.source_mtime_ms,"
        ~ "analyzed_at_ms=excluded.analyzed_at_ms;";
    if (!runSqlCommandDb(db, upsertPhotoSql))
    {
        return false;
    }

    const photoIdText = querySqlOutputDb(
        db,
        "SELECT id FROM face_photos WHERE source_path='" ~ escapedSourcePath ~ "' LIMIT 1;"
    ).strip();
    if (photoIdText.length == 0)
    {
        return false;
    }

    runSqlCommandDb(db, "DELETE FROM faces WHERE source_path='" ~ escapedSourcePath ~ "';");

    foreach (detection; detections)
    {
        runSqlCommandDb(
            db,
            "INSERT OR IGNORE INTO face_fingerprints (fingerprint_hex) VALUES ('"
                ~ sqlEscape(
                    detection.fingerprintHex)
                ~ "');"
        );

        runSqlCommandDb(
            db,
            "INSERT INTO faces ("
                ~ "photo_id, source_path, thumb_path, x, y, w, h, image_width, image_height, fingerprint_hex"
                ~ ") VALUES ("
                ~ photoIdText
                ~ ",'"
                ~ escapedSourcePath
                ~ "','"
                ~ sqlEscape(
                    thumbPath)
                ~ "',"
                ~ to!string(detection.x)
                ~ ","
                ~ to!string(
                    detection.y)
                ~ ","
                ~ to!string(detection.w)
                ~ ","
                ~ to!string(
                    detection.h)
                ~ ","
                ~ to!string(detection.imageWidth > 0 ? detection.imageWidth : 1)
                ~ ","
                ~ to!string(
                    detection.imageHeight > 0 ? detection.imageHeight
                    : 1)
                ~ ",'"
                ~ sqlEscape(detection.fingerprintHex)
                ~ "');"
        );
    }

    return true;
}

private void scanLibraryFaces(const string rootPath)
{
    if (!exists(rootPath) || !isDir(rootPath))
    {
        return;
    }

    const cacheRoot = defaultCacheRoot();
    const dbPath = faceDbPath(cacheRoot);
    auto db = openSqliteDb(dbPath);
    if (db is null)
    {
        return;
    }
    scope (exit)
        sqlite3_close(db);

    if (!ensureFaceSchemaDb(db))
    {
        return;
    }

    runSqlCommandDb(db, "BEGIN TRANSACTION;");

    size_t scannedImages = 0;
    size_t batchCount = 0;
    foreach (entry; dirEntries(rootPath, SpanMode.depth, true))
    {
        if (!entry.isFile)
        {
            continue;
        }

        const sourcePath = entry.name;
        if (!isImageFile(sourcePath))
        {
            continue;
        }

        const mtimeMs = fileModifiedMs(sourcePath);
        const key = thumbnailKey(sourcePath, cast(long) entry.size, mtimeMs);
        const thumbPath = ensureDerivedImage(sourcePath, cacheRoot, key, "thumb", 512, 82);
        syncFacesForImage(
            db,
            sourcePath,
            thumbPath.length == 0 ? sourcePath : thumbPath,
            mtimeMs
        );

        scannedImages++;
        batchCount++;
        if (batchCount >= 50)
        {
            runSqlCommandDb(db, "COMMIT;");
            runSqlCommandDb(db, "BEGIN TRANSACTION;");
            batchCount = 0;
        }

        if (scannedImages >= MAX_FACE_SCAN_IMAGES)
        {
            break;
        }
    }

    runSqlCommandDb(db, "COMMIT;");
}

private FaceRecord[] listUnnamedFacesFromDb()
{
    FaceRecord[] rows;

    const dbPath = faceDbPath(defaultCacheRoot());
    if (!exists(dbPath) || !ensureFaceSchema(dbPath))
    {
        return rows;
    }

    const querySql =
        "SELECT id, source_path, thumb_path, x, y, w, h, image_width, image_height, "
        ~ "COALESCE(person_name, ''), fingerprint_hex "
        ~ "FROM faces "
        ~ "WHERE person_name IS NULL OR TRIM(person_name) = '' "
        ~ "ORDER BY id DESC LIMIT "
        ~ to!string(MAX_FACE_MATCHES)
        ~ ";";

    const output = querySqlOutput(dbPath, querySql);
    foreach (line; output.splitLines())
    {
        const trimmed = line.strip();
        if (trimmed.length == 0)
        {
            continue;
        }

        auto columns = trimmed.split("\t");
        if (columns.length < 11)
        {
            continue;
        }

        FaceRecord row;
        try
        {
            row.id = columns[0].to!long;
            row.sourcePath = columns[1].idup;
            row.thumbPath = columns[2].idup;
            row.x = columns[3].to!int;
            row.y = columns[4].to!int;
            row.w = columns[5].to!int;
            row.h = columns[6].to!int;
            row.imageWidth = columns[7].to!int;
            row.imageHeight = columns[8].to!int;
            row.personName = columns[9].idup;
            row.fingerprintHex = columns[10].idup;
        }
        catch (Exception)
        {
            continue;
        }

        rows ~= row;
    }

    return rows;
}

private string unnamedFacesJson()
{
    const rows = listUnnamedFacesFromDb();
    auto builder = appender!string();
    builder.put("{\"faces\":[");

    bool first = true;
    foreach (row; rows)
    {
        if (!first)
        {
            builder.put(",");
        }
        builder.put("{");
        builder.put("\"faceId\":");
        builder.put(to!string(row.id));
        builder.put(",\"sourceUrl\":\"");
        builder.put(jsonEscape(toFileUrl(row.sourcePath)));
        builder.put("\",");
        builder.put("\"thumbUrl\":\"");
        builder.put(jsonEscape(toFileUrl(row.thumbPath)));
        builder.put("\",");
        builder.put("\"x\":");
        builder.put(to!string(row.x));
        builder.put(",\"y\":");
        builder.put(to!string(row.y));
        builder.put(",\"w\":");
        builder.put(to!string(row.w));
        builder.put(",\"h\":");
        builder.put(to!string(row.h));
        builder.put(",\"imageWidth\":");
        builder.put(to!string(row.imageWidth > 0 ? row.imageWidth : 1));
        builder.put(",\"imageHeight\":");
        builder.put(to!string(row.imageHeight > 0 ? row.imageHeight : 1));
        builder.put(",\"personName\":\"");
        builder.put(jsonEscape(row.personName));
        builder.put("\",");
        builder.put("\"fingerprint\":\"");
        builder.put(jsonEscape(row.fingerprintHex));
        builder.put("\"");
        builder.put("}");
        first = false;
    }

    builder.put("]}");
    return builder.data;
}

private bool setFaceNameInDb(const long faceId, const string name)
{
    const dbPath = faceDbPath(defaultCacheRoot());
    auto db = openSqliteDb(dbPath);
    if (db is null)
    {
        return false;
    }
    scope (exit)
        sqlite3_close(db);

    if (!ensureFaceSchemaDb(db))
    {
        return false;
    }

    const fingerprintHex = querySqlOutputDb(
        db,
        "SELECT fingerprint_hex FROM faces WHERE id=" ~ to!string(faceId) ~ " LIMIT 1;"
    ).strip();
    if (fingerprintHex.length == 0)
    {
        return false;
    }

    const escapedHex = sqlEscape(fingerprintHex);
    const escapedName = sqlEscape(name);
    const updateFingerprintSql =
        "UPDATE face_fingerprints SET person_name='"
        ~ escapedName
        ~ "' WHERE fingerprint_hex='"
        ~ escapedHex
        ~ "';";
    const updateFacesSql =
        "UPDATE faces SET person_name='"
        ~ escapedName
        ~ "' WHERE fingerprint_hex='"
        ~ escapedHex
        ~ "';";

    return runSqlCommandDb(db, updateFingerprintSql) && runSqlCommandDb(db, updateFacesSql);
}

private bool setFingerprintNameInDb(const long fingerprintId, const string name)
{
    const dbPath = faceDbPath(defaultCacheRoot());
    auto db = openSqliteDb(dbPath);
    if (db is null)
    {
        return false;
    }
    scope (exit)
        sqlite3_close(db);

    if (!ensureFaceSchemaDb(db))
    {
        return false;
    }

    const escapedName = sqlEscape(name);
    const updateFingerprintSql =
        "UPDATE face_fingerprints SET person_name='"
        ~ escapedName
        ~ "' WHERE id="
        ~ to!string(fingerprintId)
        ~ ";";
    if (!runSqlCommandDb(db, updateFingerprintSql))
    {
        return false;
    }

    const updateFacesSql =
        "UPDATE faces SET person_name='"
        ~ escapedName
        ~ "' WHERE fingerprint_hex=(SELECT fingerprint_hex FROM face_fingerprints WHERE id="
        ~ to!string(fingerprintId)
        ~ " LIMIT 1);";
    return runSqlCommandDb(db, updateFacesSql);
}

private FingerprintRecord[] listFingerprintRecordsFromDb()
{
    FingerprintRecord[] rows;

    const dbPath = faceDbPath(defaultCacheRoot());
    if (!exists(dbPath) || !ensureFaceSchema(dbPath))
    {
        return rows;
    }

    const querySql =
        "SELECT fp.id, fp.fingerprint_hex, COALESCE(fp.person_name,''), "
        ~ "f.source_path, f.thumb_path, f.x, f.y, f.w, f.h, f.image_width, f.image_height, "
        ~ "(SELECT COUNT(*) FROM faces f2 WHERE f2.fingerprint_hex = fp.fingerprint_hex) "
        ~ "FROM face_fingerprints fp "
        ~ "JOIN faces f ON f.id = (SELECT MIN(id) FROM faces fs WHERE fs.fingerprint_hex = fp.fingerprint_hex) "
        ~ "ORDER BY fp.id DESC LIMIT "
        ~ to!string(MAX_FACE_MATCHES)
        ~ ";";

    const output = querySqlOutput(dbPath, querySql);
    foreach (line; output.splitLines())
    {
        const trimmed = line.strip();
        if (trimmed.length == 0)
        {
            continue;
        }

        auto columns = trimmed.split("\t");
        if (columns.length < 12)
        {
            continue;
        }

        FingerprintRecord row;
        try
        {
            row.fingerprintId = columns[0].to!long;
            row.fingerprintHex = columns[1].idup;
            row.personName = columns[2].idup;
            row.sourcePath = columns[3].idup;
            row.thumbPath = columns[4].idup;
            row.x = columns[5].to!int;
            row.y = columns[6].to!int;
            row.w = columns[7].to!int;
            row.h = columns[8].to!int;
            row.imageWidth = columns[9].to!int;
            row.imageHeight = columns[10].to!int;
            row.faceCount = columns[11].to!int;
        }
        catch (Exception)
        {
            continue;
        }

        rows ~= row;
    }

    return rows;
}

private string peopleFingerprintsJson()
{
    const rows = listFingerprintRecordsFromDb();
    auto builder = appender!string();
    builder.put("{\"fingerprints\":[");

    bool first = true;
    foreach (row; rows)
    {
        if (!first)
        {
            builder.put(",");
        }
        builder.put("{");
        builder.put("\"fingerprintId\":");
        builder.put(to!string(row.fingerprintId));
        builder.put(",\"personName\":\"");
        builder.put(jsonEscape(row.personName));
        builder.put("\",");
        builder.put("\"fingerprint\":\"");
        builder.put(jsonEscape(row.fingerprintHex));
        builder.put("\",");
        builder.put("\"sourceUrl\":\"");
        builder.put(jsonEscape(toFileUrl(row.sourcePath)));
        builder.put("\",");
        builder.put("\"thumbUrl\":\"");
        builder.put(jsonEscape(toFileUrl(row.thumbPath)));
        builder.put("\",");
        builder.put("\"x\":");
        builder.put(to!string(row.x));
        builder.put(",\"y\":");
        builder.put(to!string(row.y));
        builder.put(",\"w\":");
        builder.put(to!string(row.w));
        builder.put(",\"h\":");
        builder.put(to!string(row.h));
        builder.put(",\"imageWidth\":");
        builder.put(to!string(row.imageWidth > 0 ? row.imageWidth : 1));
        builder.put(",\"imageHeight\":");
        builder.put(to!string(row.imageHeight > 0 ? row.imageHeight : 1));
        builder.put(",\"faceCount\":");
        builder.put(to!string(row.faceCount));
        builder.put("}");
        first = false;
    }

    builder.put("]}");
    return builder.data;
}

private long sqlCountOrZero(const string dbPath, const string sql)
{
    const output = querySqlOutput(dbPath, sql).strip();
    if (output.length == 0)
    {
        return 0;
    }

    try
    {
        return output.to!long;
    }
    catch (Exception)
    {
        return 0;
    }
}

long photoWagonUnknownPeopleCount()
{
    const dbPath = faceDbPath(defaultCacheRoot());
    auto db = openSqliteDb(dbPath);
    if (db is null)
    {
        return 0;
    }
    scope (exit)
        sqlite3_close(db);

    return sqlCountOrZeroDb(
        db,
        "SELECT COUNT(*) FROM face_fingerprints WHERE person_name IS NULL OR TRIM(person_name) = '';"
    );
}

string photoWagonFaceDbStatusJson()
{
    const dbPath = faceDbPath(defaultCacheRoot());
    const dbExists = exists(dbPath);
    auto db = openSqliteDb(dbPath);
    const schemaReady = db !is null && ensureFaceSchemaDb(db);

    long faceCount = 0;
    long fingerprintCount = 0;
    long unknownPeopleCount = 0;
    long photoCount = 0;
    if (schemaReady)
    {
        faceCount = sqlCountOrZeroDb(db, "SELECT COUNT(*) FROM faces;");
        fingerprintCount = sqlCountOrZeroDb(db, "SELECT COUNT(*) FROM face_fingerprints;");
        unknownPeopleCount = sqlCountOrZeroDb(db, "SELECT COUNT(*) FROM face_fingerprints WHERE person_name IS NULL OR TRIM(person_name) = '';");
        photoCount = sqlCountOrZeroDb(db, "SELECT COUNT(*) FROM face_photos;");
    }
    if (db !is null)
    {
        sqlite3_close(db);
    }

    auto builder = appender!string();
    builder.put("{");
    builder.put("\"ok\":");
    builder.put(schemaReady ? "true" : "false");
    builder.put(",\"dbPath\":\"");
    builder.put(jsonEscape(dbPath));
    builder.put("\",\"dbExists\":");
    builder.put(dbExists ? "true" : "false");
    builder.put(",\"schemaReady\":");
    builder.put(schemaReady ? "true" : "false");
    builder.put(",\"faces\":");
    builder.put(to!string(faceCount));
    builder.put(",\"fingerprints\":");
    builder.put(to!string(fingerprintCount));
    builder.put(",\"unknownPeople\":");
    builder.put(to!string(unknownPeopleCount));
    builder.put(",\"photos\":");
    builder.put(to!string(photoCount));
    builder.put("}");
    return builder.data;
}

string photoWagonFaceStateJson()
{
    auto builder = appender!string();
    builder.put("{");
    builder.put("\"status\":");
    builder.put(photoWagonFaceDbStatusJson());
    builder.put(",\"unknownFaces\":");
    builder.put(unnamedFacesJson());
    builder.put(",\"people\":");
    builder.put(peopleFingerprintsJson());
    builder.put("}");
    return builder.data;
}

string photoWagonFaceScanAndListJson(const string rootPath)
{
    if (rootPath.length > 0)
    {
        scanLibraryFaces(rootPath);
    }
    return unnamedFacesJson();
}

string photoWagonFaceListJson()
{
    return unnamedFacesJson();
}

bool photoWagonFaceSetName(const long faceId, const string name)
{
    return setFaceNameInDb(faceId, name);
}

string photoWagonPeopleScanAndListJson(const string rootPath)
{
    if (rootPath.length > 0)
    {
        scanLibraryFaces(rootPath);
    }
    return peopleFingerprintsJson();
}

string photoWagonPeopleListJson()
{
    return peopleFingerprintsJson();
}

bool photoWagonFingerprintSetName(const long fingerprintId, const string name)
{
    return setFingerprintNameInDb(fingerprintId, name);
}

private string buildIndexJson(const string rootPath)
{
    if (!exists(rootPath) || !isDir(rootPath))
    {
        return "{\"sections\":[],\"flat\":[],\"dateTree\":[],\"count\":0}";
    }

    const cacheRoot = defaultCacheRoot();
    PhotoItem[] items;

    size_t metadataDateCount = 0;
    size_t fallbackDateCount = 0;

    size_t scannedEntries = 0;
    bool hitScanLimit = false;
    bool hitImageLimit = false;

    foreach (entry; dirEntries(rootPath, SpanMode.depth, true))
    {
        scannedEntries++;
        if (scannedEntries > MAX_SCANNED_ENTRIES)
        {
            hitScanLimit = true;
            break;
        }

        if (!entry.isFile)
        {
            continue;
        }

        const sourcePath = entry.name;
        if (!isImageFile(sourcePath))
        {
            continue;
        }

        const mtimeMs = fileModifiedMs(sourcePath);
        const key = thumbnailKey(sourcePath, cast(long) entry.size, mtimeMs);
        const thumbPath = ensureDerivedImage(sourcePath, cacheRoot, key, "thumb", 512, 82);
        const screenPath = ensureDerivedImage(sourcePath, cacheRoot, key, "screen", 1920, 88);

        auto metadata = readPhotoMetadata(sourcePath, mtimeMs);
        if (metadata.usedFallback)
        {
            fallbackDateCount++;
        }
        else
        {
            metadataDateCount++;
        }

        PhotoItem item;
        item.sourcePath = sourcePath;
        item.thumbPath = thumbPath.length == 0 ? sourcePath : thumbPath;
        item.screenPath = screenPath.length == 0 ? sourcePath : screenPath;
        const dimensions = dimensionsFromVips(sourcePath);
        item.sourceWidth = dimensions.width;
        item.sourceHeight = dimensions.height;
        item.dateTime = metadata.dateTime;
        item.monthTitle = humanizedMonthFrom(item.dateTime);
        item.subtitle = metadata.city.length == 0 ? item.monthTitle : metadata.city;
        items ~= item;

        if (items.length >= MAX_INDEXED_IMAGES)
        {
            hitImageLimit = true;
            break;
        }
    }

    items.sort!compareItems();

    int[int][int] yearMonthCounts;
    int[] years;

    auto builder = appender!string();
    builder.put("{");

    builder.put("\"sections\":[");
    string currentMonth;
    size_t flatIndex = 0;
    bool firstSection = true;
    bool sectionOpen = false;
    bool firstItemInSection = true;

    foreach (item; items)
    {
        const local = item.dateTime.toLocalTime();
        const year = cast(int) local.year;
        const month = cast(int) local.month;
        if (year !in yearMonthCounts)
        {
            yearMonthCounts[year] = null;
            years ~= year;
        }
        yearMonthCounts[year][month] = yearMonthCounts[year].get(month, 0) + 1;

        if (currentMonth != item.monthTitle)
        {
            if (sectionOpen)
            {
                builder.put("]}");
            }
            if (!firstSection)
            {
                builder.put(",");
            }
            builder.put("{\"title\":\"");
            builder.put(jsonEscape(item.monthTitle));
            builder.put("\",\"items\":[");
            currentMonth = item.monthTitle;
            firstSection = false;
            sectionOpen = true;
            firstItemInSection = true;
        }

        if (!firstItemInSection)
        {
            builder.put(",");
        }
        builder.put("{");
        builder.put("\"thumbUrl\":\"");
        builder.put(jsonEscape(toFileUrl(item.thumbPath)));
        builder.put("\",");
        builder.put("\"screenUrl\":\"");
        builder.put(jsonEscape(toFileUrl(item.screenPath)));
        builder.put("\",");
        builder.put("\"sourceUrl\":\"");
        builder.put(jsonEscape(toFileUrl(item.sourcePath)));
        builder.put("\",");
        builder.put("\"subtitle\":\"");
        builder.put(jsonEscape(item.subtitle));
        builder.put("\",");
        builder.put("\"sourceWidth\":");
        builder.put(to!string(item.sourceWidth > 0 ? item.sourceWidth : 1));
        builder.put(",");
        builder.put("\"sourceHeight\":");
        builder.put(to!string(item.sourceHeight > 0 ? item.sourceHeight : 1));
        builder.put(",");
        builder.put("\"flatIndex\":");
        builder.put(to!string(flatIndex));
        builder.put("}");
        firstItemInSection = false;
        flatIndex++;
    }

    if (sectionOpen)
    {
        builder.put("]}");
    }
    builder.put("],");

    builder.put("\"flat\":[");
    bool firstFlat = true;
    for (size_t index = 0; index < items.length; ++index)
    {
        const item = items[index];
        if (!firstFlat)
        {
            builder.put(",");
        }
        builder.put("{");
        builder.put("\"thumbUrl\":\"");
        builder.put(jsonEscape(toFileUrl(item.thumbPath)));
        builder.put("\",");
        builder.put("\"screenUrl\":\"");
        builder.put(jsonEscape(toFileUrl(item.screenPath)));
        builder.put("\",");
        builder.put("\"sourceUrl\":\"");
        builder.put(jsonEscape(toFileUrl(item.sourcePath)));
        builder.put("\",");
        builder.put("\"subtitle\":\"");
        builder.put(jsonEscape(item.subtitle));
        builder.put("\",");
        builder.put("\"sourceWidth\":");
        builder.put(to!string(item.sourceWidth > 0 ? item.sourceWidth : 1));
        builder.put(",");
        builder.put("\"sourceHeight\":");
        builder.put(to!string(item.sourceHeight > 0 ? item.sourceHeight : 1));
        builder.put(",");
        builder.put("\"flatIndex\":");
        builder.put(to!string(index));
        builder.put("}");
        firstFlat = false;
    }
    builder.put("],");

    years.sort!((a, b) => a > b);

    builder.put("\"dateTree\":[");
    bool firstYear = true;
    foreach (year; years)
    {
        if (!firstYear)
        {
            builder.put(",");
        }
        builder.put("{\"year\":");
        builder.put(to!string(year));
        builder.put(",\"months\":[");

        int[] months;
        foreach (month, _; yearMonthCounts[year])
        {
            months ~= month;
        }
        months.sort!((a, b) => a > b);

        bool firstMonth = true;
        foreach (month; months)
        {
            if (!firstMonth)
            {
                builder.put(",");
            }
            builder.put("{\"month\":\"");
            builder.put(monthName(month));
            builder.put("\",");
            builder.put("\"monthNum\":");
            builder.put(to!string(month));
            builder.put(",");
            builder.put("\"count\":");
            builder.put(to!string(yearMonthCounts[year][month]));
            builder.put("}");
            firstMonth = false;
        }

        builder.put("]}");
        firstYear = false;
    }
    builder.put("],");

    builder.put("\"count\":");
    builder.put(to!string(items.length));
    builder.put(",");
    builder.put("\"cacheRoot\":\"");
    builder.put(jsonEscape(cacheRoot));
    builder.put("\"");
    builder.put("}");

    const logMessage = format(
        "Photo scan/index: %s files, %s metadata dates, %s filesystem fallbacks " ~
            "cache: %s scanned: %s scanLimit: %s imageLimit: %s",
        items.length, metadataDateCount, fallbackDateCount, cacheRoot, scannedEntries, hitScanLimit, hitImageLimit
    );
    photo_wagon_log_from_d(toStringz(logMessage));

    return builder.data;
}

extern (C) const(char)* photo_wagon_index_json(const char* root_path)
{
    if (root_path is null)
    {
        const emptyJson = "{\"sections\":[],\"flat\":[],\"dateTree\":[],\"count\":0}";
        auto ptr = cast(char*) malloc(emptyJson.length + 1);
        if (ptr is null)
        {
            return null;
        }
        memcpy(ptr, emptyJson.ptr, emptyJson.length);
        ptr[emptyJson.length] = 0;
        return cast(const(char)*) ptr;
    }

    const rootPath = fromStringz(root_path).idup;
    const json = buildIndexJson(rootPath);

    auto ptr = cast(char*) malloc(json.length + 1);
    if (ptr is null)
    {
        return null;
    }

    memcpy(ptr, json.ptr, json.length);
    ptr[json.length] = 0;
    return cast(const(char)*) ptr;
}

extern (C) void photo_wagon_index_free(const char* json_ptr)
{
    if (json_ptr !is null)
    {
        free(cast(void*) json_ptr);
    }
}
