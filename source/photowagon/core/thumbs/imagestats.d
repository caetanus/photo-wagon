/// What a picture looks like, statistically — the signals the kind classifier uses
/// to tell a photograph from a screenshot or a meme. Pure D over interleaved 8-bit
/// pixels, no libvips, so the phone (which decodes with Qt) can compute it too.
module photowagon.core.thumbs.imagestats;

struct ImageStats
{
	bool ok;
	/// share of pixels in the most common colour (4 bits per channel)
	float dominantFraction;
	/// distinct colours (4 bits per channel) as a share of the pixel count
	float uniqueFraction;
	/// mean HSV-style saturation 0..1
	float meanSaturation;
	/// share of horizontal neighbours whose luminance differs by more than 32
	float edgeDensity;
	/// share of near-white and near-black pixels
	float lightFraction;
	float darkFraction;
	/// share of horizontal neighbours that are exactly the same colour (8-bit),
	/// measured at 256 px: flat digital areas, which photographs rarely have
	float flatFraction;
}

/// The numbers behind `imageStats`, on interleaved 8-bit pixels.
ImageStats statsOf(const(ubyte)[] px, int w, int h, int bands) pure nothrow
{
	ImageStats r;
	immutable n = cast(size_t) w * h;
	if (n == 0 || bands < 1 || px.length < n * bands)
		return r;
	uint[4096] bins;
	double sat = 0;
	size_t light, dark, edges, pairs, flat;
	foreach (y; 0 .. h)
		foreach (x; 0 .. w)
		{
			immutable i = (y * w + x) * bands;
			immutable cr = px[i], cg = bands > 1 ? px[i + 1] : px[i], cb = bands > 2 ? px[i + 2] : px[i];
			bins[(cr >> 4) << 8 | (cg >> 4) << 4 | (cb >> 4)]++;
			immutable mx = cr > cg ? (cr > cb ? cr : cb) : (cg > cb ? cg : cb);
			immutable mn = cr < cg ? (cr < cb ? cr : cb) : (cg < cb ? cg : cb);
			if (mx > 0)
				sat += cast(double)(mx - mn) / mx;
			if (mn >= 235)
				light++;
			if (mx <= 20)
				dark++;
			if (x + 1 < w)
			{
				immutable j = i + bands;
				immutable l1 = (cr * 299 + cg * 587 + cb * 114) / 1000;
				immutable l2 = (px[j] * 299 + (bands > 1 ? px[j + 1] : px[j]) * 587 + (bands > 2 ? px[j + 2] : px[j]) * 114) / 1000;
				if ((l1 > l2 ? l1 - l2 : l2 - l1) > 32)
					edges++;
				if (px[j] == cr && (bands < 2 || px[j + 1] == cg) && (bands < 3 || px[j + 2] == cb))
					flat++;
				pairs++;
			}
		}
	uint top;
	size_t unique;
	foreach (c; bins)
	{
		if (c > top)
			top = c;
		if (c > 0)
			unique++;
	}
	r.ok = true;
	r.dominantFraction = cast(float) top / n;
	r.uniqueFraction = cast(float) unique / n;
	r.meanSaturation = cast(float)(sat / n);
	r.edgeDensity = pairs ? cast(float) edges / pairs : 0;
	r.flatFraction = pairs ? cast(float) flat / pairs : 0;
	r.lightFraction = cast(float) light / n;
	r.darkFraction = cast(float) dark / n;
	return r;
}

unittest
{
	// a flat white image: one colour, no edges
	auto white = new ubyte[16 * 16 * 3];
	white[] = 255;
	auto s = statsOf(white, 16, 16, 3);
	assert(s.ok && s.dominantFraction == 1 && s.edgeDensity == 0 && s.lightFraction == 1 && s.flatFraction == 1);
	// noise: many colours, many edges
	auto noise = new ubyte[16 * 16 * 3];
	foreach (i, ref b; noise)
		b = cast(ubyte)((i * 7919) % 251);
	auto t = statsOf(noise, 16, 16, 3);
	assert(t.dominantFraction < 0.2 && t.uniqueFraction > 0.1 && t.edgeDensity > 0.3);
}
