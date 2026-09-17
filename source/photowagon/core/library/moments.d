/// Moments — the timeline grouped into events. A burst of photos taken close
/// together in time is one moment (a birthday, an outing, an afternoon at the
/// pool); a gap of a few hours starts the next. Each moment maps to a taken_ts
/// window (`Filter.tsFrom`/`tsTo`), so opening one reuses the same paged grid.
/// Computed on the fly from taken_ts — nothing stored.
module photowagon.core.library.moments;

import std.algorithm : sort;
import std.array : array;
import std.conv : to;
import std.json;

import photowagon.core.db.sqlite : Database;
import photowagon.core.library.calendar : fileUrl, localDate;
import photowagon.core.library.photos : Filter, PhotoRepo;
import photowagon.core.store.store : ContentStore;

private enum long gapSeconds = 6 * 3600;   // a gap longer than this starts a new moment
private enum long minPhotos = 6;           // below this a "moment" is not worth a card
private enum size_t maxMoments = 400;       // most-recent first; keep the payload sane

struct Moment
{
	long from;   // taken_ts of the first photo (inclusive)
	long to;     // taken_ts of the last photo (inclusive)
	long count;
	string place;
	string cover; // a representative thumbnail hash
}

final class MomentsService
{
	private Database db;
	private ContentStore store;
	private PhotoRepo photos;

	this(Database db, ContentStore store, PhotoRepo photos)
	{
		this.db = db;
		this.store = store;
		this.photos = photos;
	}

	private static immutable string[] months = [
		"", "January", "February", "March", "April", "May", "June",
		"July", "August", "September", "October", "November", "December"
	];

	/// `{moments: [{key, title, subtitle, cover, count}]}`, most recent first.
	JSONValue list(bool inline = false)
	{
		auto moments = group();
		// most recent first, and cap the strip
		moments.sort!((a, b) => a.from > b.from);
		if (moments.length > maxMoments)
			moments = moments[0 .. maxMoments];

		JSONValue[] out_;
		foreach (m; moments)
		{
			JSONValue j = JSONValue.emptyObject;
			j["key"] = "moment:" ~ m.from.to!string ~ ":" ~ (m.to + 1).to!string;
			j["title"] = dateLabel(m.from, m.to);
			j["subtitle"] = m.place.length
				? m.place ~ "  ·  " ~ countLabel(m.count)
				: countLabel(m.count);
			j["count"] = m.count;
			j["cover"] = coverUrl(m.cover, inline);
			out_ ~= j;
		}
		return JSONValue(["moments": JSONValue(out_)]);
	}

	/// `moment:<from>:<to>` → the taken_ts window it covers.
	Filter filterFor(string key)
	{
		import std.string : indexOf;
		Filter f;
		if (key.indexOf(':') < 0)
			return f;
		auto rest = key[key.indexOf(':') + 1 .. $];
		immutable sep = rest.indexOf(':');
		if (sep < 0)
			return f;
		try
		{
			f.tsFrom = rest[0 .. sep].to!long;
			f.tsTo = rest[sep + 1 .. $].to!long;
		}
		catch (Exception)
		{
		}
		return f;
	}

	// --- grouping -------------------------------------------------------------------

	private Moment[] group()
	{
		// Photographs only (screenshots and memes don't make events), in time order.
		auto s = db.prepare(`SELECT taken_ts, place, thumb_hash FROM photos
			WHERE taken_ts > 0 AND (kind = 'photo' OR kind IS NULL)
			ORDER BY taken_ts ASC`);
		Moment[] out_;
		bool open;
		long from, to, count;
		long[string] places;      // place → how many photos carried it, to pick the dominant one
		string[] thumbs;          // the moment's thumbnails, to pick a middle cover

		void close()
		{
			if (!open || count < minPhotos)
				return;
			Moment m;
			m.from = from;
			m.to = to;
			m.count = count;
			string best;
			long bestN;
			foreach (p, n; places)
				if (n > bestN)
				{
					bestN = n;
					best = p;
				}
			m.place = best;
			if (thumbs.length)
				m.cover = thumbs[thumbs.length / 2];   // the middle photo reads as the event, not its edges
			out_ ~= m;
		}

		while (s.step())
		{
			immutable ts = s.getLong(0);
			immutable place = s.isNull(1) ? null : s.getString(1);
			immutable thumb = s.isNull(2) ? null : s.getString(2);
			if (open && ts - to > gapSeconds)
			{
				close();
				open = false;
			}
			if (!open)
			{
				open = true;
				from = ts;
				count = 0;
				places = null;
				thumbs = null;
			}
			to = ts;
			count++;
			if (place.length)
				places[place] = (place in places ? places[place] : 0) + 1;
			if (thumb.length)
				thumbs ~= thumb;
		}
		close();
		return out_;
	}

	// --- labels + cover -------------------------------------------------------------

	private static string countLabel(long n)
	{
		return n.to!string ~ (n == 1 ? " photo" : " photos");
	}

	/// A human date for the moment: one day, a span within a month, or across months/years.
	private static string dateLabel(long from, long to)
	{
		import std.format : format;
		immutable a = localDate(from);   // [y, m, d]
		immutable b = localDate(to);
		string sh(int m) { return months[m][0 .. 3]; }   // "Sep"
		if (a == b)
			return format("%d %s %d", a[2], months[a[1]], a[0]);
		if (a[0] == b[0] && a[1] == b[1])
			return format("%d–%d %s %d", a[2], b[2], months[a[1]], a[0]);
		if (a[0] == b[0])
			return format("%d %s – %d %s %d", a[2], sh(a[1]), b[2], sh(b[1]), a[0]);
		return format("%d %s %d – %d %s %d", a[2], sh(a[1]), a[0], b[2], sh(b[1]), b[0]);
	}

	private JSONValue coverUrl(string hash, bool inline)
	{
		if (hash is null || store is null || !store.has(hash))
			return JSONValue(null);
		if (!inline)
			return JSONValue(fileUrl(store.pathFor(hash)));
		import std.base64 : Base64;
		return JSONValue("data:image/jpeg;base64," ~ cast(string) Base64.encode(store.get(hash)));
	}
}
