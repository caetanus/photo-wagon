/// Places: the city a photo was taken in. From the EXIF GPS through a compiled-in
/// table of the world's cities (data/places, GeoNames), or the user's own word on
/// a selection ("Set Place…"). A phone with location tags off writes GPS 0,0 —
/// that is "no fix", not the Gulf of Guinea.
module photowagon.core.library.places;

import std.algorithm : min, max;
import std.array : split;
import std.conv : to;
import std.json;
import std.math : cos, sqrt, PI, ceil;
import std.string : strip, lineSplitter, startsWith;
import std.uni : toLower, normalize, NFD;

import vibe.core.log : logInfo, logWarn;

import photowagon.core.db.sqlite : Database;
import photowagon.core.db.schema : getSetting, setSetting;
import photowagon.core.ipc.events : Events;
import photowagon.core.library.calendar : fileUrl;
import photowagon.core.store.store : ContentStore;

struct City
{
	string name;
	float lat;
	float lon;
	string country; // the name, not the code
}

/// Nearest-city lookup over a table sorted by population (ties go to the bigger
/// city) with a 2° grid over it, so a lookup touches a few hundred rows.
final class Geocoder
{
	City[] cities;
	private string[string] countryNames;
	private uint[][int] grid; // key = latCell * 1000 + lonCell

	/// `citiesTsv`: name, lat, lon, ISO code per line; `countriesTsv`: code, name.
	this(string citiesTsv, string countriesTsv)
	{
		foreach (line; countriesTsv.lineSplitter)
		{
			auto f = line.split('\t');
			if (f.length >= 2)
				countryNames[f[0]] = f[1];
		}
		foreach (line; citiesTsv.lineSplitter)
		{
			auto f = line.split('\t');
			if (f.length < 4)
				continue;
			City c;
			c.name = f[0];
			try
			{
				c.lat = f[1].to!float;
				c.lon = f[2].to!float;
			}
			catch (Exception)
				continue;
			c.country = countryName(f[3]);
			grid[cell(c.lat, c.lon)] ~= cast(uint) cities.length;
			cities ~= c;
		}
	}

	/// The tables compiled into the binary (data/places).
	static Geocoder builtin()
	{
		return new Geocoder(import("cities.tsv"), import("countries.tsv"));
	}

	string countryName(string code)
	{
		if (auto p = code in countryNames)
			return *p;
		return code;
	}

	private static int cell(double lat, double lon)
	{
		immutable la = cast(int)((lat + 90) / 2);
		immutable lo = cast(int)((lon + 180) / 2);
		return la * 1000 + ((lo % 180) + 180) % 180;
	}

	/// Kilometres between two points, flat-earth approximation (fine under 200 km).
	static double distanceKm(double lat1, double lon1, double lat2, double lon2)
	{
		immutable k = cos((lat1 + lat2) / 2 * PI / 180);
		immutable dx = (lon2 - lon1) * k;
		immutable dy = lat2 - lat1;
		return 111.2 * sqrt(dx * dx + dy * dy);
	}

	/// The nearest city within `maxKm`; false when there is none.
	bool nearest(double lat, double lon, out City best, double maxKm = 100)
	{
		if (lat < -90 || lat > 90 || lon < -180 || lon > 180)
			return false;
		immutable la = cast(int)((lat + 90) / 2);
		immutable lo = cast(int)((lon + 180) / 2);
		immutable degLat = maxKm / 111.2;
		immutable k = max(cos(lat * PI / 180), 0.05);
		immutable cellsLat = cast(int) ceil(degLat / 2) + 1;
		immutable cellsLon = min(cast(int) ceil(degLat / k / 2) + 1, 90);
		double bestKm = maxKm;
		bool found;
		foreach (dl; -cellsLat .. cellsLat + 1)
			foreach (dn; -cellsLon .. cellsLon + 1)
			{
				immutable key = (la + dl) * 1000 + (((lo + dn) % 180) + 180) % 180;
				auto bucket = key in grid;
				if (bucket is null)
					continue;
				foreach (i; *bucket)
				{
					immutable d = distanceKm(lat, lon, cities[i].lat, cities[i].lon);
					if (d < bestKm)
					{
						bestKm = d;
						best = cities[i];
						found = true;
					}
				}
			}
		return found;
	}

	/// Cities whose name starts with `q`, accents and case aside, biggest first.
	City[] suggest(string q, size_t limit = 8)
	{
		immutable key = fold(q);
		if (!key.length)
			return null;
		City[] out_;
		foreach (ref c; cities)
			if (fold(c.name).startsWith(key))
			{
				out_ ~= c;
				if (out_.length >= limit)
					break;
			}
		return out_;
	}

	/// "São Paulo" → "sao paulo": lower case, combining marks dropped.
	static string fold(string s)
	{
		string out_;
		foreach (dchar ch; normalize!NFD(s.strip).toLower)
			if (ch < 0x300 || ch > 0x36F)
				out_ ~= ch;
		return out_;
	}
}

/// Bump to redo every automatic (GPS) placement, e.g. after a table update.
enum placeVersion = 1;

final class PlaceService
{
	private Database db;
	private Geocoder geo;
	private ContentStore store;
	private Events events;
	/// Called with the photos whose place the user set (the file tag writer listens).
	void delegate(const(long)[] ids) onUserChange;

	this(Database db, Geocoder geo, ContentStore store, Events events)
	{
		this.db = db;
		this.geo = geo;
		this.store = store;
		this.events = events;
	}

	/// Names the photos that have GPS and were never looked up. Returns how many got a place.
	long geocodePending()
	{
		if (getSetting(db, "place_version") != placeVersion.to!string)
		{
			db.exec("UPDATE photos SET place = NULL, country = NULL, place_by = NULL WHERE place_by = 'gps' OR place_by = 'none'");
			setSetting(db, "place_version", placeVersion.to!string);
		}
		auto q = db.prepare("SELECT id, lat, lon FROM photos WHERE lat IS NOT NULL AND lon IS NOT NULL AND place_by IS NULL AND NOT (lat = 0 AND lon = 0)");
		long[] ids;
		double[] lats, lons;
		while (q.step())
		{
			ids ~= q.getLong(0);
			lats ~= q.getDouble(1);
			lons ~= q.getDouble(2);
		}
		if (!ids.length)
			return 0;
		long named;
		db.transaction!void({
			auto u = db.prepare("UPDATE photos SET place = ?, country = ?, place_by = ? WHERE id = ?");
			foreach (i, id; ids)
			{
				City c;
				u.reset();
				if (geo.nearest(lats[i], lons[i], c))
				{
					u.bind(1, c.name).bind(2, c.country).bind(3, "gps").bind(4, id);
					named++;
				}
				else
					u.bind(1, cast(string) null).bind(2, cast(string) null).bind(3, "none").bind(4, id);
				u.run();
			}
		});
		logInfo("places: %s of %s photos with GPS placed in a city", named, ids.length);
		if (named && events !is null)
			events.emit("places.changed", JSONValue.emptyObject);
		return named;
	}

	/// `{places: [{place, country, count, cover}]}`, most photos first; `cover` is
	/// the newest photo's thumbnail (a data: URL with `inline`).
	JSONValue list(bool inline = false)
	{
		auto s = db.prepare(`SELECT p.place, p.country, count(*),
			(SELECT q.thumb_hash FROM photos q WHERE q.place = p.place AND q.country IS p.country AND q.thumb_hash IS NOT NULL
			 ORDER BY q.taken_ts DESC, q.id DESC LIMIT 1)
			FROM photos p WHERE p.place IS NOT NULL GROUP BY p.place, p.country ORDER BY 3 DESC, 1`);
		JSONValue[] out_;
		while (s.step())
		{
			JSONValue j = JSONValue.emptyObject;
			j["place"] = s.getString(0);
			j["country"] = s.isNull(1) ? JSONValue(null) : JSONValue(s.getString(1));
			j["count"] = s.getLong(2);
			j["cover"] = coverUrl(s.isNull(3) ? null : s.getString(3), inline);
			out_ ~= j;
		}
		return JSONValue(["places": JSONValue(out_)]);
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

	/// The user's word: `place` empty clears (and the GPS will not put it back).
	void setPlace(long[] ids, string place, string country)
	{
		place = place.strip;
		country = country.strip;
		if (place.length && !country.length)
		{
			// a typed city we know: take its country
			auto hits = geo.suggest(place, 1);
			if (hits.length && Geocoder.fold(hits[0].name) == Geocoder.fold(place))
			{
				place = hits[0].name;
				country = hits[0].country;
			}
		}
		db.transaction!void({
			auto u = db.prepare("UPDATE photos SET place = ?, country = ?, place_by = 'user' WHERE id = ?");
			foreach (id; ids)
			{
				u.reset();
				if (place.length)
					u.bind(1, place).bind(2, country.length ? country : cast(string) null);
				else
					u.bind(1, cast(string) null).bind(2, cast(string) null);
				u.bind(3, id);
				u.run();
			}
		});
		if (events !is null)
			events.emit("places.changed", JSONValue.emptyObject);
		if (onUserChange !is null)
			onUserChange(ids);
	}

	/// `{places: [{place, country}]}` for a name being typed: the library's own
	/// places first, then the world's cities.
	JSONValue suggest(string q, size_t limit = 8)
	{
		JSONValue[] out_;
		bool[string] seen;
		immutable key = Geocoder.fold(q);
		if (key.length)
		{
			auto s = db.prepare("SELECT place, country, count(*) FROM photos WHERE place IS NOT NULL GROUP BY place, country ORDER BY 3 DESC");
			while (s.step() && out_.length < limit)
			{
				immutable place = s.getString(0);
				if (!Geocoder.fold(place).startsWith(key))
					continue;
				immutable country = s.isNull(1) ? null : s.getString(1);
				seen[place ~ "|" ~ country] = true;
				out_ ~= JSONValue(["place": JSONValue(place), "country": country is null ? JSONValue(null) : JSONValue(country), "own": JSONValue(true)]);
			}
			foreach (c; geo.suggest(q, limit))
			{
				if ((c.name ~ "|" ~ c.country) in seen || out_.length >= limit)
					continue;
				out_ ~= JSONValue(["place": JSONValue(c.name), "country": JSONValue(c.country), "own": JSONValue(false)]);
			}
		}
		return JSONValue(["places": JSONValue(out_)]);
	}
}

unittest
{
	auto g = new Geocoder("São Paulo\t-23.5475\t-46.6361\tBR\nGuarulhos\t-23.4628\t-46.5333\tBR\nLisbon\t38.7167\t-9.1333\tPT\nSalvador\t-12.9711\t-38.5108\tBR\n",
			"BR\tBrazil\nPT\tPortugal\n");
	City c;
	assert(g.nearest(-23.55, -46.64, c) && c.name == "São Paulo" && c.country == "Brazil");
	assert(g.nearest(-23.46, -46.53, c) && c.name == "Guarulhos");
	assert(g.nearest(38.72, -9.14, c) && c.name == "Lisbon" && c.country == "Portugal");
	assert(!g.nearest(0, 0, c));           // the Gulf of Guinea: no city for 100 km
	assert(!g.nearest(-30, -50, c));       // the Atlantic
	assert(Geocoder.fold("São Paulo") == "sao paulo");
	assert(g.suggest("sao")[0].name == "São Paulo");
	assert(g.suggest("SAL")[0].name == "Salvador");
	assert(g.suggest("xyz").length == 0);
	assert(Geocoder.distanceKm(-23.5475, -46.6361, -23.4628, -46.5333) < 20);
}

unittest
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	auto g = new Geocoder("São Paulo\t-23.5475\t-46.6361\tBR\nLisbon\t38.7167\t-9.1333\tPT\n", "BR\tBrazil\nPT\tPortugal\n");
	auto svc = new PlaceService(db, g, null, null);
	db.exec(`INSERT INTO photos (id, hash, path, taken_ts, taken_at, lat, lon) VALUES
		(1, 'a', '/a', 0, '', -23.55, -46.64), (2, 'b', '/b', 0, '', 0, 0), (3, 'c', '/c', 0, '', NULL, NULL), (4, 'd', '/d', 0, '', 38.72, -9.14)`);
	assert(svc.geocodePending() == 2);
	assert(svc.geocodePending() == 0); // nothing left to look up
	auto l = svc.list()["places"].array;
	assert(l.length == 2 && l[0]["count"].integer == 1);
	svc.setPlace([2, 3], "lisbon", "");    // a typed name we know gets its case and country
	l = svc.list()["places"].array;
	assert(l[0]["place"].str == "Lisbon" && l[0]["country"].str == "Portugal" && l[0]["count"].integer == 3);
	svc.setPlace([1], "Vovó's farm", "");  // an unknown name stays as typed
	assert(svc.suggest("vov")["places"].array[0]["place"].str == "Vovó's farm");
	svc.setPlace([1], "", "");             // cleared, and the GPS will not put it back
	assert(svc.geocodePending() == 0);
	assert(svc.list()["places"].array.length == 1);
}
