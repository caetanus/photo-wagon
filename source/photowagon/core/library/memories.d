/// Memories — collections the app curates for you from what it already knows:
/// "On This Day", the places and people you photograph most, the moods that recur,
/// and a throwback to this month a few years back. Nothing is stored: each memory is
/// derived on the fly and maps to an ordinary `Filter`, so opening one reuses the
/// same paged grid as everything else. See `Filter.monthDay` for the one query this
/// needed that the standard filters did not already have.
module photowagon.core.library.memories;

import std.conv : to;
import std.datetime : Clock, LocalTime;
import std.format : format;
import std.json;

import photowagon.core.db.sqlite : Database;
import photowagon.core.library.calendar : fileUrl;
import photowagon.core.library.photos : Filter, PhotoRepo;
import photowagon.core.store.store : ContentStore;

/// A curated collection. `key` encodes the filter that reopens it (see `filterFor`).
struct Memory
{
	string key;
	string kind;   // onthisday | place | person | scene | throwback
	string title;
	string subtitle;
	string cover;  // a thumbnail hash, turned into a URL for the UI
	long count;
	int prio;      // ordering: lower first
}

final class MemoriesService
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

	private static immutable string[] monthNames = [
		"", "January", "February", "March", "April", "May", "June",
		"July", "August", "September", "October", "November", "December"
	];

	/// `{memories: [{key, kind, title, subtitle, cover, count}]}`, curated and ordered.
	JSONValue list(bool inline = false)
	{
		Memory[] all;
		all ~= onThisDay();
		all ~= throwback();
		all ~= topHolidays(4);
		all ~= topPlaces(4);
		all ~= topPeople(4);
		all ~= topScenes(3);

		// Order by kind priority, then by size; drop the empties; cap the strip.
		import std.algorithm : sort, filter;
		import std.array : array;
		auto kept = all.filter!(m => m.count > 0).array;
		kept.sort!((a, b) => a.prio != b.prio ? a.prio < b.prio : a.count > b.count);
		if (kept.length > 14)
			kept = kept[0 .. 14];

		JSONValue[] out_;
		foreach (m; kept)
		{
			JSONValue j = JSONValue.emptyObject;
			j["key"] = m.key;
			j["kind"] = m.kind;
			j["title"] = m.title;
			j["subtitle"] = m.subtitle;
			j["count"] = m.count;
			j["cover"] = coverUrl(m.cover, inline);
			out_ ~= j;
		}
		return JSONValue(["memories": JSONValue(out_)]);
	}

	/// The filter that a memory `key` reopens. Unknown keys give the empty filter.
	Filter filterFor(string key)
	{
		import std.string : indexOf;
		Filter f;
		immutable colon = key.indexOf(':');
		immutable kind = colon < 0 ? key : key[0 .. colon];
		immutable rest = colon < 0 ? "" : key[colon + 1 .. $];
		switch (kind)
		{
		case "onthisday":
			f.monthDay = rest;   // "MM-DD"
			break;
		case "place":
			import std.string : indexOf;
			immutable bar = rest.indexOf('|');
			if (bar < 0)
				f.place = rest;
			else
			{
				f.place = rest[0 .. bar];
				immutable c = rest[bar + 1 .. $];
				if (c.length)
					f.country = c;
			}
			break;
		case "person":
			try
				f.personId = rest.to!long;
			catch (Exception)
			{
			}
			break;
		case "scene":
			f.tagGroup = "scene";
			f.tag = rest;
			break;
		case "holiday":
			f.tagGroup = "holiday";
			f.tag = rest;
			break;
		case "throwback":
			immutable dot = rest.indexOf(':');
			if (dot > 0)
			{
				try
				{
					f.year = rest[0 .. dot].to!int;
					f.month = rest[dot + 1 .. $].to!int;
				}
				catch (Exception)
				{
				}
			}
			break;
		default:
			break;
		}
		return f;
	}

	// --- generators -----------------------------------------------------------------

	private Memory onThisDay()
	{
		auto now = Clock.currTime(LocalTime());
		immutable md = format("%02d-%02d", now.month, now.day);
		auto s = db.prepare(`SELECT count(*),
			min(cast(strftime('%Y', taken_ts, 'unixepoch', 'localtime') AS INTEGER)),
			max(cast(strftime('%Y', taken_ts, 'unixepoch', 'localtime') AS INTEGER))
			FROM photos WHERE strftime('%m-%d', taken_ts, 'unixepoch', 'localtime') = ?`);
		s.bind(1, md);
		Memory m;
		if (!s.step())
			return m;
		immutable count = s.getLong(0);
		if (count < 3 || s.isNull(1))
			return m;
		immutable minY = cast(int) s.getLong(1);
		immutable maxY = cast(int) s.getLong(2);
		if (minY >= now.year)   // only today's own photos, not a memory yet
			return m;
		m.key = "onthisday:" ~ md;
		m.kind = "onthisday";
		m.title = "On This Day";
		m.subtitle = format("%d photos · %s", count, minY == maxY ? minY.to!string : format("%d–%d", minY, maxY));
		m.cover = newestThumb("strftime('%m-%d', taken_ts, 'unixepoch', 'localtime') = ?", md);
		m.count = count;
		m.prio = 0;
		return m;
	}

	private Memory throwback()
	{
		auto now = Clock.currTime(LocalTime());
		Memory m;
		// The most recent of the last three years that has enough of this month.
		foreach (back; 1 .. 4)
		{
			immutable y = now.year - back;
			immutable ym = format("%04d-%02d", y, now.month);
			auto s = db.prepare(`SELECT count(*) FROM photos
				WHERE strftime('%Y-%m', taken_ts, 'unixepoch', 'localtime') = ?`);
			s.bind(1, ym);
			s.step();
			immutable count = s.getLong(0);
			if (count < 5)
				continue;
			m.key = format("throwback:%d:%d", y, now.month);
			m.kind = "throwback";
			m.title = format("%s %d", monthNames[now.month], y);
			m.subtitle = format("%d photos · %s", count, back == 1 ? "a year ago" : format("%d years ago", back));
			m.cover = newestThumb("strftime('%Y-%m', taken_ts, 'unixepoch', 'localtime') = ?", ym);
			m.count = count;
			m.prio = 1;
			break;
		}
		return m;
	}

	private Memory[] topPlaces(int n)
	{
		auto s = db.prepare(`SELECT p.place, p.country, count(*) c,
			(SELECT q.thumb_hash FROM photos q WHERE q.place = p.place AND q.country IS p.country
			 AND q.thumb_hash IS NOT NULL ORDER BY q.taken_ts DESC, q.id DESC LIMIT 1)
			FROM photos p WHERE p.place IS NOT NULL AND p.place != ''
			GROUP BY p.place, p.country HAVING c >= 5 ORDER BY c DESC LIMIT ?`);
		s.bind(1, n);
		Memory[] out_;
		while (s.step())
		{
			immutable place = s.getString(0);
			immutable country = s.isNull(1) ? "" : s.getString(1);
			Memory m;
			m.count = s.getLong(2);
			m.key = "place:" ~ place ~ "|" ~ country;
			m.kind = "place";
			m.title = place;
			m.subtitle = country.length ? format("%d photos · %s", m.count, country) : format("%d photos", m.count);
			m.cover = s.isNull(3) ? null : s.getString(3);
			m.prio = 5;
			out_ ~= m;
		}
		return out_;
	}

	private Memory[] topPeople(int n)
	{
		auto s = db.prepare(`SELECT pr.id, pr.name, count(DISTINCT f.photo_id) c,
			(SELECT q.thumb_hash FROM faces f2 JOIN photos q ON q.id = f2.photo_id
			 WHERE f2.person_id = pr.id AND q.thumb_hash IS NOT NULL
			 ORDER BY q.taken_ts DESC, q.id DESC LIMIT 1)
			FROM persons pr JOIN faces f ON f.person_id = pr.id
			WHERE pr.name IS NOT NULL AND pr.name != ''
			GROUP BY pr.id HAVING c >= 5 ORDER BY c DESC LIMIT ?`);
		s.bind(1, n);
		Memory[] out_;
		while (s.step())
		{
			Memory m;
			m.key = "person:" ~ s.getLong(0).to!string;
			m.kind = "person";
			m.title = s.getString(1);
			m.count = s.getLong(2);
			m.subtitle = format("%d photo%s", m.count, m.count == 1 ? "" : "s");
			m.cover = s.isNull(3) ? null : s.getString(3);
			m.prio = 3;
			out_ ~= m;
		}
		return out_;
	}

	private Memory[] topScenes(int n)
	{
		auto s = db.prepare(`SELECT tg.tag, count(*) c,
			(SELECT q.thumb_hash FROM photo_tags t2 JOIN photos q ON q.id = t2.photo_id
			 WHERE t2.grp = 'scene' AND t2.tag = tg.tag AND q.thumb_hash IS NOT NULL
			 ORDER BY q.taken_ts DESC, q.id DESC LIMIT 1)
			FROM photo_tags tg WHERE tg.grp = 'scene' AND tg.tag IS NOT NULL AND tg.tag != ''
			GROUP BY tg.tag HAVING c >= 8 ORDER BY c DESC LIMIT ?`);
		s.bind(1, n);
		Memory[] out_;
		while (s.step())
		{
			Memory m;
			immutable tag = s.getString(0);
			m.key = "scene:" ~ tag;
			m.kind = "scene";
			m.title = tag;
			m.count = s.getLong(1);
			m.subtitle = format("%d photo%s", m.count, m.count == 1 ? "" : "s");
			m.cover = s.isNull(2) ? null : s.getString(2);
			m.prio = 4;
			out_ ~= m;
		}
		return out_;
	}

	private Memory[] topHolidays(int n)
	{
		// The holidays that recur through the library — Christmas, birthdays, Carnival …
		auto s = db.prepare(`SELECT tg.tag, count(*) c,
			(SELECT q.thumb_hash FROM photo_tags t2 JOIN photos q ON q.id = t2.photo_id
			 WHERE t2.grp = 'holiday' AND t2.tag = tg.tag AND q.thumb_hash IS NOT NULL
			 ORDER BY q.taken_ts DESC, q.id DESC LIMIT 1),
			min(cast(strftime('%Y', p.taken_ts, 'unixepoch', 'localtime') AS INTEGER)),
			max(cast(strftime('%Y', p.taken_ts, 'unixepoch', 'localtime') AS INTEGER))
			FROM photo_tags tg JOIN photos p ON p.id = tg.photo_id
			WHERE tg.grp = 'holiday' AND tg.tag IS NOT NULL AND tg.tag != ''
			GROUP BY tg.tag HAVING c >= 15 ORDER BY c DESC LIMIT ?`);
		s.bind(1, n);
		Memory[] out_;
		while (s.step())
		{
			Memory m;
			immutable tag = s.getString(0);
			m.key = "holiday:" ~ tag;
			m.kind = "holiday";
			m.title = tag;
			m.count = s.getLong(1);
			m.cover = s.isNull(2) ? null : s.getString(2);
			immutable minY = s.isNull(3) ? 0 : cast(int) s.getLong(3);
			immutable maxY = s.isNull(4) ? 0 : cast(int) s.getLong(4);
			m.subtitle = minY && minY != maxY
				? format("%d photos · %d–%d", m.count, minY, maxY)
				: format("%d photos", m.count);
			m.prio = 2;
			out_ ~= m;
		}
		return out_;
	}

	// --- helpers --------------------------------------------------------------------

	/// Newest thumbnail hash among photos matching `cond` (a WHERE fragment with one `?`).
	private string newestThumb(string cond, string arg)
	{
		auto s = db.prepare("SELECT thumb_hash FROM photos WHERE " ~ cond
			~ " AND thumb_hash IS NOT NULL ORDER BY taken_ts DESC, id DESC LIMIT 1");
		s.bind(1, arg);
		return s.step() && !s.isNull(0) ? s.getString(0) : null;
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
