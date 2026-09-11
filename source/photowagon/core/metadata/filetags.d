/// Tags in the files themselves. The library's word on a photo — the user's
/// keywords, the scene / mood / weather / holiday, the place — goes into the
/// file's XMP dc:subject and IPTC keywords, where any other program reads it
/// ("praia 2020", "Scene: Beach", "Place: Peruíbe, Brazil"); and what a file
/// already carries when it is imported comes back the same way. Pixels are
/// never touched and the modification time is put back, so the file's hash in
/// the library (the one the phone deduplicates by) stays the import-time hash.
module photowagon.core.metadata.filetags;

import std.algorithm : canFind;
import std.array : split;
import std.json;
import std.string : startsWith, strip, lastIndexOf;

import vibe.core.concurrency : async;
import vibe.core.log : logInfo, logWarn;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.events : Events;
import photowagon.core.metadata.exif : writeSubjects;

/// The prefixes that tell a classifier tag or a place from a plain keyword.
private enum string[string] prefixOf = [
	"scene": "Scene:", "mood": "Mood:", "weather": "Weather:", "holiday": "Holiday:", "place": "Place:",
];

struct Subjects
{
	string[] keywords;
	string[string] tags; // group → tag
	string place;
	string country;

	/// The list that goes into the file: keywords first, then the rest, prefixed.
	string[] encode() const
	{
		string[] out_ = keywords.dup;
		foreach (g; ["scene", "mood", "weather", "holiday"])
			if (auto t = g in tags)
				if (t.length)
					out_ ~= prefixOf[g] ~ " " ~ *t;
		if (place.length)
			out_ ~= prefixOf["place"] ~ " " ~ place ~ (country.length ? ", " ~ country : "");
		return out_;
	}

	/// The other way round: a file's keyword list, ours or anybody's.
	static Subjects decode(const(string)[] list)
	{
		Subjects s;
		foreach (raw; list)
		{
			immutable k = raw.strip;
			if (!k.length)
				continue;
			bool taken;
			foreach (g, pre; prefixOf)
				if (k.startsWith(pre))
				{
					immutable v = k[pre.length .. $].strip;
					if (g == "place")
					{
						immutable comma = v.lastIndexOf(", ");
						s.place = comma > 0 ? v[0 .. comma].strip : v;
						s.country = comma > 0 ? v[comma + 2 .. $].strip : null;
					}
					else if (v.length)
						s.tags[g] = v;
					taken = true;
					break;
				}
			if (!taken && !s.keywords.canFind(k))
				s.keywords ~= k;
		}
		return s;
	}
}

/// What the library says about photo `id`, ready to be written.
Subjects subjectsOf(Database db, long id, out string path)
{
	Subjects s;
	{
		auto q = db.prepare("SELECT path, place, country FROM photos WHERE id = ?");
		q.bind(1, id);
		if (!q.step())
			return s;
		path = q.getString(0);
		s.place = q.getString(1);
		s.country = q.getString(2);
	}
	{
		auto q = db.prepare("SELECT grp, tag FROM photo_tags WHERE photo_id = ? AND tag <> ''");
		q.bind(1, id);
		while (q.step())
			s.tags[q.getString(0)] = q.getString(1);
	}
	{
		auto q = db.prepare("SELECT keyword FROM photo_keywords WHERE photo_id = ? ORDER BY keyword");
		q.bind(1, id);
		while (q.step())
			s.keywords ~= q.getString(0);
	}
	return s;
}

/// A file's keywords, just imported, come into the library: plain keywords are
/// added; prefixed tags and the place are taken as `file` — shown right away, kept
/// until the classifiers are re-run with a new vocabulary, and never overriding
/// what the user said here.
void applyFileSubjects(Database db, long id, const(string)[] list)
{
	auto s = Subjects.decode(list);
	db.transaction!void({
		if (s.keywords.length)
		{
			auto u = db.prepare("INSERT OR IGNORE INTO photo_keywords (photo_id, keyword) VALUES (?, ?)");
			foreach (k; s.keywords)
			{
				u.reset();
				u.bind(1, id).bind(2, k);
				u.run();
			}
		}
		if (s.tags.length)
		{
			auto u = db.prepare(`INSERT INTO photo_tags (photo_id, grp, tag, score, tag_by) VALUES (?, ?, ?, 1, 'file')
				ON CONFLICT(photo_id, grp) DO UPDATE SET tag = excluded.tag, score = 1, tag_by = 'file' WHERE photo_tags.tag_by <> 'user'`);
			foreach (g, t; s.tags)
			{
				u.reset();
				u.bind(1, id).bind(2, g).bind(3, t);
				u.run();
			}
		}
		if (s.place.length)
		{
			auto u = db.prepare("UPDATE photos SET place = ?, country = ?, place_by = 'file' WHERE id = ? AND (place_by IS NULL OR place_by <> 'user')");
			u.bind(1, s.place).bind(2, s.country.length ? s.country : cast(string) null).bind(3, id);
			u.run();
		}
	});
}

/// `writeSubjects` for `async`: the list travels joined (small arguments).
private string writeJoined(string path, string joined)
{
	return writeSubjects(path, joined.length ? joined.split("\x1f") : null);
}

/// Writes the library's tags into files, one at a time, on a worker: everything the
/// library knows about the photo, the classifiers' word included. Photos are queued
/// by the services when the user changes something about them, and by
/// `files.writeTags` for the rest.
final class FileTagWriter
{
	private Database db;
	private Events events;
	private FiberGroup jobs;
	private bool[long] queue;
	private bool running, closed;

	this(Database db, Events events)
	{
		this.db = db;
		this.events = events;
		jobs = new FiberGroup((Exception e) nothrow {
			try
				logWarn("filetags: job failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	void close() nothrow
	{
		closed = true;
		jobs.stopAll();
	}

	/// Queues these photos; the job starts if it is not running.
	void enqueue(const(long)[] ids)
	{
		foreach (id; ids)
			queue[id] = true;
		if (!running && !closed && queue.length)
		{
			running = true;
			jobs.spawn(&run);
		}
	}

	/// Every local photo that carries anything to write.
	long enqueueAll()
	{
		long[] ids;
		auto q = db.prepare(`SELECT id FROM photos p WHERE p.path IS NOT NULL AND (p.place IS NOT NULL
			OR EXISTS (SELECT 1 FROM photo_tags t WHERE t.photo_id = p.id AND t.tag <> '')
			OR EXISTS (SELECT 1 FROM photo_keywords k WHERE k.photo_id = p.id))`);
		while (q.step())
			ids ~= q.getLong(0);
		enqueue(ids);
		return ids.length;
	}

	size_t pending() const
	{
		return queue.length;
	}

	private void run()
	{
		import core.time : MonoTime, msecs;
		import std.file : exists;

		scope (exit)
			running = false;
		long done, written, failed;
		auto lastReport = MonoTime.currTime;
		immutable total = queue.length;
		while (queue.length && !closed)
		{
			long id;
			foreach (k, _; queue)
			{
				id = k;
				break;
			}
			queue.remove(id);
			string path;
			auto s = subjectsOf(db, id, path);
			done++;
			if (path is null || !path.exists)
				continue;
			string joined;
			foreach (i, k; s.encode())
				joined ~= (i ? "\x1f" : "") ~ k;
			auto err = async(&writeJoined, path, joined).getResult();
			if (err is null)
			{
				written++;
				// the file grew or shrank by its metadata; the indexer must not take it for a new
				// file (the hash on record stays the import-time one — the one the phone knows)
				try
				{
					import std.file : getSize;
					auto u = db.prepare("UPDATE photos SET size = ? WHERE id = ?");
					u.bind(1, cast(long) getSize(path)).bind(2, id);
					u.run();
				}
				catch (Exception)
				{
				}
			}
			else
			{
				failed++;
				logWarn("filetags: %s: %s", path, err);
			}
			if (MonoTime.currTime - lastReport > 300.msecs)
			{
				lastReport = MonoTime.currTime;
				events.emit("files.tags", JSONValue(["done": JSONValue(done), "total": JSONValue(cast(long) total)]));
			}
		}
		logInfo("filetags: %s files written, %s failed", written, failed);
		events.emit("files.tags.done", JSONValue(["written": JSONValue(written), "failed": JSONValue(failed)]));
	}
}

unittest
{
	Subjects s;
	s.keywords = ["praia 2020", "família"];
	s.tags["scene"] = "Beach";
	s.tags["weather"] = "Hot";
	s.place = "Peruíbe";
	s.country = "Brazil";
	auto list = s.encode();
	assert(list == ["praia 2020", "família", "Scene: Beach", "Weather: Hot", "Place: Peruíbe, Brazil"]);
	auto back = Subjects.decode(list ~ ["  praia 2020 ", "Mood: ", "Lightroom keyword"]);
	assert(back.keywords == ["praia 2020", "família", "Lightroom keyword"]);
	assert(back.tags["scene"] == "Beach" && back.tags["weather"] == "Hot" && "mood" !in back.tags);
	assert(back.place == "Peruíbe" && back.country == "Brazil");
	assert(Subjects.decode(["Place: Sítio da Vovó"]).place == "Sítio da Vovó");
	assert(Subjects.decode(["Place: Sítio da Vovó"]).country is null);
}

unittest
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	db.exec(`INSERT INTO photos (id, hash, path, taken_ts, taken_at) VALUES (1, 'a', '/a', 0, '')`);
	db.exec(`INSERT INTO photo_tags (photo_id, grp, tag, score, tag_by) VALUES (1, 'mood', 'Calm', 1, 'user'), (1, 'scene', 'Pool', 0.5, 'auto')`);
	applyFileSubjects(db, 1, ["viagem", "Scene: Beach", "Mood: Joyful", "Place: Peruíbe, Brazil"]);
	string path;
	auto s = subjectsOf(db, 1, path);
	assert(path == "/a" && s.keywords == ["viagem"]);
	assert(s.tags["scene"] == "Beach");   // the automatic guess yields to the file
	assert(s.tags["mood"] == "Calm");     // the user's word here stays
	assert(s.place == "Peruíbe" && s.country == "Brazil");
	assert(s.encode() == ["viagem", "Scene: Beach", "Mood: Calm", "Place: Peruíbe, Brazil"]);
}
