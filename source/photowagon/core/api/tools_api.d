/// The desktop's Tools: clean-up work over the whole library, each a question the user
/// answers quickly instead of hunting photo by photo.
///   - similar photos: groups of near-identical photos (CLIP neighbours in sqlite-vec), the
///     best one first — the rest can go to the trash;
///   - thumbnails: the small copies (≤ 512 px) that have a larger near-identical photo — the
///     phone's thumbnail cache that a USB import brought along — plus the small images with
///     no larger copy, shown apart for the user to decide;
///   - unidentified faces: the unnamed face groups (largest first), then the loose faces,
///     one at a time, to be named, merged into a person or dismissed;
///   - screenshots and memes: grouped by where they came from (the app a screenshot's file
///     name carries, WhatsApp) or else by month, so a whole group goes to the trash at once.
/// Deleting, naming and merging use the existing calls (photo.delete, people.*, face.*).
module photowagon.core.api.tools_api;

import std.json;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.protocol;
import photowagon.core.library.calendar : fileUrl;
import photowagon.core.library.photos : PhotoRepo, Photo;
import photowagon.core.library.scenes : SceneService;
import photowagon.core.store.store : ContentStore;
import libp2p.util.fibers : FiberGroup;

/// The small side of a thumbnail: a photo this size or smaller with a larger twin is a copy.
enum thumbMaxSide = 512;

private final class SimilarScan
{
    bool running;
    bool done;
    double minSimilarity = 0.95;
    long progress, total;
    long[][] groups;   // each: the photo ids of one group, best first
    string error;
}

/// `owner`: the daemon's fiber group — the background scan runs in it, so a shutdown
/// interrupts and joins it before the database it reads is closed.
void registerToolsApi(Registry r, Database db, PhotoRepo photos, SceneService scenes, ContentStore store,
    FiberGroup owner)
{
    auto scan = new SimilarScan;

    string url(string hash)
    {
        return hash is null || !hash.length ? null : fileUrl(store.pathFor(hash));
    }

    static long maxSide(ref const Photo p)
    {
        return p.width > p.height ? p.width : p.height;
    }

    // best first: the largest picture, then the largest file (the least compressed)
    long[] rank(long[] ids)
    {
        import std.algorithm : sort;

        Photo[] ps;
        foreach (id; ids)
            try
                ps ~= photos.get(id);
            catch (Exception)
            {
            }
        ps.sort!((a, b) => maxSide(a) != maxSide(b) ? maxSide(a) > maxSide(b) : a.size > b.size);
        long[] out_;
        foreach (ref p; ps)
            out_ ~= p.id;
        return out_;
    }

    void runScan(double minSim)
    {
        import vibe.core.core : yield;

        scan.running = true;
        scan.done = false;
        scan.error = null;
        scan.groups = null;
        scan.minSimilarity = minSim;
        scope (exit)
            scan.running = false;
        try
        {
            long[] ids;
            {
                auto s = db.prepare("SELECT photo_id FROM photo_vec");
                while (s.step())
                    ids ~= s.getLong(0);
            }
            scan.total = ids.length;
            scan.progress = 0;
            // union-find over the pairs at or above the threshold
            long[long] parent;
            long find(long x)
            {
                auto p = x in parent;
                if (p is null || *p == x)
                    return x;
                immutable root = find(*p);
                parent[x] = root;
                return root;
            }
            void unite(long a, long b)
            {
                immutable ra = find(a), rb = find(b);
                if (ra != rb)
                    parent[ra] = rb;
            }
            foreach (id; ids)
            {
                foreach (hit; scenes.similar(id, 8).array)
                    if (hit["similarity"].floating >= minSim)
                    {
                        immutable other = hit["id"].integer;
                        if (other !in parent)
                            parent[other] = other;
                        if (id !in parent)
                            parent[id] = id;
                        unite(id, other);
                    }
                scan.progress++;
                yield();   // one neighbour query per turn: the daemon keeps answering
            }
            long[][long] byRoot;
            foreach (id, _; parent)
                byRoot[find(id)] ~= id;
            foreach (_, members; byRoot)
                if (members.length > 1)
                    scan.groups ~= rank(members);
            import std.algorithm : sort;

            scan.groups.sort!((a, b) => a.length > b.length);
            scan.done = true;
        }
        catch (Exception e)
            scan.error = e.msg;
    }

    // {minSimilarity?} → {started}: (re)groups the library in the background
    r.add("tools.similar.start", (JSONValue p) {
        double minSim = 0.95;
        if (p.type == JSONType.object && "minSimilarity" in p)
            minSim = p["minSimilarity"].type == JSONType.float_ ? p["minSimilarity"].floating
                : cast(double) p["minSimilarity"].integer;
        if (minSim < 0.80 || minSim > 0.999)
            throw new ApiError("bad_params", "minSimilarity must be between 0.80 and 0.999");
        if (scan.running)
            return JSONValue(["started": JSONValue(false), "running": JSONValue(true)]);
        scan.running = true;   // (claimed now: a second start before the task runs is refused)
        owner.spawn({ runScan(minSim); });
        return JSONValue(["started": JSONValue(true)]);
    });

    JSONValue photoJson(long id)
    {
        try
        {
            auto ph = photos.get(id);
            auto j = photos.toJson(ph);
            j["maxSide"] = maxSide(ph);
            return j;
        }
        catch (Exception)
            return JSONValue(null);
    }

    // → {running, done, progress, total, minSimilarity, groups?: [{items: [photo…]}] (best first)}
    r.add("tools.similar.status", (JSONValue p) {
        JSONValue o = JSONValue.emptyObject;
        o["running"] = scan.running;
        o["done"] = scan.done;
        o["progress"] = scan.progress;
        o["total"] = scan.total;
        o["minSimilarity"] = scan.minSimilarity;
        if (scan.error.length)
            o["error"] = scan.error;
        if (scan.done)
        {
            JSONValue[] groups;
            foreach (g; scan.groups)
            {
                JSONValue[] items;
                foreach (id; g)
                {
                    auto j = photoJson(id);
                    if (j.type != JSONType.null_)
                        items ~= j;   // (one deleted since the scan drops out)
                }
                if (items.length > 1)
                    groups ~= JSONValue(["items": JSONValue(items)]);
            }
            o["groups"] = groups;
        }
        return o;
    });

    // → {scanned, redundant: [{photo, keep}], orphans: [photo]}: the small copies with a larger
    // near-identical photo (from the last similar-photos scan), and the small images without one
    r.add("tools.thumbnails", (JSONValue p) {
        import std.algorithm : canFind;

        JSONValue[] redundant, orphans;
        long[] covered;
        foreach (g; scan.groups)
        {
            JSONValue keep = JSONValue(null);
            foreach (id; g)
            {
                auto j = photoJson(id);
                if (j.type == JSONType.null_)
                    continue;
                if (keep.type == JSONType.null_)
                {
                    keep = j;   // the group's best
                    continue;
                }
                if (j["maxSide"].integer <= thumbMaxSide && keep["maxSide"].integer > thumbMaxSide)
                {
                    redundant ~= JSONValue(["photo": j, "keep": keep]);
                    covered ~= id;
                }
            }
        }
        // small images the scan did not pair with a larger one
        {
            auto s = db.prepare("SELECT id FROM photos WHERE path IS NOT NULL AND width > 0 AND height > 0 "
                ~ "AND max(width, height) <= ? ORDER BY taken_ts DESC LIMIT 5000");
            s.bind(1, cast(long) thumbMaxSide);
            while (s.step())
            {
                immutable id = s.getLong(0);
                if (covered.canFind(id))
                    continue;
                auto j = photoJson(id);
                if (j.type != JSONType.null_)
                    orphans ~= j;
            }
        }
        return JSONValue(["scanned": JSONValue(scan.done), "redundant": JSONValue(redundant), "orphans": JSONValue(orphans)]);
    });

    // {offset} → {total, clusters, loose, item?}: the unnamed face groups (largest first), then the
    // faces with no group; item = {type:"cluster", personId, count, faces:[{faceId, url, photoId}]}
    // or {type:"face", faceId, photoId, url, photoThumbUrl}
    r.add("tools.unidentified", (JSONValue p) {
        immutable offset = getLong(p, "offset", 0);
        long clusters, loose;
        {
            auto s = db.prepare("SELECT count(*) FROM persons pe WHERE (pe.name IS NULL OR pe.name = '') "
                ~ "AND EXISTS (SELECT 1 FROM faces f WHERE f.person_id = pe.id)");
            if (s.step())
                clusters = s.getLong(0);
        }
        {
            auto s = db.prepare("SELECT count(*) FROM faces WHERE person_id IS NULL");
            if (s.step())
                loose = s.getLong(0);
        }
        JSONValue o = JSONValue.emptyObject;
        o["clusters"] = clusters;
        o["loose"] = loose;
        o["total"] = clusters + loose;
        if (offset < clusters)
        {
            auto s = db.prepare("SELECT pe.id, count(f.id) AS n FROM persons pe JOIN faces f ON f.person_id = pe.id "
                ~ "WHERE pe.name IS NULL OR pe.name = '' GROUP BY pe.id ORDER BY n DESC, pe.id LIMIT 1 OFFSET ?");
            s.bind(1, offset);
            if (s.step())
            {
                immutable pid = s.getLong(0), n = s.getLong(1);
                JSONValue[] faces;
                auto fs = db.prepare("SELECT id, thumb_hash, photo_id FROM faces WHERE person_id = ? "
                    ~ "ORDER BY score DESC LIMIT 30");
                fs.bind(1, pid);
                while (fs.step())
                    faces ~= JSONValue(["faceId": JSONValue(fs.getLong(0)),
                        "url": JSONValue(url(fs.isNull(1) ? null : fs.getString(1))),
                        "photoId": JSONValue(fs.getLong(2))]);
                o["item"] = JSONValue(["type": JSONValue("cluster"), "personId": JSONValue(pid),
                    "count": JSONValue(n), "faces": JSONValue(faces)]);
            }
        }
        else if (offset - clusters < loose)
        {
            auto s = db.prepare("SELECT f.id, f.thumb_hash, f.photo_id, p.thumb_hash FROM faces f "
                ~ "JOIN photos p ON p.id = f.photo_id WHERE f.person_id IS NULL "
                ~ "ORDER BY f.score DESC, f.id LIMIT 1 OFFSET ?");
            s.bind(1, offset - clusters);
            if (s.step())
                o["item"] = JSONValue(["type": JSONValue("face"), "faceId": JSONValue(s.getLong(0)),
                    "url": JSONValue(url(s.isNull(1) ? null : s.getString(1))),
                    "photoId": JSONValue(s.getLong(2)),
                    "photoThumbUrl": JSONValue(url(s.isNull(3) ? null : s.getString(3)))]);
        }
        return o;
    });

    // {kind: "screenshot"|"meme"} → {kind, total, groups: [{key, label, source, items: [{id, thumbUrl,
    // takenTs, name, width, height}]}]}: the app groups first (largest first), then the months
    // (newest first); each group newest first
    r.add("tools.junk", (JSONValue p) {
        immutable kind = p.type == JSONType.object && "kind" in p && p["kind"].type == JSONType.string
            ? p["kind"].str : "";
        if (kind != "screenshot" && kind != "meme")
            throw new ApiError("bad_params", "kind must be screenshot or meme");
        JSONValue[][string] byKey;
        string[string] labelOf;
        bool[string] isApp;
        long total;
        {
            auto s = db.prepare("SELECT id, thumb_hash, taken_ts, path, width, height FROM photos "
                ~ "WHERE kind = ? AND path IS NOT NULL ORDER BY taken_ts DESC, id DESC");
            s.bind(1, kind);
            while (s.step())
            {
                immutable path = s.getString(3), ts = s.getLong(2);
                auto src = sourceOf(path);
                string key, label;
                if (src.length)
                {
                    key = "app:" ~ src;
                    label = src;
                }
                else
                {
                    key = "month:" ~ monthKey(ts);
                    label = monthLabel(ts);
                }
                JSONValue it = JSONValue.emptyObject;
                it["id"] = s.getLong(0);
                it["thumbUrl"] = url(s.isNull(1) ? null : s.getString(1));
                it["takenTs"] = ts;
                it["name"] = baseName(path);
                it["width"] = s.getLong(4);
                it["height"] = s.getLong(5);
                byKey[key] ~= it;
                labelOf[key] = label;
                isApp[key] = src.length > 0;
                total++;
            }
        }
        // an app with only a couple of screenshots is noise as a group of its own
        string[] small;
        foreach (k, items; byKey)
            if (isApp[k] && items.length < 3)
                small ~= k;
        foreach (k; small)
        {
            byKey["app:~other"] ~= byKey[k];
            labelOf["app:~other"] = "Other apps";
            isApp["app:~other"] = true;
            byKey.remove(k);
        }
        if (auto o = "app:~other" in byKey)
        {
            import std.algorithm : sort;

            (*o).sort!((a, b) => a["takenTs"].integer > b["takenTs"].integer);
        }
        import std.algorithm : sort;

        auto keys = byKey.keys;
        keys.sort!((a, b) {
            if (isApp[a] != isApp[b])
                return isApp[a];
            if (isApp[a])
                return byKey[a].length != byKey[b].length ? byKey[a].length > byKey[b].length : a < b;
            return a > b;   // "month:YYYY-MM": newest first ("month:0000-00", undated, last)
        });
        JSONValue[] groups;
        foreach (k; keys)
            groups ~= JSONValue(["key": JSONValue(k), "label": JSONValue(labelOf[k]),
                "source": JSONValue(isApp[k] ? "app" : "month"), "items": JSONValue(byKey[k])]);
        return JSONValue(["kind": JSONValue(kind), "total": JSONValue(total), "groups": JSONValue(groups)]);
    });
}

private string baseName(string path)
{
    import std.path : baseName;

    return baseName(path);
}

/// The app a file name says it came from, "" when it says none:
///   Screenshot_2020-06-18-19-29-52-502_com.nu.production.jpg → "Nubank"
///   Screenshot_20251204_162630_ChatGPT.jpg → "ChatGPT"
///   IMG-20200413-WA0018.jpg → "WhatsApp"
string sourceOf(string path)
{
    import std.path : baseName, stripExtension;
    import std.string : toLower, indexOf;
    import std.algorithm : startsWith, canFind;
    import std.array : split;
    import std.ascii : isDigit, isAlpha, toUpper;

    auto name = stripExtension(baseName(path));
    // WhatsApp's own names: IMG-YYYYMMDD-WAnnnn, VID-…, STK-…
    {
        auto wa = name.indexOf("-WA");
        if (wa > 0 && wa + 3 < name.length && isDigit(name[wa + 3]))
            return "WhatsApp";
    }
    if (!name.toLower.startsWith("screenshot"))
        return "";
    // the tail after the date/time digits and separators
    size_t i = "screenshot".length;
    // (a dot counts only between digits: "…_09.30" is still the time)
    // (and macOS's "Screenshot 2021-07-04 at 09.30.12": the "at" is part of the time)
    bool timeChar(size_t k)
    {
        immutable c = name[k];
        return isDigit(c) || c == '_' || c == '-' || c == ' '
            || (c == '.' && k + 1 < name.length && isDigit(name[k + 1]));
    }
    while (i < name.length)
    {
        if (timeChar(i))
            i++;
        else if (name[i .. $].startsWith("at ") && i > 0 && name[i - 1] == ' ')
            i += 3;
        else if (i > 0 && name[i - 1] == ' ' && (name[i .. $].toLower.startsWith("am")
                || name[i .. $].toLower.startsWith("pm")) && (i + 2 == name.length || !isAlpha(name[i + 2])))
            i += 2;   // "… 09.30.12 AM
        else
            break;
    }
    auto app = name[i .. $];

    if (!app.canFind!(c => isAlpha(c)))
        return "";   // no name in it, only more digits
    static immutable string[string] known = [
        "whatsapp": "WhatsApp", "chrome": "Chrome", "youtube": "YouTube", "googlequicksearchbox": "Google",
        "telegram": "Telegram", "instagram": "Instagram", "nu": "Nubank", "itau": "Itaú",
        "itaucard": "Itaú", "discord": "Discord", "firefox": "Firefox", "lockscreen": "Lock screen",
        "claude": "Claude", "chatgpt": "ChatGPT", "electrum": "Electrum", "slack": "Slack",
        "netflix": "Netflix", "twitter": "X", "x": "X", "maps": "Maps", "brave": "Brave",
        "photos": "Photos", "docs": "Docs", "wikipedia": "Wikipedia", "calculator": "Calculator",
        "home": "Home screen", "weather2": "Weather", "weather": "Weather",
    ];
    if (!app.canFind('.'))
    {
        if (auto k = app.toLower in known)
            return *k;
        return app;   // already a display name ("Tomb of the Mask")
    }
    // an Android package: its most telling segment
    static immutable noise = ["com", "org", "net", "br", "air", "st", "android", "google", "apps", "app",
        "production", "messenger", "mobile", "activity", "browser", "mediaclient", "miui", "lgeha"];
    string pick;
    foreach (seg; app.split('.'))
        if (!pick.length && seg.length && !noise.canFind(seg.toLower))
            pick = seg;
    if (!pick.length)
        pick = app.split('.')[$ - 1];
    if (auto k = pick.toLower in known)
        return *k;
    return pick.length ? toUpper(pick[0]) ~ pick[1 .. $] : "";
}

unittest
{
    assert(sourceOf("/x/Screenshot_2020-06-18-19-29-52-502_com.nu.production.jpg") == "Nubank");
    assert(sourceOf("/x/Screenshot_20251204_162630_ChatGPT.jpg") == "ChatGPT");
    assert(sourceOf("/x/Screenshot_2020-05-23-15-09-19-762_com.android.chrome.jpg") == "Chrome");
    assert(sourceOf("/x/Screenshot_2020-05-23-15-09-19-762_com.google.android.youtube.jpg") == "YouTube");
    assert(sourceOf("/x/Screenshot_2021-01-06-18-22-48-877_com.Slack.jpg") == "Slack");
    assert(sourceOf("/x/IMG-20200413-WA0018.jpg") == "WhatsApp");
    assert(sourceOf("/x/Screenshot_20240101_101010.png") == "");
    assert(sourceOf("/x/1000043009.jpg") == "");
    assert(sourceOf("/x/Screenshot_2021-07-04_09.30.jpg") == "");
    assert(sourceOf("/x/Screenshot 2021-07-04 at 09.30.12.png") == "");
    assert(sourceOf("/x/Screenshot 2021-07-04 at 09.30.12 AM.png") == "");
    assert(sourceOf("/x/Screenshot 2021-07-04 at 9.30.12 pm (2).png") == "");
    assert(sourceOf("/x/Screenshot_2020-01-01-10-10-10-111_air.com.RustyLake.CubeEscapeTheMill.jpg") == "RustyLake");
}

private string monthKey(long ts)
{
    import std.format : format;

    if (!ts)
        return "0000-00";
    auto t = localTime(ts);
    return format("%04d-%02d", t.year, cast(int) t.month);
}

private string monthLabel(long ts)
{
    import std.conv : to;

    if (!ts)
        return "No date";
    static immutable mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    auto t = localTime(ts);
    return mo[cast(int) t.month - 1] ~ " " ~ t.year.to!string;
}

private auto localTime(long ts)
{
    import std.datetime.systime : SysTime, unixTimeToStdTime;
    import std.datetime.timezone : LocalTime;

    return SysTime(unixTimeToStdTime(ts), LocalTime());
}
