/// The phone grid's rows as a real QAbstractListModel, built in D: the day's photos laid
/// out as a mosaic the way Google Photos does (a big 2×2 tile beside small ones, a landscape
/// photo across the whole width, plain rows between), with a day header only while selecting
/// (the header carries "select the whole day"; otherwise a floating date pill tells the day). Every update is reconciled BY KEY against what the view
/// already shows — a row whose tiles changed is `dataChanged`, one that moved is moved, new
/// ones inserted, gone ones removed — so the delegates on screen survive and the scroll stays
/// where it is (the QML ListModel it replaces was rebuilt in JavaScript on every page, and Qt
/// says a ListModel is not for large data: https://doc.qt.io/qt-6/qtquick-performance.html).
module photowagon.ui.gridrows;

import qt.quick.qabstractlistmodel, qt.quick.qmodelindex, qt.quick.qvariant;
import qt.quick.qtvirt;   // the mixin resolves __QAbstractListModel_* here
import qtmoc;

import std.json;

enum : int
{
    KindRole = 257,   // Qt::UserRole + 1
    KeyRole,
    LabelRole,
    TilesRole,        // the row's tiles as a JSON array string (parsed once per delegate)
    SpanRole,         // the row's height in cells (a big tile or a wide photo spans 2)
}

struct GridRow
{
    string kind;      // "h" a day header, "r" a row of tiles
    string key;       // the day ("2026-9-21", "undated") or the day's row ("2026-9-21#8")
    string label;     // the header's text
    string tiles;     // JSON array of {pid, thumbUrl, sent, remote, video, duration, x, y, w, h}
                      // (x, y, w, h: the tile's place in the row, in cells)
    long firstPid;    // the row's first photo (anchoring a re-chunk), 0 for a header
    string[] pids;    // every photo of the row, as text (finding one)
    int span = 1;     // the row's height in cells
}

@QObject class GridRows
{
    mixin QtdWidget!QAbstractListModel;

    GridRow[] rows;
    int cols = 4;
    bool headers = false;   // day headers (while selecting)
    int mosaicMax = 4;      // the widest grid still laid out as a mosaic (phone 4, desktop 8)
    bool stacks = true;     // near-identical photos taken together as one tile
    private JSONValue[] lastItems;

    // ---- the model ----------------------------------------------------------------

    int rowCount(const(QModelIndex)* parent)
    {
        return parent.isValid() ? 0 : cast(int) rows.length;
    }

    QVariant data(const(QModelIndex)* idx, int role)
    {
        immutable i = idx.row();
        if (i < 0 || i >= rows.length)
            return QVariant.__make();
        auto r = &rows[i];
        switch (role)
        {
        case KindRole: return QVariant(r.kind);
        case KeyRole: return QVariant(r.key);
        case LabelRole: return QVariant(r.label);
        case TilesRole: return QVariant(r.tiles);
        case SpanRole: return QVariant(r.span);
        default: return QVariant.__make();
        }
    }

    ubyte[][int] roleNames()
    {
        return [
            KindRole: cast(ubyte[]) "kind".dup,
            KeyRole: cast(ubyte[]) "key".dup,
            LabelRole: cast(ubyte[]) "label".dup,
            TilesRole: cast(ubyte[]) "tiles".dup,
            SpanRole: cast(ubyte[]) "span".dup,
        ];
    }

    // ---- updates --------------------------------------------------------------------

    /// The listing changed (a page, a refresh, a thumbnail, a photo sent): reconcile.
    void update(JSONValue[] items)
    {
        lastItems = items;
        reconcile(build(items, cols, headers, mosaicMax, stacks));
    }

    /// Stacks on or off (Settings: "Stack similar photos").
    void setStacks(bool on)
    {
        if (on == stacks)
            return;
        stacks = on;
        reconcile(build(lastItems, cols, headers, mosaicMax, stacks));
    }

    /// The widest grid (in columns) still laid out as a mosaic; wider ones are plain.
    void setMosaicMax(int m)
    {
        if (m == mosaicMax)
            return;
        mosaicMax = m;
        reconcile(build(lastItems, cols, headers, mosaicMax, stacks));
    }

    /// Day headers on or off (the grid shows them while selecting).
    void setHeaders(bool on)
    {
        if (on == headers)
            return;
        headers = on;
        reconcile(build(lastItems, cols, headers, mosaicMax, stacks));
    }

    /// The column count changed (a pinch, a rotation): re-chunk the same photos.
    void setCols(int c)
    {
        if (c < 1 || c == cols)
            return;
        cols = c;
        reconcile(build(lastItems, cols, headers, mosaicMax, stacks));
    }

    /// The row holding photo `pid` (a re-chunk keeps it in view), or -1.
    int rowOf(long pid) const
    {
        import std.conv : to;
        import std.algorithm : canFind;

        immutable s = pid.to!string;
        foreach (i, ref r; rows)
            if (r.kind == "r" && r.pids.canFind(s))
                return cast(int) i;
        return -1;
    }

    /// Arrow-key navigation over the mosaic's geometry: from photo `pid`, the photo left
    /// (dir 0), right (1), above (2) or below (3); 0 when there is none. Left/right step to
    /// the neighbour in the same band, else to the previous/next photo in order; up/down to
    /// the nearest tile overlapping the same columns.
    long navigate(long pid, int dir) const
    {
        import std.math : abs;

        struct R { long pid; int x, y, w, h; int band; }
        R[] all;
        int top, band;
        foreach (ref r; rows)
        {
            if (r.kind != "r")
                continue;
            foreach (t; parseJSON(r.tiles).array)
                all ~= R(t["pid"].integer, cast(int) t["x"].integer, top + cast(int) t["y"].integer,
                    cast(int) t["w"].integer, cast(int) t["h"].integer, band);
            top += r.span;
            band++;
        }
        size_t at = size_t.max;
        foreach (i, ref t; all)
            if (t.pid == pid)
                at = i;
        if (at == size_t.max)
            return 0;
        immutable c = all[at];
        immutable cy = c.y * 2 + c.h, cx = c.x * 2 + c.w;   // centre, doubled (integers)
        long best;
        long bestScore = long.max;
        foreach (i, ref t; all)
        {
            if (i == at)
                continue;
            immutable ty = t.y * 2 + t.h, tx = t.x * 2 + t.w;
            immutable overlapsRows = t.y < c.y + c.h && c.y < t.y + t.h;
            immutable overlapsCols = t.x < c.x + c.w && c.x < t.x + t.w;
            long score = long.max;
            final switch (dir)
            {
            case 0: if (overlapsRows && t.x + t.w <= c.x) score = cx - tx; break;
            case 1: if (overlapsRows && t.x >= c.x + c.w) score = tx - cx; break;
            case 2: if (overlapsCols && t.y + t.h <= c.y) score = (cy - ty) * 64 + abs(tx - cx); break;
            case 3: if (overlapsCols && t.y >= c.y + c.h) score = (ty - cy) * 64 + abs(tx - cx); break;
            }
            if (score < bestScore)
            {
                bestScore = score;
                best = t.pid;
            }
        }
        // nothing further that way in this band: into the neighbouring band, reading order —
        // its bottom-right tile going left, its top-left going right (never another tile of
        // the same band, which could bounce between two tiles forever)
        if (best == 0 && (dir == 0 || dir == 1))
        {
            immutable want = dir == 0 ? c.band - 1 : c.band + 1;
            long key = dir == 0 ? long.min : long.max;
            foreach (ref t; all)
                if (t.band == want)
                {
                    immutable k = cast(long) t.y * 1024 + t.x;
                    if (dir == 0 ? k > key : k < key)
                    {
                        key = k;
                        best = t.pid;
                    }
                }
        }
        return best;
    }

    /// The key of row `i` ("" out of range): the scrubber's date.
    string keyAt(int i) const
    {
        return i >= 0 && i < rows.length ? rows[i].key : "";
    }

    private void reconcile(GridRow[] next)
    {
        // Keyed, in runs: a stretch of new rows goes in with one insert, a stretch of gone ones
        // out with one remove (row by row, the first 9000-photo listing copied the whole array
        // once per row, quadratic, on the Qt thread).
        bool[string] nextKeys, curKeys;
        foreach (ref r; next)
            nextKeys[r.kind ~ "|" ~ r.key] = true;
        foreach (ref r; rows)
            curKeys[r.kind ~ "|" ~ r.key] = true;
        size_t i;
        while (i < next.length)
        {
            auto e = next[i];
            immutable ek = e.kind ~ "|" ~ e.key;
            if (i < rows.length)
            {
                auto cur = rows[i];
                if (cur.key == e.key && cur.kind == e.kind)
                {
                    if (cur.tiles != e.tiles || cur.label != e.label || cur.span != e.span)
                        replace(i, e);
                    i++;
                    continue;
                }
                if ((cur.kind ~ "|" ~ cur.key) !in nextKeys)
                {
                    size_t j = i + 1;   // the whole stretch of gone rows
                    while (j < rows.length && (rows[j].kind ~ "|" ~ rows[j].key) !in nextKeys)
                        j++;
                    removeRange(i, j);
                    continue;
                }
                if (ek in curKeys)
                {
                    // further down: move it up (its delegate survives)
                    size_t j = i + 1;
                    while (j < rows.length && !(rows[j].key == e.key && rows[j].kind == e.kind))
                        j++;
                    if (j < rows.length)
                    {
                        moveUp(j, i);
                        if (rows[i].tiles != e.tiles || rows[i].label != e.label || rows[i].span != e.span)
                            replace(i, e);
                        i++;
                        continue;
                    }
                }
            }
            // new here: with the rows new after it, in one insert
            size_t j = i + 1;
            while (j < next.length && (next[j].kind ~ "|" ~ next[j].key) !in curKeys)
                j++;
            insertRange(i, next[i .. j]);
            i = j;
        }
        if (rows.length > next.length)
            removeRange(next.length, rows.length);
    }

    private void removeRange(size_t from, size_t to)
    {
        beginRemoveRows(QModelIndex.__make(), cast(int) from, cast(int) to - 1);
        rows = rows[0 .. from] ~ rows[to .. $];
        endRemoveRows();
    }

    private void insertRange(size_t at, GridRow[] block)
    {
        beginInsertRows(QModelIndex.__make(), cast(int) at, cast(int)(at + block.length) - 1);
        rows = rows[0 .. at] ~ block ~ rows[at .. $];
        endInsertRows();
    }

    private void replace(size_t i, GridRow e)
    {
        rows[i] = e;
        auto ix = createIndex(cast(int) i, 0);
        dataChanged(ix, ix, [KindRole, KeyRole, LabelRole, TilesRole, SpanRole]);
    }

    // row `from` (below) to position `to` (above): Qt's destination is the row it goes before
    private void moveUp(size_t from, size_t to)
    {
        beginMoveRows(QModelIndex.__make(), cast(int) from, cast(int) from, QModelIndex.__make(), cast(int) to);
        auto r = rows[from];
        rows = rows[0 .. to] ~ r ~ rows[to .. from] ~ rows[from + 1 .. $];
        endMoveRows();
    }
}

// ---- building the rows ----------------------------------------------------------------

private long num(JSONValue v, string k)
{
    if (v.type != JSONType.object)
        return 0;
    if (auto p = k in v.object)
    {
        if (p.type == JSONType.integer)
            return p.integer;
        if (p.type == JSONType.uinteger)
            return cast(long) p.uinteger;
        if (p.type == JSONType.float_)
            return cast(long) p.floating;
    }
    return 0;
}

private bool flag(JSONValue v, string k)
{
    return v.type == JSONType.object && k in v.object && v[k].type == JSONType.true_;
}

private string str(JSONValue v, string k)
{
    return v.type == JSONType.object && k in v.object && v[k].type == JSONType.string ? v[k].str : "";
}

/// taken_ts is Unix SECONDS; the day as the grid always keyed it: "Y-M-D" (unpadded), "undated".
string dayKey(long ts)
{
    import std.conv : to;

    if (!ts)
        return "undated";
    auto d = localDay(ts);
    return d.year.to!string ~ "-" ~ (cast(int) d.month).to!string ~ "-" ~ d.day.to!string;
}

private auto localDay(long ts)
{
    import std.datetime.systime : SysTime, unixTimeToStdTime;
    import std.datetime.timezone : LocalTime;

    return SysTime(unixTimeToStdTime(ts), LocalTime()).toLocalTime();
}

/// "Today", "Yesterday", "Mon, Sep 21" (the year when it is not this one), "Sem data".
string dayLabel(long ts)
{
    import std.conv : to;
    import std.datetime.systime : Clock;
    import std.datetime.date : Date;

    if (!ts)
        return "Sem data";
    auto t = localDay(ts);
    auto now = Clock.currTime();
    immutable that = Date(t.year, t.month, t.day), today = Date(now.year, now.month, now.day);
    immutable diff = (today - that).total!"days";
    if (diff == 0)
        return "Today";
    if (diff == 1)
        return "Yesterday";
    static immutable wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    static immutable mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    auto base = wd[cast(int) that.dayOfWeek] ~ ", " ~ mo[cast(int) that.month - 1] ~ " " ~ that.day.to!string;
    return that.year == today.year ? base : base ~ " " ~ that.year.to!string;
}

/// A photo's shape as shown: true when it is clearly wider than tall, the kind that reads
/// well across the whole grid. (width/height are stored as displayed: the indexer already
/// swapped them for EXIF orientations 5–8.)
private bool landscape(JSONValue it)
{
    immutable w = num(it, "width"), h = num(it, "height");
    return w > 0 && h > 0 && w * 10 >= h * 14;   // 1.4:1 or wider
}

/// Worth enlarging: Google Photos "auto-enlarges notable moments" and "prioritizes real-life
/// photos over screenshots" (support.google.com/photos/answer/14169846): a favourite always,
/// another real photo (not a screenshot, meme or document scan) on a stable pick, never the rest.
private bool highlight(JSONValue it, uint p, uint every)
{
    immutable kind = str(it, "kind");
    if (kind.length && kind != "photo" && kind != "video")
        return false;
    if (flag(it, "favorite"))
        return true;
    return p % every == 0;
}

/// A stable pick per photo (the layout must not reshuffle when a page grows): a small mix of
/// the id's bits.
private uint pick(long id)
{
    ulong x = cast(ulong) id * 0x9E3779B97F4A7C15UL;
    return cast(uint)(x >> 33);
}

/// items -> rows. A mosaic when there are 3 to `mosaicMax` columns (on the phone 3 or 4,
/// the Google Photos zoom levels that have one): a big 2×2 tile beside 2×(cols−2) small ones, the big one left or
/// right in turn; a landscape photo across the whole width, two cells tall (only up to 4
/// columns: wider, it would be a banner); plain rows of `cols` between. Denser or sparser
/// (2) grids stay plain. `headers`: a header row
/// before each day, whose rows then end with it; without headers the mosaic runs on across
/// days, as Google Photos' does (no half-empty last row per day), each row labelled with
/// the day of its first photo.
GridRow[] build(JSONValue[] items, int cols, bool headers = false, int mosaicMax = 4, bool stacks = true)
{
    import std.conv : to;

    GridRow[] out_;
    if (cols < 1)
        cols = 1;
    immutable mosaic = cols >= 3 && cols <= mosaicMax;
    size_t i;
    while (i < items.length)
    {
        immutable ts = num(items[i], "takenTs");
        immutable dayOfSegment = dayKey(ts);
        // a header's `tiles` carries {count}: how many photos that day
        immutable headerAt = out_.length;
        if (headers)
            out_ ~= GridRow("h", dayOfSegment, dayLabel(ts), "[]", 0, null);
        JSONValue[] day;   // the segment: one day with headers, everything without
        long[][] members;  // per entry of `day`: the photos it stands for (a stack: all of them)
        while (i < items.length && (!headers || dayKey(num(items[i], "takenTs")) == dayOfSegment))
        {
            // a stack: the photos in a row that share one show as its first (the newest)
            immutable st = stacks ? num(items[i], "stack") : 0;
            if (st && day.length && num(day[$ - 1], "stack") == st)
                members[$ - 1] ~= num(items[i], "id");
            else
            {
                day ~= items[i];
                members ~= [num(items[i], "id")];
            }
            i++;
        }
        if (headers)
        {
            size_t n;
            foreach (ref m; members)
                n += m.length;
            out_[headerAt].tiles = `{"count":` ~ n.to!string ~ `}`;
        }

        size_t[long] entryOf;   // photo id → its index in `day` (its members)
        foreach (k, ref d; day)
            entryOf[num(d, "id")] = k;
        JSONValue tile(JSONValue it, int x, int y, int w, int h)
        {
            JSONValue t = JSONValue.emptyObject;
            if (auto k = num(it, "id") in entryOf)
                if (members[*k].length > 1)
                {
                    t["stack"] = cast(long) members[*k].length;
                    t["stackId"] = num(it, "stack");
                    t["members"] = JSONValue(members[*k]);
                }
            t["pid"] = num(it, "id");
            t["thumbUrl"] = str(it, "thumbUrl");
            t["sent"] = flag(it, "sent");
            t["remote"] = flag(it, "remote");
            t["video"] = flag(it, "video");
            t["duration"] = num(it, "duration");
            // what the desktop cell shows or acts on (its heart, the hover words, the file)
            t["favorite"] = flag(it, "favorite");
            foreach (k; ["scene", "holiday", "weather", "path"])
                if (str(it, k).length)
                    t[k] = str(it, k);
            t["x"] = x;
            t["y"] = y;
            t["w"] = w;
            t["h"] = h;
            return t;
        }
        void emit(JSONValue[] tiles, JSONValue[] src, int span, string shape)
        {
            string[] pids;   // every photo it stands for, stacked ones too (finding one)
            foreach (it; src)
                if (auto k = num(it, "id") in entryOf)
                    foreach (m; members[*k])
                        pids ~= m.to!string;
            immutable first = num(src[0], "id");
            immutable firstTs = num(src[0], "takenTs");
            // keyed by its day, first photo and shape: a row keeps its delegate while photos
            // are added elsewhere
            out_ ~= GridRow("r", dayKey(firstTs) ~ "#" ~ first.to!string ~ shape, dayLabel(firstTs),
                JSONValue(tiles).toString(), first, pids, span);
        }

        immutable bigCount = 1 + 2 * (cols - 2);
        bool bigLeft = true;
        size_t j;
        while (j < day.length)
        {
            immutable rest = day.length - j;
            immutable p = pick(num(day[j], "id"));
            if (mosaic && rest >= bigCount && highlight(day[j], p, 4))
            {
                // the big tile, then the small ones in two rows beside it
                JSONValue[] tiles;
                auto src = day[j .. j + bigCount];
                immutable bx = bigLeft ? 0 : cols - 2;
                tiles ~= tile(src[0], bx, 0, 2, 2);
                int k = 1;
                foreach (y; 0 .. 2)
                    foreach (c; 0 .. cols)
                        if (c < bx || c >= bx + 2)
                            tiles ~= tile(src[k++], c, y, 1, 1);
                emit(tiles, src, 2, bigLeft ? "L" : "R");
                bigLeft = !bigLeft;
                j += bigCount;
                continue;
            }
            if (mosaic && cols <= 4 && landscape(day[j]) && highlight(day[j], p, 3))
            {
                emit([tile(day[j], 0, 0, cols, 2)], day[j .. j + 1], 2, "W");
                j += 1;
                continue;
            }
            immutable end = j + cols < day.length ? j + cols : day.length;
            JSONValue[] tiles;
            foreach (n, it; day[j .. end])
                tiles ~= tile(it, cast(int) n, 0, 1, 1);
            emit(tiles, day[j .. end], 1, "");
            j = end;
        }
    }
    return out_;
}

unittest
{
    JSONValue[] items;
    foreach (id; [5, 4, 3])
        items ~= parseJSON(`{"id":` ~ (cast(char)('0' + id)) ~ `,"takenTs":1700000000,"thumbUrl":"u"}`);
    items ~= parseJSON(`{"id":2,"takenTs":0}`);
    // a screenshot is never enlarged, a favourite photo always is (3 columns)
    {
        JSONValue[] its;
        foreach (id; 1 .. 8)
            its ~= parseJSON(`{"id":` ~ (cast(char)('0' + id)) ~ `,"takenTs":1700000000,"kind":"screenshot"}`);
        foreach (r; build(its, 3))
            assert(r.span == 1);
        its[0] = parseJSON(`{"id":1,"takenTs":1700000000,"kind":"photo","favorite":true}`);
        assert(build(its, 3)[0].span == 2);
    }
    // a stack: three photos sharing one show as one tile standing for all three
    {
        JSONValue[] its;
        foreach (id; [9, 8, 7, 6])
            its ~= parseJSON(`{"id":` ~ (cast(char)('0' + id)) ~ `,"takenTs":1700000000`
                ~ (id >= 7 ? `,"stack":7` : ``) ~ `}`);
        auto r = build(its, 3);
        auto t = parseJSON(r[0].tiles).array;
        assert(t.length == 2 && t[0]["stack"].integer == 3 && t[0]["members"].array.length == 3);
        assert(r[0].pids.length == 4);
        assert(parseJSON(build(its, 3, false, 4, false)[0].tiles).array.length == 3);   // stacks off
    }
    // headers on, 2 columns (plain): header, 2 rows of the day, header undated, 1 row
    auto rows = build(items, 2, true);
    assert(rows.length == 5);
    assert(rows[0].kind == "h" && rows[1].kind == "r" && rows[1].firstPid == 5 && rows[2].firstPid == 3);
    assert(rows[3].key == "undated" && rows[3].label == "Sem data");
    assert(parseJSON(rows[0].tiles)["count"].integer == 3);
    // no headers: rows only, running on across the days (4 photos, 2 columns: 2 rows)
    assert(build(items, 2).length == 2);
}

unittest
{
    import std.conv : to;
    import std.algorithm : map, sum;

    // a mosaic day: every photo placed once, cells never overlap, rows fill the width
    JSONValue[] items;
    foreach (id; 1 .. 200)
        items ~= parseJSON(`{"id":` ~ id.to!string ~ `,"takenTs":1700000000,"width":4000,"height":`
            ~ (id % 2 ? "3000" : "2250") ~ `}`);
    foreach (cols; [3, 4, 6, 8])
    {
        auto rows = build(items, cols, false, 8);
        size_t placed;
        bool big, wide;
        foreach (r; rows)
        {
            auto tiles = parseJSON(r.tiles).array;
            placed += tiles.length;
            bool[int] used;
            foreach (t; tiles)
            {
                immutable w = t["w"].integer, h = t["h"].integer;
                big |= w == 2 && h == 2;
                wide |= w == cols;
                foreach (y; 0 .. h)
                    foreach (x; 0 .. w)
                    {
                        immutable c = cast(int)((t["y"].integer + y) * cols + t["x"].integer + x);
                        assert(c !in used);
                        used[c] = true;
                        assert(t["y"].integer + y < r.span && t["x"].integer + x < cols);
                    }
            }
        }
        assert(placed == items.length);
        assert(big && (wide || cols > 4));
    }
}
