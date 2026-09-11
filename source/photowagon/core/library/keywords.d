/// Keywords: the user's own tags on photos, any word, as many as wanted ("praia
/// 2020", "casa da vó", "vender"). Next to the classifier tags (scenes.d) they
/// are what the tag strip under a photo shows and what the sidebar lists.
module photowagon.core.library.keywords;

import std.algorithm : sort, uniq;
import std.array : array, split;
import std.json;
import std.string : strip;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.events : Events;
import photowagon.core.library.calendar : fileUrl;
import photowagon.core.store.store : ContentStore;

/// Separator used by the `keywords` subquery of PhotoRepo (group_concat).
enum keywordSep = "\x1f";

final class KeywordService
{
	private Database db;
	private ContentStore store;
	private Events events;
	/// Called with the photos whose keywords the user changed (the file tag writer listens).
	void delegate(const(long)[] ids) onUserChange;

	this(Database db, ContentStore store, Events events)
	{
		this.db = db;
		this.store = store;
		this.events = events;
	}

	/// `{keywords: [{keyword, count, cover}]}`, most photos first.
	JSONValue list(bool inline = false)
	{
		auto s = db.prepare(`SELECT k.keyword, count(*),
			(SELECT p.thumb_hash FROM photo_keywords k2 JOIN photos p ON p.id = k2.photo_id
			 WHERE k2.keyword = k.keyword AND p.thumb_hash IS NOT NULL ORDER BY p.taken_ts DESC, p.id DESC LIMIT 1)
			FROM photo_keywords k GROUP BY k.keyword ORDER BY 2 DESC, 1`);
		JSONValue[] out_;
		while (s.step())
		{
			JSONValue j = JSONValue.emptyObject;
			j["keyword"] = s.getString(0);
			j["count"] = s.getLong(1);
			j["cover"] = coverUrl(s.isNull(2) ? null : s.getString(2), inline);
			out_ ~= j;
		}
		return JSONValue(["keywords": JSONValue(out_)]);
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

	string[] ofPhoto(long id)
	{
		auto s = db.prepare("SELECT keyword FROM photo_keywords WHERE photo_id = ? ORDER BY keyword");
		s.bind(1, id);
		string[] out_;
		while (s.step())
			out_ ~= s.getString(0);
		return out_;
	}

	/// Cleans a typed list: trimmed, non-empty, no duplicates, the user's case kept.
	static string[] normalize(string[] raw)
	{
		string[] out_;
		bool[string] seen;
		foreach (k; raw)
		{
			immutable t = k.strip;
			if (!t.length)
				continue;
			import std.uni : toLower;
			immutable key = t.toLower;
			if (key in seen)
				continue;
			seen[key] = true;
			out_ ~= t;
		}
		return out_;
	}

	/// Adds every keyword to every photo (already there = nothing happens).
	void add(long[] ids, string[] keywords)
	{
		keywords = normalize(keywords);
		if (!ids.length || !keywords.length)
			return;
		db.transaction!void({
			auto u = db.prepare("INSERT OR IGNORE INTO photo_keywords (photo_id, keyword) VALUES (?, ?)");
			foreach (id; ids)
				foreach (k; keywords)
				{
					u.reset();
					u.bind(1, id).bind(2, k);
					u.run();
				}
		});
		if (events !is null)
			events.emit("keywords.changed", JSONValue.emptyObject);
		if (onUserChange !is null)
			onUserChange(ids);
	}

	void remove(long[] ids, string keyword)
	{
		keyword = keyword.strip;
		if (!ids.length || !keyword.length)
			return;
		db.transaction!void({
			auto u = db.prepare("DELETE FROM photo_keywords WHERE photo_id = ? AND keyword = ? COLLATE NOCASE");
			foreach (id; ids)
			{
				u.reset();
				u.bind(1, id).bind(2, keyword);
				u.run();
			}
		});
		if (events !is null)
			events.emit("keywords.changed", JSONValue.emptyObject);
		if (onUserChange !is null)
			onUserChange(ids);
	}

	/// Renames a keyword everywhere (merges into an existing one).
	void rename(string from, string to)
	{
		to = to.strip;
		if (!to.length)
			return;
		db.transaction!void({
			auto u = db.prepare("INSERT OR IGNORE INTO photo_keywords (photo_id, keyword) SELECT photo_id, ? FROM photo_keywords WHERE keyword = ?");
			u.bind(1, to).bind(2, from);
			u.run();
			auto d = db.prepare("DELETE FROM photo_keywords WHERE keyword = ? AND keyword <> ?");
			d.bind(1, from).bind(2, to);
			d.run();
		});
		if (events !is null)
			events.emit("keywords.changed", JSONValue.emptyObject);
		if (onUserChange !is null)
		{
			long[] ids;
			auto q = db.prepare("SELECT photo_id FROM photo_keywords WHERE keyword = ?");
			q.bind(1, to);
			while (q.step())
				ids ~= q.getLong(0);
			onUserChange(ids);
		}
	}
}

unittest
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	db.exec(`INSERT INTO photos (id, hash, path, taken_ts, taken_at) VALUES (1, 'a', '/a', 0, ''), (2, 'b', '/b', 0, '')`);
	auto svc = new KeywordService(db, null, null);
	svc.add([1, 2], [" praia ", "praia", "Casa da Vó", ""]);
	assert(svc.ofPhoto(1) == ["Casa da Vó", "praia"]);
	auto l = svc.list()["keywords"].array;
	assert(l.length == 2 && l[0]["count"].integer == 2);
	svc.remove([1], "PRAIA");   // case does not matter when removing
	assert(svc.ofPhoto(1) == ["Casa da Vó"]);
	svc.rename("praia", "Praia 2020");
	assert(svc.ofPhoto(2) == ["Casa da Vó", "Praia 2020"]);
	assert(KeywordService.normalize(["a", "A", " b "]) == ["a", "b"]);
}
