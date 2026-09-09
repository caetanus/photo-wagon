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
module photowagon.core.faces.cluster;

import std.math : sqrt;

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

struct Centroid
{
	long personId;
	float[128] sum = 0;
	uint count;
	bool named; // a named person is never merged away automatically

	float[128] mean() const pure nothrow @nogc
	{
		float[128] m = sum;
		float n = 0;
		foreach (v; m)
			n += v * v;
		n = sqrt(n);
		if (n > 1e-9)
			m[] /= n;
		return m;
	}
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
		float[128] newA = 0, newB = sumB;
		newB = 0;
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

final class ClusterIndex
{
	private Centroid[] persons;
	private size_t[long] byId;

	void add(long personId, const ref float[128] embedding, bool named = false)
	{
		auto u = unit(embedding);
		if (auto i = personId in byId)
		{
			persons[*i].sum[] += u[];
			persons[*i].count++;
			persons[*i].named |= named;
			return;
		}
		Centroid c;
		c.personId = personId;
		c.sum = u;
		c.count = 1;
		c.named = named;
		byId[personId] = persons.length;
		persons ~= c;
	}

	void setNamed(long personId, bool named)
	{
		if (auto i = personId in byId)
			persons[*i].named = named;
	}

	/// The closest person, and how close; 0 when nobody clears the threshold.
	/// `taken` lists persons that cannot be the answer: the ones already found
	/// in the same photo, since nobody appears twice in one picture.
	long match(const ref float[128] embedding, out float best, const(long)[] taken = null) const
	{
		bool ambiguous;
		return match(embedding, best, ambiguous, taken);
	}

	/// Same, reporting when the runner-up was too close to call (then 0 is
	/// returned and `ambiguous` is true: leave the face unassigned).
	long match(const ref float[128] embedding, out float best, out bool ambiguous, const(long)[] taken = null) const
	{
		import std.algorithm : canFind;

		best = -1;
		float second = -1;
		long person;
		auto u = unit(embedding);
		foreach (ref c; persons)
		{
			if (c.count == 0 || taken.canFind(c.personId))
				continue;
			auto m = c.mean();
			immutable s = dot(m, u);
			if (s > best)
			{
				second = best;
				best = s;
				person = c.personId;
			}
			else if (s > second)
				second = s;
		}
		ambiguous = best >= joinThreshold && second >= joinThreshold && best - second < minMargin;
		if (ambiguous)
			return 0;
		return best >= joinThreshold ? person : 0;
	}

	/// Pairs (from, into) to merge: centroids closer than `mergeThreshold`.
	/// Never two named persons, never two persons `apart` says share a photo;
	/// the smaller (or the unnamed) one goes into the other.
	long[2][] mergeCandidates(scope bool delegate(long, long) apart = null) const
	{
		long[2][] out_;
		bool[long] gone;
		auto means = new float[128][](persons.length);
		foreach (i, ref c; persons)
			means[i] = c.mean();
		foreach (i; 0 .. persons.length)
		{
			if (persons[i].personId in gone)
				continue;
			foreach (j; i + 1 .. persons.length)
			{
				if (persons[j].personId in gone)
					continue;
				if (persons[i].named && persons[j].named)
					continue;
				if (dot(means[i], means[j]) < mergeThreshold)
					continue;
				if (apart !is null && apart(persons[i].personId, persons[j].personId))
					continue;
				// keep the named one; else the bigger one
				size_t keep = i, drop = j;
				if (persons[j].named || (!persons[i].named && persons[j].count > persons[i].count))
				{
					keep = j;
					drop = i;
				}
				out_ ~= [persons[drop].personId, persons[keep].personId];
				gone[persons[drop].personId] = true;
				if (drop == i)
					break;
			}
		}
		return out_;
	}

	/// Applies a merge that the repo performed.
	void merge(long from, long into)
	{
		auto f = from in byId;
		auto t = into in byId;
		if (f is null || t is null)
			return;
		persons[*t].sum[] += persons[*f].sum[];
		persons[*t].count += persons[*f].count;
		persons[*t].named |= persons[*f].named;
		persons[*f].count = 0;
		persons[*f].sum = 0;
		byId.remove(from);
	}

	/// Drops a face's contribution when the user moves it elsewhere.
	void remove(long personId, const ref float[128] embedding)
	{
		if (auto i = personId in byId)
		{
			auto u = unit(embedding);
			persons[*i].sum[] -= u[];
			if (persons[*i].count)
				persons[*i].count--;
		}
	}

	size_t length() const
	{
		size_t n;
		foreach (ref c; persons)
			n += c.count;
		return n;
	}

	size_t personCount() const
	{
		return byId.length;
	}
}

unittest
{
	auto idx = new ClusterIndex;
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
