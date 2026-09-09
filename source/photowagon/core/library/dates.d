/// The years → months → days tree the sidebar shows.
module photowagon.core.library.dates;

import std.json;

import photowagon.core.db.sqlite : Database;
import photowagon.core.library.calendar : dateRange, fileUrl;
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

	/// Thumbnail URL of the newest photo in [from, to), or null.
	private JSONValue cover(long from, long to, long rootId)
	{
		if (store is null)
			return JSONValue(null);
		auto s = db.prepare("SELECT thumb_hash FROM photos WHERE taken_ts >= ? AND taken_ts < ? AND thumb_hash IS NOT NULL"
				~ (rootId ? " AND root_id = ?" : "") ~ " ORDER BY taken_ts DESC, id DESC LIMIT 1");
		s.bind(1, from).bind(2, to);
		if (rootId)
			s.bind(3, rootId);
		if (!s.step())
			return JSONValue(null);
		return JSONValue(fileUrl(store.pathFor(s.getString(0))));
	}

	/// `{years: [{year, count, cover, months: [{month, count, cover, days: [{day, count}]}]}]}`, newest first.
	JSONValue build(long rootId = 0)
	{
		import std.conv : to;

		string sql = "SELECT strftime('%Y-%m-%d', taken_ts, 'unixepoch', 'localtime') AS d, count(*) FROM photos";
		if (rootId)
			sql ~= " WHERE root_id = ?";
		sql ~= " GROUP BY d ORDER BY d DESC";
		auto s = db.prepare(sql);
		if (rootId)
			s.bind(1, rootId);

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
			y["cover"] = cover(yrange[0], yrange[1], rootId);
			foreach (ref m; y["months"].array)
			{
				auto mrange = dateRange(yr, cast(int) m["month"].integer, 0);
				m["cover"] = cover(mrange[0], mrange[1], rootId);
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
}
