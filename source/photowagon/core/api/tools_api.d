/// The desktop's Tools: clean-up work over the whole library, each a question the user
/// answers quickly instead of hunting photo by photo.
///   - similar photos: groups of near-identical photos (CLIP neighbours in sqlite-vec), the
///     best one first — the rest can go to the trash;
///   - thumbnails: the small copies (≤ 512 px) that have a larger near-identical photo — the
///     phone's thumbnail cache that a USB import brought along — plus the small images with
///     no larger copy, shown apart for the user to decide;
///   - unidentified faces: the unnamed face groups (largest first), then the loose faces,
///     one at a time, to be named, merged into a person or dismissed.
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
}
