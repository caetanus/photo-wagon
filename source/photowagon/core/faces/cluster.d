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
/// Centroid cosine at which two persons are the same one.
enum mergeThreshold = 0.55f;
/// A face narrower than this (pixels of the original) or less confident than
/// `minScore` is stored but not clustered.
enum minFaceWidth = 48;
enum minScore = 0.8f;
/// Bump when the rule changes: libraries clustered by an older rule are redone.
enum clusterVersion = 2;

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
	long match(const ref float[128] embedding, out float best) const
	{
		best = -1;
		long person;
		auto u = unit(embedding);
		foreach (ref c; persons)
		{
			auto m = c.mean();
			immutable s = dot(m, u);
			if (s > best)
			{
				best = s;
				person = c.personId;
			}
		}
		return best >= joinThreshold ? person : 0;
	}

	/// Pairs (from, into) to merge: centroids closer than `mergeThreshold`.
	/// Never two named persons; the smaller (or the unnamed) one goes into the other.
	long[2][] mergeCandidates() const
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
	idx.add(11, c);
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
