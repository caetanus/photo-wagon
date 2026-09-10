/// The years → months → days tree the sidebar shows.
module photowagon.core.library.dates;

import std.json;

import photowagon.core.db.sqlite : Database;
import photowagon.core.library.calendar : dateRange, fileUrl;
import photowagon.core.library.photos : Filter, PhotoRepo;
import photowagon.core.store.store : ContentStore;

final class DateTree
{
	private Database db;
	private ContentStore store;

	this(Database db, ContentStore store = null)
	{
		this.db = db;
		this.store = store;
	}

	/// Thumbnail URL of the newest photo in [from, to) matching the filter, or null.
	private JSONValue cover(long from, long to, Filter f)
	{
		if (store is null)
			return JSONValue(null);
		auto w = PhotoRepo.whereClause(f);
		auto s = db.prepare("SELECT p.thumb_hash FROM photos p" ~ w.joins ~ w.where
				~ " AND p.taken_ts >= ? AND p.taken_ts < ? AND p.thumb_hash IS NOT NULL ORDER BY p.taken_ts DESC, p.id DESC LIMIT 1");
		immutable n = w.bind(s);
		s.bind(n + 1, from).bind(n + 2, to);
		if (!s.step())
			return JSONValue(null);
		return JSONValue(fileUrl(store.pathFor(s.getString(0))));
	}

	/// The tree of one root (0 = the whole library).
	JSONValue build(long rootId = 0)
	{
		Filter f;
		f.rootId = rootId;
		return build(f);
	}

	/// `{years: [{year, count, cover, months: [{month, count, cover, days: [{day, count}]}]}]}`, newest first,
	/// over the photos matching the filter (its own date fields are ignored: the tree is what to pick from).
	JSONValue build(Filter f)
	{
		import std.conv : to;

		f.year = f.month = f.day = 0;
		auto w = PhotoRepo.whereClause(f);
		auto s = db.prepare("SELECT strftime('%Y-%m-%d', p.taken_ts, 'unixepoch', 'localtime') AS d, count(*) FROM photos p"
				~ w.joins ~ w.where ~ " GROUP BY d ORDER BY d DESC");
		w.bind(s);

		JSONValue[] years;
		JSONValue* year;
		JSONValue* month;
		int curYear = -1, curMonth = -1;
		while (s.step())
		{
			immutable d = s.getString(0);
			immutable n = s.getLong(1);
			if (d is null || d.length < 10)
				continue;
			immutable y = d[0 .. 4].to!int;
			immutable m = d[5 .. 7].to!int;
			immutable dd = d[8 .. 10].to!int;
			if (y != curYear)
			{
				years ~= JSONValue(["year": JSONValue(y), "count": JSONValue(0), "months": JSONValue(cast(JSONValue[]) [])]);
				year = &years[$ - 1];
				curYear = y;
				curMonth = -1;
			}
			if (m != curMonth)
			{
				(*year)["months"].array ~= JSONValue(["month": JSONValue(m), "count": JSONValue(0), "days": JSONValue(cast(JSONValue[]) [])]);
				month = &(*year)["months"].array[$ - 1];
				curMonth = m;
			}
			(*month)["days"].array ~= JSONValue(["day": JSONValue(dd), "count": JSONValue(n)]);
			(*month)["count"] = JSONValue((*month)["count"].integer + n);
			(*year)["count"] = JSONValue((*year)["count"].integer + n);
		}
		foreach (ref y; years)
		{
			immutable yr = cast(int) y["year"].integer;
			auto yrange = dateRange(yr, 0, 0);
			y["cover"] = cover(yrange[0], yrange[1], f);
			foreach (ref m; y["months"].array)
			{
				auto mrange = dateRange(yr, cast(int) m["month"].integer, 0);
				m["cover"] = cover(mrange[0], mrange[1], f);
			}
		}
		return JSONValue(["years": JSONValue(years)]);
	}
}

unittest
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	// two photos on the same local day, one a year later
	import std.datetime : SysTime, DateTime, LocalTime;

	immutable t1 = SysTime(DateTime(2024, 3, 10, 12, 0, 0), LocalTime()).toUnixTime;
	immutable t2 = SysTime(DateTime(2025, 1, 1, 12, 0, 0), LocalTime()).toUnixTime;
	foreach (i, ts; [t1, t1 + 60, t2])
	{
		import std.conv : to;

		db.exec("INSERT INTO photos (hash, taken_ts, taken_at) VALUES ('h" ~ i.to!string ~ "', " ~ ts.to!string ~ ", '')");
	}
	auto tree = new DateTree(db).build();
	auto years = tree["years"].array;
	assert(years.length == 2);
	assert(years[0]["year"].integer == 2025);
	assert(years[1]["count"].integer == 2);
	assert(years[1]["months"][0]["days"][0]["day"].integer == 10);
	// the tree follows the filter: only the favourite remains
	db.exec("UPDATE photos SET favorite = 1 WHERE hash = 'h2'");
	Filter fav = {favorites: true};
	auto favTree = new DateTree(db).build(fav);
	assert(favTree["years"].array.length == 1 && favTree["years"][0]["year"].integer == 2025);
}
