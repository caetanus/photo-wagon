/// Scenes, moods, weather and holidays: zero-shot tags from CLIP. Every photograph
/// gets one image embedding (stored, so a new vocabulary costs no re-encoding) and,
/// per group, the label whose text embedding it is closest to — or nothing, when
/// "a photo of nothing in particular" wins or the winner is weak. For holidays the
/// calendar (holidays.d) speaks first. The user's word (`setTag`) sticks.
/// Vocabulary and text embeddings: data/scenes.
module photowagon.core.library.scenes;

import core.time : MonoTime, msecs;
import std.algorithm : max;
import std.array : split;
import std.conv : to;
import std.json;
import std.math : exp;
import std.string : lineSplitter, strip;

import vibe.core.concurrency : async;
import vibe.core.log : logInfo, logWarn;
import vibe.core.task : InterruptException;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.config : Config;
import photowagon.core.db.schema : getSetting, setSetting;
import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.events : Events;
import photowagon.core.library.calendar : fileUrl;
import photowagon.core.library.clip : clipDim, clipEncode, initClip;
import photowagon.core.library.holidays : holidayOf;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.store.store : ContentStore;

/// Bump when the vocabulary (data/scenes/prompts.tsv) or the scoring changes:
/// the automatic tags are redone from the stored embeddings.
enum tagsVersion = 5;
/// Bump when the image model changes: everything is re-encoded.
enum clipVersion = 2;   // 1 stored zero embeddings for photos whose tag insert failed

/// CLIP's logit scale; the softmax over a group's labels uses it.
enum logitScale = 100.0;
/// The winner must have this much of the group's probability mass to count.
/// Weather and holidays ask for more: an indoor photo is not "Hot", a cake is not
/// always a birthday.
double minProbFor(string group) pure nothrow @safe
{
	switch (group)
	{
	case "weather":
		return 0.60;
	case "holiday":
		return 0.70;   // three friends in black dresses were a 'graduation' at 60 %
	default:
		return 0.30;
	}
}

/// The groups, in the order of the vocabulary; each photo gets one tag per group.
enum string[] tagGroups = ["scene", "mood", "weather", "holiday"];

struct Label
{
	string group; // scene | mood | weather | holiday
	string name;
	float[clipDim] embedding;
	bool nothing; // the "nothing in particular" class of its group
	bool dateOnly; // holidays the calendar alone assigns (a mother with her baby is not Mother's Day)
}

/// The vocabulary compiled in from data/scenes/prompts.tsv.
Label[] parseVocabulary(string tsv)
{
	Label[] out_;
	foreach (line; tsv.lineSplitter)
	{
		auto f = line.split('\t');
		if (f.length < 3)
			continue;
		Label l;
		l.group = f[0];
		l.name = f[1];
		l.dateOnly = f.length > 3 && f[3].strip == "date";
		auto v = f[2].strip.split(' ');
		if (v.length != clipDim)
			continue;
		foreach (i, x; v)
			l.embedding[i] = x.to!float;
		// the first label of a group is its "nothing in particular" class
		l.nothing = true;
		foreach (ref o; out_)
			if (o.group == l.group)
				l.nothing = false;
		out_ ~= l;
	}
	return out_;
}

Label[] builtinVocabulary()
{
	return parseVocabulary(import("prompts.tsv"));
}

struct Scored
{
	string tag; // "" when nothing in particular
	float prob;
	string[] top; // the three best labels, for the info panel
	float[] probs;
}

/// The best label of `group` for an image embedding.
Scored score(const Label[] vocab, const float[clipDim] emb, string group)
{
	double[] sims;
	const(Label)*[] labels;
	foreach (ref l; vocab)
		if (l.group == group && !l.dateOnly)
		{
			double d = 0;
			foreach (i; 0 .. clipDim)
				d += cast(double) emb[i] * l.embedding[i];
			sims ~= d;
			labels ~= &l;
		}
	Scored s;
	if (!labels.length)
		return s;
	double mx = -1e9;
	foreach (v; sims)
		mx = max(mx, v);
	double sum = 0;
	double[] probs;
	foreach (v; sims)
	{
		immutable p = exp(logitScale * (v - mx));
		probs ~= p;
		sum += p;
	}
	foreach (ref p; probs)
		p /= sum;
	// the three best, in order
	size_t[] order;
	foreach (i; 0 .. probs.length)
		order ~= i;
	import std.algorithm : sort;
	order.sort!((a, b) => probs[a] > probs[b]);
	foreach (i; order[0 .. order.length > 3 ? 3 : order.length])
	{
		s.top ~= labels[i].name;
		s.probs ~= cast(float) probs[i];
	}
	immutable best = order[0];
	s.prob = cast(float) probs[best];
	if (!labels[best].nothing && probs[best] >= minProbFor(group))
		s.tag = labels[best].name;
	return s;
}

final class SceneService
{
	private Config cfg;
	private Database db;
	private PhotoRepo photos;
	private ContentStore store;
	private Events events;
	private Label[] vocab;
	private FiberGroup jobs;
	private bool running, again, closed;
	/// False when the model file is missing: the library gets no tags, nothing else changes.
	bool available;

	this(Config cfg, Database db, PhotoRepo photos, ContentStore store, Events events)
	{
		this.cfg = cfg;
		this.db = db;
		this.photos = photos;
		this.store = store;
		this.events = events;
		vocab = builtinVocabulary();
		if (getSetting(db, "tags_version") != tagsVersion.to!string)
		{
			db.exec("DELETE FROM photo_tags WHERE tag_by = 'auto' OR tag_by = 'date'");
			setSetting(db, "tags_version", tagsVersion.to!string);
		}
		if (getSetting(db, "clip_version") != clipVersion.to!string)
		{
			db.exec("DELETE FROM photo_clip");
			db.exec("DELETE FROM photo_tags WHERE tag_by = 'auto' OR tag_by = 'date'");
			setSetting(db, "clip_version", clipVersion.to!string);
		}
		try
		{
			initClip(cfg.clipModel);
			available = true;
		}
		catch (Exception e)
			logWarn("scenes: %s — scenes and moods are off (put the model in %s)", e.msg, cfg.modelsDir);
		jobs = new FiberGroup((Exception e) nothrow {
			try
				logWarn("scenes: job failed: %s", e.msg);
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

	bool busy() const
	{
		return running;
	}

	void start()
	{
		if (!available || closed)
			return;
		if (running)
		{
			again = true;
			return;
		}
		running = true;
		jobs.spawn(() {
			scope (exit)
				running = false;
			do
			{
				again = false;
				run();
			}
			while (again);
		});
	}

	// ---- the pass -----------------------------------------------------------------

	private long[] pending()
	{
		// photographs (or not yet classified) with a thumbnail and no embedding yet
		auto s = db.prepare(`SELECT p.id FROM photos p LEFT JOIN photo_clip c ON c.photo_id = p.id
			WHERE c.photo_id IS NULL AND p.thumb_hash IS NOT NULL AND (p.kind = 'photo' OR p.kind IS NULL) ORDER BY p.id`);
		long[] out_;
		while (s.step())
			out_ ~= s.getLong(0);
		return out_;
	}

	private void run()
	{
		// 1. embeddings for the new photos
		auto ids = pending();
		auto started = MonoTime.currTime, lastReport = started;
		long done, tagged;
		if (ids.length)
			logInfo("scenes: encoding %s photos", ids.length);
		foreach (id; ids)
		{
			if (closed)
				return;
			float[clipDim] emb;
			bool encoded;
			try
			{
				auto p = photos.get(id);
				// the stored thumbnail: CLIP looks at 224 px anyway, and no 100 MP decode
				immutable src = store.pathFor(p.thumbHash);
				emb = async(&clipEncode, src).getResult();
				encoded = true;
			}
			catch (InterruptException)
				throw new InterruptException;
			catch (Exception e)
			{
				logWarn("scenes: photo %s: %s", id, e.msg);
				markFailed(id);   // an unreadable image is not retried; the zero embedding says so
			}
			if (encoded)
				try
				{
					storeEmbedding(id, emb);
					if (tagAuto(id, emb))
						tagged++;
				}
				catch (InterruptException)
					throw new InterruptException;
				catch (Exception e)
					logWarn("scenes: photo %s: %s (will be retried)", id, e.msg);
			done++;
			if (MonoTime.currTime - lastReport > 300.msecs || done == ids.length)
			{
				lastReport = MonoTime.currTime;
				events.emit("tags.progress", JSONValue(["done": JSONValue(done), "total": JSONValue(ids.length)]));
			}
			if (done % 50 == 0)
				events.emit("tags.changed", JSONValue.emptyObject);
		}
		// 2. tags for embedded photos without them (a new vocabulary, or a group added)
		long rescored = rescoreMissing();
		if (done || rescored)
		{
			immutable secs = (MonoTime.currTime - started).total!"msecs" / 1000.0;
			logInfo("scenes: done — %s photos encoded, %s tagged, %s re-scored, %.1fs", done, tagged, rescored, secs);
			events.emit("tags.done", JSONValue(["photos": JSONValue(done), "tagged": JSONValue(tagged), "seconds": JSONValue(secs)]));
			events.emit("tags.changed", JSONValue.emptyObject);
		}
	}

	private void storeEmbedding(long id, const float[clipDim] emb)
	{
		auto u = db.prepare("INSERT OR REPLACE INTO photo_clip (photo_id, embedding, version) VALUES (?, ?, ?)");
		u.bind(1, id).bind(2, cast(const(ubyte)[]) emb[]).bind(3, clipVersion);
		u.run();
	}

	/// An image that cannot be read gets an all-zero embedding, so it is not retried forever.
	private void markFailed(long id)
	{
		float[clipDim] zero = 0;
		storeEmbedding(id, zero);
	}

	private bool loadEmbedding(long id, out float[clipDim] emb)
	{
		auto s = db.prepare("SELECT embedding FROM photo_clip WHERE photo_id = ?");
		s.bind(1, id);
		if (!s.step())
			return false;
		auto b = s.getBlob(0);
		if (b.length != clipDim * float.sizeof)
			return false;
		emb[] = (cast(const(float)[]) b)[];
		return true;
	}

	private static bool isZero(const float[clipDim] emb)
	{
		foreach (v; emb)
			if (v != 0)
				return false;
		return true;
	}

	/// Automatic tags for every group where the user has said nothing. True when a real tag landed.
	/// The calendar speaks first for `holiday`; a zero embedding (unreadable image) still gets its date.
	private bool tagAuto(long id, const float[clipDim] emb)
	{
		bool any;
		auto u = db.prepare("INSERT INTO photo_tags (photo_id, grp, tag, score, tag_by) VALUES (?, ?, ?, ?, ?) ON CONFLICT(photo_id, grp) DO NOTHING");
		immutable zero = isZero(emb);
		foreach (group; tagGroups)
		{
			string tag, by = "auto";
			double prob = 0;
			if (group == "holiday")
			{
				tag = holidayOf(takenTs(id));
				if (tag.length)
				{
					by = "date";
					prob = 1;
				}
			}
			if (!tag.length && !zero)
			{
				auto sc = score(vocab, emb, group);
				tag = sc.tag;
				prob = sc.prob;
			}
			if (zero && !tag.length)
				continue;
			u.reset();
			u.bind(1, id).bind(2, group).bind(3, tag is null ? "" : tag).bind(4, prob).bind(5, by);
			u.run();
			if (tag.length)
				any = true;
		}
		return any;
	}

	private long takenTs(long id)
	{
		auto s = db.prepare("SELECT taken_ts FROM photos WHERE id = ?");
		s.bind(1, id);
		return s.step() ? s.getLong(0) : 0;
	}

	private long rescoreMissing()
	{
		auto q = db.prepare(`SELECT c.photo_id, c.embedding FROM photo_clip c
			WHERE (SELECT count(*) FROM photo_tags t WHERE t.photo_id = c.photo_id) < ?`);
		q.bind(1, cast(long) tagGroups.length);
		long[] ids;
		float[clipDim][] embs;
		while (q.step())
		{
			auto b = q.getBlob(0 + 1);
			if (b.length != clipDim * float.sizeof)
				continue;
			float[clipDim] e;
			e[] = (cast(const(float)[]) b)[];
			ids ~= q.getLong(0);
			embs ~= e;
		}
		if (!ids.length)
			return 0;
		db.transaction!void({
			foreach (i, id; ids)
				tagAuto(id, embs[i]);
		});
		return ids.length;
	}

	// ---- the API -------------------------------------------------------------------

	/// `{scene: [names], mood: [names], weather: [names], holiday: [names]}` — the vocabulary the user can pick from.
	JSONValue labels()
	{
		JSONValue out_ = JSONValue.emptyObject;
		foreach (g; tagGroups)
			out_[g] = JSONValue(cast(JSONValue[]) []);
		foreach (ref l; vocab)
			if (!l.nothing)
				out_[l.group].array ~= JSONValue(l.name);
		return out_;
	}

	/// `{scene: [{tag, count, cover}], mood: […], weather: […], holiday: […], available}`, most photos first.
	JSONValue list(bool inline = false)
	{
		JSONValue groupList(string group)
		{
			auto s = db.prepare(`SELECT t.tag, count(*),
				(SELECT p.thumb_hash FROM photo_tags t2 JOIN photos p ON p.id = t2.photo_id
				 WHERE t2.grp = t.grp AND t2.tag = t.tag AND p.thumb_hash IS NOT NULL ORDER BY p.taken_ts DESC, p.id DESC LIMIT 1)
				FROM photo_tags t WHERE t.grp = ? AND t.tag <> '' GROUP BY t.tag ORDER BY 2 DESC, 1`);
			s.bind(1, group);
			JSONValue[] out_;
			while (s.step())
			{
				JSONValue j = JSONValue.emptyObject;
				j["tag"] = s.getString(0);
				j["count"] = s.getLong(1);
				j["cover"] = coverUrl(s.isNull(2) ? null : s.getString(2), inline);
				out_ ~= j;
			}
			return JSONValue(out_);
		}

		JSONValue out_ = JSONValue.emptyObject;
		foreach (g; tagGroups)
			out_[g] = groupList(g);
		out_["available"] = available;
		return out_;
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

	/// `{scene, mood, weather, holiday, by: {group: auto|date|user}, scores: {group: [{tag, prob}] ×3}}` for one photo.
	JSONValue photoTags(long id)
	{
		JSONValue out_ = JSONValue.emptyObject;
		JSONValue by = JSONValue.emptyObject;
		foreach (g; tagGroups)
			out_[g] = JSONValue(null);
		auto s = db.prepare("SELECT grp, tag, tag_by FROM photo_tags WHERE photo_id = ?");
		s.bind(1, id);
		while (s.step())
		{
			immutable tag = s.getString(1);
			out_[s.getString(0)] = tag.length ? JSONValue(tag) : JSONValue(null);
			by[s.getString(0)] = s.getString(2);
		}
		out_["by"] = by;
		JSONValue scores = JSONValue.emptyObject;
		float[clipDim] emb;
		if (loadEmbedding(id, emb) && !isZero(emb))
			foreach (group; tagGroups)
			{
				auto sc = score(vocab, emb, group);
				JSONValue[] arr;
				foreach (i, name; sc.top)
					arr ~= JSONValue(["tag": JSONValue(name), "prob": JSONValue(sc.probs[i])]);
				scores[group] = JSONValue(arr);
			}
		out_["scores"] = scores;
		return out_;
	}

	/// The user's word on a group for these photos; `tag` empty = nothing in particular.
	void setTag(long[] ids, string group, string tag)
	{
		import std.algorithm : canFind;
		if (!tagGroups.canFind(group))
			throw new Exception("group must be one of scene, mood, weather, holiday");
		tag = tag.strip;
		if (tag.length)
		{
			bool known;
			foreach (ref l; vocab)
				if (l.group == group && !l.nothing && l.name == tag)
					known = true;
			if (!known)
				throw new Exception("unknown " ~ group ~ " tag: " ~ tag);
		}
		db.transaction!void({
			auto u = db.prepare(`INSERT INTO photo_tags (photo_id, grp, tag, score, tag_by) VALUES (?, ?, ?, 1, 'user')
				ON CONFLICT(photo_id, grp) DO UPDATE SET tag = excluded.tag, score = 1, tag_by = 'user'`);
			foreach (id; ids)
			{
				u.reset();
				u.bind(1, id).bind(2, group).bind(3, tag is null ? "" : tag);
				u.run();
			}
		});
		if (events !is null)
			events.emit("tags.changed", JSONValue.emptyObject);
	}
}

unittest
{
	// a toy vocabulary in 512-d: four labels along four axes
	Label a, n, b, c;
	a.group = n.group = b.group = c.group = "scene";
	a.name = "Beach";
	n.name = "None";
	n.nothing = true;   // (parseVocabulary marks the first of a group; here by hand)
	b.name = "Snow";
	c.name = "Pool";
	a.embedding[] = 0;
	n.embedding[] = 0;
	b.embedding[] = 0;
	c.embedding[] = 0;
	a.embedding[0] = 1;
	n.embedding[1] = 1;
	b.embedding[2] = 1;
	c.embedding[3] = 1;
	auto vocab = [a, n, b, c];
	float[clipDim] e = 0;
	e[0] = 0.9;
	e[2] = 0.3;
	auto s = score(vocab, e, "scene");
	assert(s.tag == "Beach" && s.top[0] == "Beach" && s.top[1] == "Snow");
	e[] = 0;
	e[1] = 1;
	assert(score(vocab, e, "scene").tag == "");     // "nothing in particular" wins → no tag
	e[] = 0;
	e[0] = e[1] = e[2] = e[3] = 0.02;
	assert(score(vocab, e, "scene").tag == "");     // a four-way tie: nobody has 30 %
	assert(score(vocab, e, "mood").tag == "");      // no labels in that group
	auto v = parseVocabulary("scene\tNone\t" ~ "0.1 ".repeatStr(clipDim) ~ "\nscene\tX\t" ~ "0 ".repeatStr(clipDim) ~ "\nbad\tline\n");
	assert(v.length == 2 && v[0].nothing && !v[1].nothing);   // the first label of a group is its "nothing"
}

version (unittest) private string repeatStr(string s, size_t n)
{
	string out_;
	foreach (i; 0 .. n)
		out_ ~= s;
	return out_;
}
