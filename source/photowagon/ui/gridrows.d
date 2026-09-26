/// The phone grid's rows as a real QAbstractListModel, built in D: a day header, then the
/// day's photos in rows of `cols`. Every update is reconciled BY KEY against what the view
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
}

struct GridRow
{
    string kind;      // "h" a day header, "r" a row of tiles
    string key;       // the day ("2026-9-21", "undated") or the day's row ("2026-9-21#8")
    string label;     // the header's text
    string tiles;     // JSON array of {pid, thumbUrl, sent, remote, video, duration}
    long firstPid;    // the row's first photo (anchoring a re-chunk), 0 for a header
    string[] pids;    // every photo of the row, as text (finding one)
}

@QObject class GridRows
{
    mixin QtdWidget!QAbstractListModel;

    GridRow[] rows;
    int cols = 4;
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
        ];
    }

    // ---- updates --------------------------------------------------------------------

    /// The listing changed (a page, a refresh, a thumbnail, a photo sent): reconcile.
    void update(JSONValue[] items)
    {
        lastItems = items;
        reconcile(build(items, cols));
    }

    /// The column count changed (a pinch, a rotation): re-chunk the same photos.
    void setCols(int c)
    {
        if (c < 1 || c == cols)
            return;
        cols = c;
        reconcile(build(lastItems, cols));
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

    /// The key of row `i` ("" out of range): the scrubber's date.
    string keyAt(int i) const
    {
        return i >= 0 && i < rows.length ? rows[i].key : "";
    }

    private void reconcile(GridRow[] next)
    {
        bool[string] keys;
        foreach (ref r; next)
            keys[r.kind ~ "|" ~ r.key] = true;
        size_t i;
        while (i < next.length)
        {
            auto e = next[i];
            if (i < rows.length)
            {
                auto cur = rows[i];
                if (cur.key == e.key && cur.kind == e.kind)
                {
                    if (cur.tiles != e.tiles || cur.label != e.label)
                        replace(i, e);
                    i++;
                    continue;
                }
                if ((cur.kind ~ "|" ~ cur.key) !in keys)
                {
                    removeAt(i);   // gone
                    continue;
                }
                // further down: move it up (its delegate survives)
                size_t j = i + 1;
                while (j < rows.length && !(rows[j].key == e.key && rows[j].kind == e.kind))
                    j++;
                if (j < rows.length)
                {
                    moveUp(j, i);
                    if (rows[i].tiles != e.tiles || rows[i].label != e.label)
                        replace(i, e);
                    i++;
                    continue;
                }
            }
            insertAt(i, e);   // new here
            i++;
        }
        if (rows.length > next.length)
        {
            beginRemoveRows(QModelIndex.__make(), cast(int) next.length, cast(int) rows.length - 1);
            rows = rows[0 .. next.length];
            endRemoveRows();
        }
    }

    private void replace(size_t i, GridRow e)
    {
        rows[i] = e;
        auto ix = createIndex(cast(int) i, 0);
        dataChanged(ix, ix, [KindRole, KeyRole, LabelRole, TilesRole]);
    }

    private void removeAt(size_t i)
    {
        beginRemoveRows(QModelIndex.__make(), cast(int) i, cast(int) i);
        rows = rows[0 .. i] ~ rows[i + 1 .. $];
        endRemoveRows();
    }

    private void insertAt(size_t i, GridRow e)
    {
        beginInsertRows(QModelIndex.__make(), cast(int) i, cast(int) i);
        rows = rows[0 .. i] ~ e ~ rows[i .. $];
        endInsertRows();
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

/// items -> [header, row, row, header, row …], chunked by `cols` (the grid's old buildRows).
GridRow[] build(JSONValue[] items, int cols)
{
    import std.conv : to;

    GridRow[] out_;
    if (cols < 1)
        cols = 1;
    size_t i;
    while (i < items.length)
    {
        immutable ts = num(items[i], "takenTs");
        immutable key = dayKey(ts);
        out_ ~= GridRow("h", key, dayLabel(ts), "[]", 0, null);
        JSONValue[] day;
        while (i < items.length && dayKey(num(items[i], "takenTs")) == key)
            day ~= items[i++];
        for (size_t j = 0; j < day.length; j += cols)
        {
            JSONValue[] tiles;
            string[] pids;
            immutable end = j + cols < day.length ? j + cols : day.length;
            foreach (it; day[j .. end])
            {
                JSONValue t = JSONValue.emptyObject;
                t["pid"] = num(it, "id");
                t["thumbUrl"] = str(it, "thumbUrl");
                t["sent"] = flag(it, "sent");
                t["remote"] = flag(it, "remote");
                t["video"] = flag(it, "video");
                t["duration"] = num(it, "duration");
                tiles ~= t;
                pids ~= num(it, "id").to!string;
            }
            out_ ~= GridRow("r", key ~ "#" ~ j.to!string, "", JSONValue(tiles).toString(),
                num(day[j], "id"), pids);
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
    auto rows = build(items, 2);
    assert(rows.length == 5);   // header, 2 rows of the day, header undated, 1 row
    assert(rows[0].kind == "h" && rows[1].kind == "r" && rows[1].firstPid == 5 && rows[2].firstPid == 3);
    assert(rows[3].key == "undated" && rows[3].label == "Sem data");
}
