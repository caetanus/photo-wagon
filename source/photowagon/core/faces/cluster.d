/// Grouping faces into people.
///
/// Each person is a centroid (the mean of its faces' unit embeddings). A new
/// face joins the person whose centroid is closest when the cosine clears
/// `joinThreshold`, otherwise it starts a person. After a scan, persons whose
/// centroids are closer than `mergeThreshold` are merged. Faces that are too
/// small or too uncertain never take part: their embeddings are noise and were
/// what chained different people together (measured on a real library:
/// nearest-neighbour joining at SFace's 0.363 put babies, a bearded man and a
/// teapot in one person; centroids at 0.45 with a size gate did not).
///
/// The vectors live in SQLite: `person_centroid` keeps each person's running sum
/// and count, `person_vec` (sqlite-vec) the unit centroid, and every "closest
/// person" question is a KNN query. Nothing is held in memory between calls.
module photowagon.core.faces.cluster;

import std.math : sqrt;

import photowagon.core.db.sqlite : Database;

/// Centroid cosine needed to join an existing person.
enum joinThreshold = 0.45f;
/// Centroid cosine at which two persons are the same one. Siblings measured
/// at 0.72 on a real library, so this stays well above that.
enum mergeThreshold = 0.75f;
/// A face narrower than this (pixels of the original) or less confident than
/// `minScore` is stored but not clustered.
enum minFaceWidth = 48;
enum minScore = 0.8f;
/// Detections below this confidence are not even stored (mostly not faces).
enum keepScore = 0.75f;
/// When the two closest persons are this close to each other, nobody is
/// chosen: the face stays unassigned for the user rather than guessed.
enum minMargin = 0.05f;
/// Bump when the rule changes: libraries clustered by an older rule are redone.
enum clusterVersion = 5;

bool eligible(float widthPx, float score) pure nothrow @nogc
{
	return widthPx >= minFaceWidth && score >= minScore;
}

float[128] unit(const ref float[128] e) pure nothrow @nogc
{
	float[128] u = e;
	float n = 0;
	foreach (v; u)
		n += v * v;
	n = sqrt(n);
	if (n > 1e-9)
		u[] /= n;
	return u;
}

float dot(const ref float[128] a, const ref float[128] b) pure nothrow @nogc
{
	float s = 0;
	foreach (i; 0 .. 128)
		s += a[i] * b[i];
	return s;
}

/// A face the split works on: id, embedding, and where it ends up.
struct SplitFace
{
	long id;
	float[128] embedding;
	bool moves;
}

/// Two persons look alike (siblings): the user just said face `seed` belongs
/// to B, not A. Decide for every other face of A whether it follows: a face
/// moves when it is closer to B's centroid than to A's and clears
/// `joinThreshold` towards B. B starts as the seed (plus what B already
/// held); a few rounds let both centroids settle. Returns the ids that move.
long[] splitTowards(SplitFace[] facesOfA, const(float[128])[] alreadyInB, const ref float[128] seed)
{
	float[128] sumA = 0, sumB = unit(seed);
	uint nB = 1;
	foreach (ref e; alreadyInB)
	{
		auto u = unit(e);
		sumB[] += u[];
		nB++;
	}
	foreach (ref f; facesOfA)
	{
		f.moves = false;
		auto u = unit(f.embedding);
		sumA[] += u[];
	}
	foreach (round; 0 .. 4)
	{
		auto mA = unit(sumA);
		auto mB = unit(sumB);
		float[128] newA = 0, newB = 0;
		// B keeps its seed and prior members
		newB[] += unit(seed)[];
		foreach (ref e; alreadyInB)
			newB[] += unit(e)[];
		foreach (ref f; facesOfA)
		{
			auto u = unit(f.embedding);
			immutable a = dot(mA, u), b = dot(mB, u);
			f.moves = b > a && b >= joinThreshold;
			if (f.moves)
				newB[] += u[];
			else
				newA[] += u[];
		}
		sumA = newA;
		sumB = newB;
	}
	long[] out_;
	foreach (ref f; facesOfA)
		if (f.moves)
			out_ ~= f.id;
	return out_;
}

/// The persons' centroids, in the database. A new index starts empty (the
/// service rebuilds it from the stored faces); every question is a query.
final class ClusterIndex
{
	private Database db;

	this(Database db)
	{
		this.db = db;
		db.exec("DELETE FROM person_vec");
		db.exec("DELETE FROM person_centroid");
	}

	private struct Row
	{
		bool found;
		float[128] sum = 0;
		uint count;
		bool named;
	}

	private Row load(long personId)
	{
		Row r;
		auto s = db.prepare("SELECT sum, count, named FROM person_centroid WHERE person_id = ?");
		s.bind(1, personId);
		if (!s.step())
			return r;
		auto blob = s.getBlob(0);
		if (blob.length == 128 * float.sizeof)
			r.sum[] = (cast(const(float)[]) blob)[];
		r.count = cast(uint) s.getLong(1);
		r.named = s.getLong(2) != 0;
		r.found = true;
		return r;
	}

	private void save(long personId, const ref Row r)
	{
		auto u = db.prepare(`INSERT INTO person_centroid (person_id, sum, count, named) VALUES (?, ?, ?, ?)
			ON CONFLICT(person_id) DO UPDATE SET sum = excluded.sum, count = excluded.count, named = excluded.named`);
		u.bind(1, personId).bind(2, cast(const(ubyte)[]) r.sum[]).bind(3, cast(long) r.count).bind(4, cast(long)(r.named ? 1 : 0));
		u.run();
		auto d = db.prepare("DELETE FROM person_vec WHERE person_id = ?");
		d.bind(1, personId);
		d.run();
		if (r.count == 0)
			return;
		auto m = unit(r.sum);
		float n = 0;
		foreach (v; m)
			n += v * v;
		if (n < 1e-6)
			return; // a zero centroid has no direction; it cannot be matched
		auto i = db.prepare("INSERT INTO person_vec (person_id, centroid) VALUES (?, ?)");
		i.bind(1, personId).bind(2, cast(const(ubyte)[]) m[]);
		i.run();
	}

	private void drop(long personId)
	{
		auto d = db.prepare("DELETE FROM person_vec WHERE person_id = ?");
		d.bind(1, personId);
		d.run();
		auto c = db.prepare("DELETE FROM person_centroid WHERE person_id = ?");
		c.bind(1, personId);
		c.run();
	}

	/// The `k` persons closest to `e` (unit), closest first, as (id, cosine).
	private struct Hit
	{
		long personId;
		float cosine;
	}

	private Hit[] nearest(const ref float[128] e, long k)
	{
		Hit[] out_;
		if (k <= 0)
			return out_;
		auto s = db.prepare("SELECT person_id, distance FROM person_vec WHERE centroid MATCH ? AND k = ? ORDER BY distance");
		s.bind(1, cast(const(ubyte)[]) e[]).bind(2, k);
		while (s.step())
			out_ ~= Hit(s.getLong(0), 1 - cast(float) s.getDouble(1));
		return out_;
	}

	void add(long personId, const ref float[128] embedding, bool named = false)
	{
		auto u = unit(embedding);
		auto r = load(personId);
		r.sum[] += u[];
		r.count++;
		r.named |= named;
		save(personId, r);
	}

	void setNamed(long personId, bool named)
	{
		auto s = db.prepare("UPDATE person_centroid SET named = ? WHERE person_id = ?");
		s.bind(1, cast(long)(named ? 1 : 0)).bind(2, personId);
		s.run();
	}

	/// The closest person, and how close; 0 when nobody clears the threshold.
	/// `taken` lists persons that cannot be the answer: the ones already found
	/// in the same photo, since nobody appears twice in one picture.
	long match(const ref float[128] embedding, out float best, const(long)[] taken = null)
	{
		bool ambiguous;
		return match(embedding, best, ambiguous, taken);
	}

	/// Same, reporting when the runner-up was too close to call (then 0 is
	/// returned and `ambiguous` is true: leave the face unassigned).
	long match(const ref float[128] embedding, out float best, out bool ambiguous, const(long)[] taken = null)
	{
		import std.algorithm : canFind;

		best = -1;
		float second = -1;
		long person;
		auto u = unit(embedding);
		foreach (h; nearest(u, cast(long) taken.length + 3))
		{
			if (taken.canFind(h.personId))
				continue;
			if (h.cosine > best)
			{
				second = best;
				best = h.cosine;
				person = h.personId;
			}
			else if (h.cosine > second)
				second = h.cosine;
		}
		ambiguous = best >= joinThreshold && second >= joinThreshold && best - second < minMargin;
		if (ambiguous)
			return 0;
		return best >= joinThreshold ? person : 0;
	}

	/// Pairs (from, into) to merge: centroids closer than `mergeThreshold`.
	/// Never two named persons, never two persons `apart` says share a photo;
	/// the smaller (or the unnamed) one goes into the other.
	long[2][] mergeCandidates(scope bool delegate(long, long) apart = null)
	{
		long[2][] out_;
		bool[long] gone;
		struct P
		{
			long id;
			uint count;
			bool named;
		}

		P[] persons;
		{
			auto s = db.prepare("SELECT person_id, count, named FROM person_centroid WHERE count > 0 ORDER BY person_id");
			while (s.step())
				persons ~= P(s.getLong(0), cast(uint) s.getLong(1), s.getLong(2) != 0);
		}
		uint[long] countOf;
		bool[long] namedOf;
		foreach (p; persons)
		{
			countOf[p.id] = p.count;
			namedOf[p.id] = p.named;
		}
		foreach (p; persons)
		{
			if (p.id in gone)
				continue;
			auto me = load(p.id);
			auto m = unit(me.sum);
			bool dropped;
			foreach (h; nearest(m, 6))
			{
				if (h.personId == p.id || h.personId in gone || h.personId !in countOf)
					continue;
				if (h.cosine < mergeThreshold)
					break;
				if (p.named && namedOf[h.personId])
					continue;
				if (apart !is null && apart(p.id, h.personId))
					continue;
				// keep the named one; else the bigger one
				long keep = p.id, drop = h.personId;
				if (namedOf[h.personId] || (!p.named && countOf[h.personId] > p.count))
				{
					keep = h.personId;
					drop = p.id;
				}
				out_ ~= [drop, keep];
				gone[drop] = true;
				if (drop == p.id)
				{
					dropped = true;
					break;
				}
			}
		}
		return out_;
	}

	/// Every person ranked by how close its centroid is to `embedding`, closest first
	/// (at most `limit`): who a face most likely is, for the naming popup.
	long[] rankFor(const ref float[128] embedding, out float[] scores, size_t limit = 8)
	{
		auto e = unit(embedding);
		long[] ids;
		float[] sims;
		foreach (h; nearest(e, cast(long) limit))
		{
			ids ~= h.personId;
			sims ~= h.cosine;
		}
		scores = sims;
		return ids;
	}

	/// Persons whose centroid is at least `threshold` close to `personId`'s, closest first.
	long[] similarTo(long personId, float threshold, out float[] scores)
	{
		auto me = load(personId);
		if (!me.found || me.count == 0)
			return null;
		auto m = unit(me.sum);
		long[] ids;
		float[] sims;
		foreach (h; nearest(m, cast(long) personCount() + 1))
		{
			if (h.personId == personId)
				continue;
			if (h.cosine < threshold)
				break;
			ids ~= h.personId;
			sims ~= h.cosine;
		}
		scores = sims;
		return ids;
	}

	/// Applies a merge that the repo performed.
	void merge(long from, long into)
	{
		auto f = load(from);
		auto t = load(into);
		if (!f.found || !t.found)
			return;
		t.sum[] += f.sum[];
		t.count += f.count;
		t.named |= f.named;
		save(into, t);
		drop(from);
	}

	/// Drops a face's contribution when the user moves it elsewhere.
	void remove(long personId, const ref float[128] embedding)
	{
		auto r = load(personId);
		if (!r.found)
			return;
		auto u = unit(embedding);
		r.sum[] -= u[];
		if (r.count)
			r.count--;
		save(personId, r);
	}

	size_t length()
	{
		auto s = db.prepare("SELECT coalesce(sum(count), 0) FROM person_centroid");
		return s.step() ? cast(size_t) s.getLong(0) : 0;
	}

	size_t personCount()
	{
		auto s = db.prepare("SELECT count(*) FROM person_centroid");
		return s.step() ? cast(size_t) s.getLong(0) : 0;
	}
}

version (unittest) private Database testDb()
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	migrate(db);
	// the persons the centroids refer to
	db.exec("INSERT INTO persons (id, name, created_at) VALUES (10, NULL, 0), (11, NULL, 0), (12, NULL, 0)");
	return db;
}

unittest
{
	auto db = testDb();
	scope (exit)
		db.close();
	auto idx = new ClusterIndex(db);
	float[128] a = 0, b = 0, c = 0;
	a[0] = 1;
	b[0] = 0.9;
	b[1] = 0.1;
	c[5] = 1;
	idx.add(10, a);
	float best;
	assert(idx.match(b, best) == 10 && best > 0.9);
	assert(idx.match(c, best) == 0);
	assert(idx.match(b, best, [10L]) == 0); // 10 is taken in this photo
	idx.add(11, c);
	{
		// halfway between two persons: too close to call
		float[128] mid = 0;
		mid[0] = 1;
		mid[5] = 1;
		bool amb;
		assert(idx.match(mid, best, amb) == 0 && amb);
	}
	float[128] d = 0;
	d[5] = 0.95;
	d[0] = 0.3; // close to c, far from a
	idx.add(12, d);
	auto m = idx.mergeCandidates();
	assert(m.length == 1 && (m[0][1] == 11 || m[0][1] == 12));
	idx.merge(m[0][0], m[0][1]);
	assert(idx.personCount == 2);
	assert(idx.length == 3);
	float[] scores;
	auto ranked = idx.rankFor(b, scores, 5);
	assert(ranked.length == 2 && ranked[0] == 10 && scores[0] > 0.9);
	idx.remove(10, a);
	assert(idx.length == 2 && idx.match(b, best) == 0);   // person 10 has no faces left
	assert(eligible(100, 0.9) && !eligible(20, 0.9) && !eligible(100, 0.5));
}

unittest
{
	// two look-alikes: A around axis 0, B around axis 0 tilted towards axis 1
	import std.random : Random, uniform;

	auto rng = Random(7);
	SplitFace[] a;
	float[128] seed = 0;
	foreach (i; 0 .. 40)
	{
		SplitFace f;
		f.id = i + 1;
		f.embedding = 0;
		immutable isB = i % 2 == 1;
		f.embedding[0] = 1;
		f.embedding[1] = isB ? 0.7 : 0.05;
		f.embedding[2] = uniform(-0.15f, 0.15f, rng);
		f.embedding[3] = isB ? uniform(-0.1f, 0.1f, rng) : 0;
		a ~= f;
	}
	seed[0] = 1;
	seed[1] = 0.75;
	auto moved = splitTowards(a, [], seed);
	assert(moved.length == 20, "expected the 20 look-alikes to move");
	foreach (id; moved)
		assert(id % 2 == 0);
}
