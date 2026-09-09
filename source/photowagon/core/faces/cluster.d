/// Grouping faces into people: a new face joins the person of its nearest
/// known face when the cosine similarity clears SFace's threshold, otherwise it
/// starts a person of its own. Pure D over an in-memory table; the repo is the
/// truth and this is rebuilt from it at startup.
module photowagon.core.faces.cluster;

import photowagon.core.faces.detect : cosine, sameFaceCosine;

struct KnownFace
{
	long faceId;
	long personId;
	float[128] embedding;
}

final class ClusterIndex
{
	private KnownFace[] faces;
	float threshold = sameFaceCosine;

	void add(long faceId, long personId, const ref float[128] embedding)
	{
		faces ~= KnownFace(faceId, personId, embedding);
	}

	/// Moves every face of `from` to `into` (a merge in the repo happened).
	void reassign(long from, long into)
	{
		foreach (ref f; faces)
			if (f.personId == from)
				f.personId = into;
	}

	void setPerson(long faceId, long personId)
	{
		foreach (ref f; faces)
			if (f.faceId == faceId)
				f.personId = personId;
	}

	/// The person the embedding belongs to, or 0 when nobody is close enough.
	long match(const ref float[128] embedding, out float best) const
	{
		best = -1;
		long person;
		foreach (ref f; faces)
		{
			immutable c = cosine(f.embedding, embedding);
			if (c > best)
			{
				best = c;
				person = f.personId;
			}
		}
		return best >= threshold ? person : 0;
	}

	size_t length() const
	{
		return faces.length;
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
	idx.add(1, 10, a);
	float best;
	assert(idx.match(b, best) == 10 && best > 0.9);
	assert(idx.match(c, best) == 0);
	idx.reassign(10, 11);
	assert(idx.match(b, best) == 11);
}
