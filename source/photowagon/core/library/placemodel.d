/// Recognising a place by how it looks, not by GPS (which the library almost never has).
///
/// The user names a place on a few photos ("Set Place…", stored with place_by='user').
/// Those become the model's examples. For every other photo that has a CLIP embedding,
/// this asks its nearest neighbours in CLIP space — a vote of the visually most similar
/// pictures — and, when enough of them are the user's examples of one place and they win
/// clearly, gives the photo that place (written place_by='visual', so it never trains the
/// model and the user can always overrule it). No location data is needed: it learns the
/// look of "home", "the office", "grandma's" from what the user confirms, and gets better
/// as more are confirmed.
module photowagon.core.library.placemodel;

import core.time : MonoTime;
import std.json;

import vibe.core.core : runTask;
import vibe.core.log : logInfo, logWarn;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.events : Events;
import photowagon.core.jobs.scheduler : jobs, Priority;

enum clipDim = 512;

// CLIP cosine is fuzzier than a face embedding, so lean conservative: a place is
// spread only on strong, agreeing similarity, and never onto a photo the user placed.
enum placeVoteMin = 0.72f;    // a neighbour below this does not count as a vote
enum placeVoteStrong = 0.82f; // a single neighbour this close is enough on its own
enum placeVoteMargin = 1.20f; // the winning place must beat the runner-up by this ratio
enum placeVoteK = 25;         // how many nearest photos to consult

final class PlaceModel
{
	private Database db;
	private Events events;
	private FiberGroup fibers;
	private bool running, again;

	this(Database db, Events events)
	{
		this.db = db;
		this.events = events;
		fibers = new FiberGroup((Exception e) nothrow {
			try
				logWarn("places: model failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	/// Spread the user's places over the look-alike photos. Cheap to call often;
	/// a call while running queues one more pass (a new example just landed).
	void start()
	{
		if (running)
		{
			again = true;
			return;
		}
		running = true;
		fibers.spawn(() {
			scope (exit)
				running = false;
			do
			{
				again = false;
				jobs.pass(Priority.scenes, "recognising places", &run);
			}
			while (again);
		});
	}

	/// The user just named (or un-named) a place: forget our own guesses so every photo is
	/// reconsidered against the new set of examples, then run a fresh pass.
	void relearn()
	{
		try
			db.exec("UPDATE photos SET place = NULL, country = NULL, place_by = NULL " ~
				"WHERE place_by = 'visual' OR place_by = 'vismiss'");
		catch (Exception e)
			logWarn("places: relearn reset failed: %s", e.msg);
		start();
	}

	void close() nothrow
	{
		fibers.stopAll();
	}

	private struct Example
	{
		string place;
		string country;
	}

	private void run()
	{
		// the examples: places the user set by hand, by photo id
		Example[long] examples;
		{
			auto s = db.prepare("SELECT id, place, country FROM photos WHERE place_by = 'user' AND place IS NOT NULL AND place != ''");
			while (s.step())
				examples[s.getLong(0)] = Example(s.getString(1), s.getString(2));
		}
		if (examples.length == 0)
			return; // nothing to learn from yet

		// candidates: photos with an embedding that have NOT been looked at yet (place_by is
		// NULL). A photo we already judged is marked — 'visual' when matched, 'vismiss' when
		// not — so a later pass is O(new photos), not O(whole library). `relearn()` clears
		// those marks when the user adds an example, so everything is reconsidered then.
		long[] candidates;
		{
			auto s = db.prepare(`SELECT v.photo_id FROM photo_vec v JOIN photos p ON p.id = v.photo_id
				WHERE p.place_by IS NULL`);
			while (s.step())
				candidates ~= s.getLong(0);
		}
		if (candidates.length == 0)
			return;

		logInfo("places: recognising over %s photos from %s examples", candidates.length, examples.length);
		auto started = MonoTime.currTime;
		auto readEmb = db.prepare("SELECT embedding FROM photo_vec WHERE photo_id = ?");
		auto knn = db.prepare("SELECT photo_id, distance FROM photo_vec WHERE embedding MATCH ? AND k = ? ORDER BY distance");
		auto upd = db.prepare("UPDATE photos SET place = ?, country = ?, place_by = 'visual' WHERE id = ?");
		auto miss = db.prepare("UPDATE photos SET place_by = 'vismiss' WHERE id = ? AND place_by IS NULL");
		long changed;

		// One photo's decision: the nearest-neighbour vote and, if it wins, the write.
		// No long-held transaction — each guess autocommits, so a foreground write
		// (a sync import) is never blocked behind the whole pass.
		bool processOne(long id)
		{
			readEmb.reset();
			readEmb.bind(1, id);
			if (!readEmb.step())
				return false;
			auto emb = readEmb.getBlob(0);
			if (emb.length != clipDim * float.sizeof)
				return false;

			// mark it seen up front, so it is not reconsidered every pass; a real match
			// overwrites this with the place below.
			miss.reset();
			miss.bind(1, id);
			miss.run();

			// vote by place-key over the nearest examples
			float[string] score;
			uint[string] cnt;
			float[string] best;
			string[string] countryOf;
			knn.reset();
			knn.bind(1, emb).bind(2, cast(long) placeVoteK + 1);
			while (knn.step())
			{
				immutable nid = knn.getLong(0);
				if (nid == id)
					continue;
				immutable cos = 1 - cast(float) knn.getDouble(1);
				if (cos < placeVoteMin)
					break; // sorted closest-first
				auto ex = nid in examples;
				if (ex is null)
					continue;
				immutable key = ex.place ~ "\x01" ~ ex.country;
				score[key] += cos;
				cnt[key]++;
				if (cos > best.get(key, 0f))
					best[key] = cos;
				countryOf[key] = ex.country;
			}

			// the winning place, if it has support and beats the runner-up clearly
			string topKey, secondKey;
			float topScore = 0, secondScore = 0;
			foreach (key, sc; score)
			{
				if (!(cnt[key] >= 2 || best[key] >= placeVoteStrong))
					continue;
				if (sc > topScore)
				{
					secondKey = topKey;
					secondScore = topScore;
					topKey = key;
					topScore = sc;
				}
				else if (sc > secondScore)
				{
					secondKey = key;
					secondScore = sc;
				}
			}
			if (topKey.length == 0)
				return false;
			if (secondKey.length && topScore < secondScore * placeVoteMargin)
				return false; // two places equally likely: leave it

			import std.string : indexOf;

			immutable sep = topKey.indexOf('\x01');
			immutable place = topKey[0 .. sep];
			immutable country = countryOf[topKey];

			upd.reset();
			upd.bind(1, place).bind(2, country.length ? country : null).bind(3, id);
			upd.run();
			return true;
		}

		foreach (id; candidates)
		{
			// through the scheduler's background gate: it steps aside for the user's and
			// the phone's requests, and yields the event loop between photos.
			if (jobs.background({ return processOne(id); }))
				changed++;
		}

		immutable secs = (MonoTime.currTime - started).total!"msecs" / 1000.0;
		logInfo("places: recognised %s photos in %.1fs", changed, secs);
		if (changed)
			events.emit("places.changed", JSONValue.emptyObject);
	}
}
