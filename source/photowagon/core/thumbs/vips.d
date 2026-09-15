/// Thumbnails through libvips, straight into the content store.
/// `makeThumbnail` is a plain function of value types: it runs on a worker.
module photowagon.core.thumbs.vips;

import std.string : fromStringz, toStringz;

import photowagon.core.store.store : storeBytes;

private extern (C) nothrow @nogc
{
	int vips_init(const char* argv0);
	void vips_concurrency_set(int n);
	void vips_cache_set_max(int max);
	void vips_cache_set_max_mem(size_t maxMem);
	void vips_cache_set_max_files(int maxFiles);
	void* vips_image_new_from_file(const char* name, ...);
	int vips_image_get_width(void* image);
	int vips_image_get_height(void* image);
	int vips_thumbnail(const char* filename, void** out_, int width, ...);
	int vips_jpegsave_buffer(void* in_, void** buf, size_t* len, ...);
	int vips_thumbnail_buffer(void* buf, size_t len, void** out_, int width, ...);
	int vips_autorot(void* in_, void** out_, ...);
	int vips_extract_area(void* in_, void** out_, int left, int top, int width, int height, ...);
	int vips_resize(void* in_, void** out_, double scale, ...);
	int vips_colourspace(void* in_, void** out_, int space, ...);
	int vips_flatten(void* in_, void** out_, ...);
	int vips_extract_band(void* in_, void** out_, int band, ...);
	int vips_cast_uchar(void* in_, void** out_, ...);
	int vips_image_get_bands(const void* image);
	void* vips_image_write_to_memory(void* in_, size_t* size);
	int vips_rot(void* in_, void** out_, int angle, ...);
	int vips_flip(void* in_, void** out_, int direction, ...);
	int vips_cast(void* in_, void** out_, int format, ...);
	int vips_linear(void* in_, void** out_, const(double)* a, const(double)* b, int n, ...);
	int vips_recomb(void* in_, void** out_, void* m, ...);
	int vips_multiply(void* left, void* right, void** out_, ...);
	int vips_sharpen(void* in_, void** out_, ...);
	void* vips_image_new_matrix_from_array(int width, int height, const(double)* array, int size);
	void* vips_image_new_from_memory_copy(const(void)* data, size_t size, int width, int height, int bands, int format);
	int vips_image_get_format(const void* image);
	int vips_copy(void* in_, void** out_, ...);
	void* vips_image_new_from_buffer(const(void)* buf, size_t len, const char* option_string, ...);
	const(char)* vips_error_buffer();
	void vips_error_clear();
	void g_object_unref(void* obj);
	void g_free(void* p);
}

void initVips(string argv0 = "photowagond")
{
	if (vips_init(argv0.toStringz) != 0)
		throw new Exception("vips_init failed: " ~ vipsError());
	// each worker fiber already runs one vips pipeline; keep vips's own pool small
	vips_concurrency_set(2);
	// vips remembers recent operations to reuse them; a photo library never asks twice,
	// and the default cache happily keeps hundreds of megabytes of decoded pictures
	vips_cache_set_max(20);
	vips_cache_set_max_mem(64 * 1024 * 1024);
	vips_cache_set_max_files(20);
}

private string vipsError()
{
	auto s = vips_error_buffer().fromStringz.idup;
	vips_error_clear();
	return s;
}

struct ThumbResult
{
	bool ok;
	/// sha256 of the JPEG written to the store
	string hash;
	int width;
	int height;
	/// dimensions of the original, as decoded (before EXIF rotation)
	int srcWidth;
	int srcHeight;
	string error;
}

/// Reads the original's dimensions, renders a thumbnail whose longest edge is
/// `size` (auto-rotated by EXIF), and stores it as JPEG under `storeRoot`.
ThumbResult makeThumbnail(string source, string storeRoot, int size)
{
	ThumbResult r;

	// header-only read for the source size
	auto src = vips_image_new_from_file(source.toStringz, null);
	if (src is null)
	{
		r.error = "cannot open: " ~ vipsError();
		return r;
	}
	r.srcWidth = vips_image_get_width(src);
	r.srcHeight = vips_image_get_height(src);
	g_object_unref(src);

	void* thumb;
	// "height" caps the other edge so `size` is the longest edge either way
	if (vips_thumbnail(source.toStringz, &thumb, size, "height".ptr, size, null) != 0)
	{
		r.error = "thumbnail: " ~ vipsError();
		return r;
	}
	scope (exit)
		g_object_unref(thumb);
	r.width = vips_image_get_width(thumb);
	r.height = vips_image_get_height(thumb);

	void* buf;
	size_t len;
	if (vips_jpegsave_buffer(thumb, &buf, &len, "Q".ptr, 84, "strip".ptr, 1, null) != 0)
	{
		r.error = "jpegsave: " ~ vipsError();
		return r;
	}
	scope (exit)
		g_free(buf);
	r.hash = storeBytes(storeRoot, (cast(ubyte*) buf)[0 .. len]);
	r.ok = true;
	return r;
}

// ---- edits ---------------------------------------------------------------------

import photowagon.core.edit.edits : Edits;

/// `source` with `edits` applied (edit/edits.d), as a JPEG whose longest edge is at
/// most `maxEdge` (0 = full size). Rotation and flips first, then the crop in the
/// rotated frame, then colour. Worker-safe. Throws on failure.
ubyte[] renderEdited(string source, Edits e, int maxEdge, int quality)
{
	import std.algorithm : max, min;
	import std.math : sqrt;

	void check(int rc, string what)
	{
		if (rc != 0)
			throw new Exception(what ~ ": " ~ vipsError());
	}

	// 1. load, EXIF-rotated; a preview shrinks while decoding
	void* img;
	if (maxEdge > 0)
	{
		// the crop can only enlarge what is shown: decode a little bigger than asked
		immutable decodeEdge = e.hasCrop() ? cast(int) min(maxEdge / max(0.15, min(e.cropW, e.cropH)), 8192.0) : maxEdge;
		check(vips_thumbnail(source.toStringz, &img, decodeEdge, "height".ptr, decodeEdge, null), "thumbnail");
	}
	else
	{
		auto raw = vips_image_new_from_file(source.toStringz, null);
		if (raw is null)
			throw new Exception("cannot open: " ~ vipsError());
		scope (exit)
			g_object_unref(raw);
		check(vips_autorot(raw, &img, null), "autorot");
	}
	void* cur = img; // the current head of the pipeline; each step replaces it
	void step(int rc, void* next, string what)
	{
		if (rc != 0)
			throw new Exception(what ~ ": " ~ vipsError());
		g_object_unref(cur);
		cur = next;
	}

	scope (exit)
		g_object_unref(cur);

	// 2. sRGB, no alpha
	{
		void* n;
		step(vips_colourspace(cur, &n, 22 /* VIPS_INTERPRETATION_sRGB */, null), n, "colourspace");
		if (vips_image_get_bands(cur) == 4)
			step(vips_flatten(cur, &n, null), n, "flatten");
	}
	// 3. geometry
	if (e.rotate % 360)
	{
		void* n;
		step(vips_rot(cur, &n, e.rotate / 90 /* VIPS_ANGLE_D90 = 1 … */, null), n, "rot");
	}
	if (e.flipH)
	{
		void* n;
		step(vips_flip(cur, &n, 0 /* horizontal */, null), n, "flip");
	}
	if (e.flipV)
	{
		void* n;
		step(vips_flip(cur, &n, 1 /* vertical */, null), n, "flip");
	}
	if (e.hasCrop())
	{
		immutable W = vips_image_get_width(cur), H = vips_image_get_height(cur);
		immutable left = max(0, cast(int)(e.cropX * W)), top = max(0, cast(int)(e.cropY * H));
		immutable w = min(cast(int)(e.cropW * W + 0.5), W - left), h = min(cast(int)(e.cropH * H + 0.5), H - top);
		if (w >= 2 && h >= 2)
		{
			void* n;
			step(vips_extract_area(cur, &n, left, top, w, h, null), n, "crop");
		}
	}
	if (maxEdge > 0)
	{
		immutable W = vips_image_get_width(cur), H = vips_image_get_height(cur);
		if (max(W, H) > maxEdge)
		{
			void* n;
			step(vips_resize(cur, &n, cast(double) maxEdge / max(W, H), null), n, "resize");
		}
	}
	// 4. colour, in float
	if (e.hasColour())
	{
		void* n;
		step(vips_cast(cur, &n, 6 /* VIPS_FORMAT_FLOAT */, null), n, "cast");
		// saturation, warmth and sepia are one 3×3 matrix: rows = output channels
		{
			immutable s = e.saturation >= 0 ? 1 + e.saturation : 1 + e.saturation; // -1 → 0 (grey), 1 → 2
			immutable lr = 0.2126, lg = 0.7152, lb = 0.0722;
			double[9] m = [
				lr + (1 - lr) * s, lg * (1 - s), lb * (1 - s),
				lr * (1 - s), lg + (1 - lg) * s, lb * (1 - s),
				lr * (1 - s), lg * (1 - s), lb + (1 - lb) * s,
			];
			// warmth: more red and a little green, less blue (and the other way round)
			immutable wr = 1 + 0.16 * e.warmth, wg = 1 + 0.04 * e.warmth, wb = 1 - 0.16 * e.warmth;
			foreach (i; 0 .. 3)
			{
				m[i] *= wr;
				m[3 + i] *= wg;
				m[6 + i] *= wb;
			}
			if (e.sepia > 0)
			{
				// blend towards the classic sepia matrix
				immutable double[9] sep = [0.393, 0.769, 0.189, 0.349, 0.686, 0.168, 0.272, 0.534, 0.131];
				foreach (i; 0 .. 9)
					m[i] = m[i] * (1 - e.sepia) + sep[i] * e.sepia;
			}
			auto mat = vips_image_new_matrix_from_array(3, 3, m.ptr, 9);
			if (mat is null)
				throw new Exception("matrix: " ~ vipsError());
			scope (exit)
				g_object_unref(mat);
			step(vips_recomb(cur, &n, mat, null), n, "recomb");
		}
		// brightness, contrast, fade: out = a·x + b
		{
			immutable c = e.contrast >= 0 ? 1 + e.contrast * 1.2 : 1 + e.contrast * 0.6;
			double a = c, b = 128 * (1 - c) + 255 * 0.45 * e.brightness;
			// fade lifts the blacks and softens the whites
			a *= 1 - 0.35 * e.fade;
			b += 255 * 0.18 * e.fade;
			double[3] av = [a, a, a], bv = [b, b, b];
			step(vips_linear(cur, &n, av.ptr, bv.ptr, 3, null), n, "linear");
		}
		if (e.vignette > 0)
		{
			// a small radial mask, resized to the picture: 1 in the middle, darker at the corners
			enum N = 64;
			float[N * N] mask;
			foreach (y; 0 .. N)
				foreach (x; 0 .. N)
				{
					immutable dx = (x + 0.5) / N - 0.5, dy = (y + 0.5) / N - 0.5;
					immutable r = sqrt(dx * dx + dy * dy) / 0.7071; // 0 centre, 1 corner
					immutable t = r < 0.35 ? 0 : (r - 0.35) / 0.65;
					mask[y * N + x] = cast(float)(1 - e.vignette * 0.85 * t * t);
				}
			auto small = vips_image_new_from_memory_copy(mask.ptr, mask.length * float.sizeof, N, N, 1, 6 /* float */);
			if (small is null)
				throw new Exception("mask: " ~ vipsError());
			scope (exit)
				g_object_unref(small);
			immutable W = vips_image_get_width(cur), H = vips_image_get_height(cur);
			void* big;
			check(vips_resize(small, &big, cast(double) W / N, "vscale".ptr, cast(double) H / N, null), "mask resize");
			scope (exit)
				g_object_unref(big);
			// the resize may land a pixel off: crop the mask to the picture
			void* fit;
			check(vips_extract_area(big, &fit, 0, 0, min(W, vips_image_get_width(big)), min(H, vips_image_get_height(big)), null), "mask fit");
			scope (exit)
				g_object_unref(fit);
			if (vips_image_get_width(fit) == W && vips_image_get_height(fit) == H)
				step(vips_multiply(cur, fit, &n, null), n, "vignette");
		}
		step(vips_cast_uchar(cur, &n, null), n, "cast");
		if (e.sharpen > 0)
			step(vips_sharpen(cur, &n, "sigma".ptr, 1.0 + e.sharpen, "m2".ptr, 2.0 + 4.0 * e.sharpen, null), n, "sharpen");
	}
	// 5. JPEG
	void* buf;
	size_t len;
	check(vips_jpegsave_buffer(cur, &buf, &len, "Q".ptr, quality, "strip".ptr, 1, null), "jpegsave");
	scope (exit)
		g_free(buf);
	return (cast(ubyte*) buf)[0 .. len].dup;
}

/// A small JPEG (longest edge `size`) of in-memory JPEG bytes — NOT stored, returned raw.
/// For inlining portraits over the phone link, where a 4 MB response of full-size crops
/// stalls the yamux stream past the phone's liveness timeout. Throws on failure.
ubyte[] smallJpegOfBytes(const(ubyte)[] bytes, int size, int quality)
{
	void* thumb;
	if (vips_thumbnail_buffer(cast(void*) bytes.ptr, bytes.length, &thumb, size, "height".ptr, size, null) != 0)
		throw new Exception("thumbnail: " ~ vipsError());
	scope (exit)
		g_object_unref(thumb);
	void* buf;
	size_t len;
	if (vips_jpegsave_buffer(thumb, &buf, &len, "Q".ptr, quality, "strip".ptr, 1, null) != 0)
		throw new Exception("jpegsave: " ~ vipsError());
	scope (exit)
		g_free(buf);
	return (cast(ubyte*) buf)[0 .. len].dup;
}

/// A thumbnail (longest edge `size`) of JPEG bytes, stored; returns the hash and the size.
ThumbResult thumbnailOfBytes(const(ubyte)[] bytes, string storeRoot, int size)
{
	ThumbResult r;
	void* thumb;
	if (vips_thumbnail_buffer(cast(void*) bytes.ptr, bytes.length, &thumb, size, "height".ptr, size, null) != 0)
	{
		r.error = "thumbnail: " ~ vipsError();
		return r;
	}
	scope (exit)
		g_object_unref(thumb);
	r.width = vips_image_get_width(thumb);
	r.height = vips_image_get_height(thumb);
	void* buf;
	size_t len;
	if (vips_jpegsave_buffer(thumb, &buf, &len, "Q".ptr, 84, "strip".ptr, 1, null) != 0)
	{
		r.error = "jpegsave: " ~ vipsError();
		return r;
	}
	scope (exit)
		g_free(buf);
	r.hash = storeBytes(storeRoot, (cast(ubyte*) buf)[0 .. len]);
	r.ok = true;
	return r;
}

/// Width and height of a JPEG in memory (header only).
int[2] jpegSize(const(ubyte)[] bytes)
{
	auto img = vips_image_new_from_buffer(bytes.ptr, bytes.length, "".ptr, null);
	if (img is null)
		throw new Exception("size: " ~ vipsError());
	scope (exit)
		g_object_unref(img);
	return [vips_image_get_width(img), vips_image_get_height(img)];
}

/// A JPEG of `source` whose longest edge is at most `maxEdge`, EXIF-rotated,
/// metadata stripped. Worker-safe. Throws on failure.
ubyte[] renderJpeg(string source, int maxEdge, int quality)
{
	void* img;
	if (vips_thumbnail(source.toStringz, &img, maxEdge, "height".ptr, maxEdge, null) != 0)
		throw new Exception("render: " ~ vipsError());
	scope (exit)
		g_object_unref(img);
	void* buf;
	size_t len;
	if (vips_jpegsave_buffer(img, &buf, &len, "Q".ptr, quality, "strip".ptr, 1, null) != 0)
		throw new Exception("jpegsave: " ~ vipsError());
	scope (exit)
		g_free(buf);
	return (cast(ubyte*) buf)[0 .. len].dup;
}

/// A JPEG of the region (fx, fy, fw, fh) (fractions of the rotated image) at the
/// original's resolution, shrunk only if its longest edge exceeds `maxEdge`: what
/// the viewer shows when zoomed in, instead of blowing up its 4096 px rendition.
ubyte[] renderRegion(string source, double fx, double fy, double fw, double fh, int maxEdge)
{
	import std.algorithm : max, min;

	auto raw = vips_image_new_from_file(source.toStringz, null);
	if (raw is null)
		throw new Exception("cannot open: " ~ vipsError());
	scope (exit)
		g_object_unref(raw);
	void* img;
	if (vips_autorot(raw, &img, null) != 0)
		throw new Exception("autorot: " ~ vipsError());
	scope (exit)
		g_object_unref(img);
	immutable W = vips_image_get_width(img), H = vips_image_get_height(img);
	int left = max(0, cast(int)(fx * W)), top = max(0, cast(int)(fy * H));
	int w = min(cast(int)(fw * W + 1), W - left), h = min(cast(int)(fh * H + 1), H - top);
	if (w < 2 || h < 2)
		throw new Exception("region outside the image");
	void* crop;
	if (vips_extract_area(img, &crop, left, top, w, h, null) != 0)
		throw new Exception("crop: " ~ vipsError());
	scope (exit)
		g_object_unref(crop);
	immutable scale = cast(double) maxEdge / max(w, h);
	void* fit;
	if (vips_resize(crop, &fit, scale < 1 ? scale : 1.0, null) != 0)
		throw new Exception("resize: " ~ vipsError());
	scope (exit)
		g_object_unref(fit);
	void* buf;
	size_t len;
	if (vips_jpegsave_buffer(fit, &buf, &len, "Q".ptr, 88, "strip".ptr, 1, null) != 0)
		throw new Exception("jpegsave: " ~ vipsError());
	scope (exit)
		g_free(buf);
	return (cast(ubyte*) buf)[0 .. len].dup;
}

/// A JPEG of the face at (fx, fy, fw, fh) (fractions of the rotated image),
/// padded by a third on each side, longest edge `size`, stored under
/// `storeRoot`. Returns the hash. Worker-safe.
string renderFaceCrop(string source, string storeRoot, double fx, double fy, double fw, double fh, int size)
{
	import std.algorithm : max, min;

	auto raw = vips_image_new_from_file(source.toStringz, null);
	if (raw is null)
		throw new Exception("cannot open: " ~ vipsError());
	scope (exit)
		g_object_unref(raw);
	void* img;
	if (vips_autorot(raw, &img, null) != 0)
		throw new Exception("autorot: " ~ vipsError());
	scope (exit)
		g_object_unref(img);
	immutable W = vips_image_get_width(img), H = vips_image_get_height(img);
	immutable pad = 0.35;
	int left = cast(int)((fx - fw * pad) * W), top = cast(int)((fy - fh * pad) * H);
	int w = cast(int)(fw * (1 + 2 * pad) * W), h = cast(int)(fh * (1 + 2 * pad) * H);
	left = max(0, left);
	top = max(0, top);
	w = min(w, W - left);
	h = min(h, H - top);
	if (w < 2 || h < 2)
		throw new Exception("face box outside the image");
	void* crop;
	if (vips_extract_area(img, &crop, left, top, w, h, null) != 0)
		throw new Exception("crop: " ~ vipsError());
	scope (exit)
		g_object_unref(crop);
	immutable scale = cast(double) size / max(w, h);
	void* small;
	if (vips_resize(crop, &small, scale < 1 ? scale : 1.0, null) != 0)
		throw new Exception("resize: " ~ vipsError());
	scope (exit)
		g_object_unref(small);
	void* buf;
	size_t len;
	if (vips_jpegsave_buffer(small, &buf, &len, "Q".ptr, 86, "strip".ptr, 1, null) != 0)
		throw new Exception("jpegsave: " ~ vipsError());
	scope (exit)
		g_free(buf);
	return storeBytes(storeRoot, (cast(ubyte*) buf)[0 .. len]);
}

/// What a picture looks like, statistically — the signals the kind classifier
/// uses to tell a photograph from a screenshot or a meme. Computed on a 96 px
/// rendition, so it costs about nothing. Worker-safe.
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

ImageStats imageStats(string source)
{
	ImageStats r;
	enum edge = 256;
	void* img;
	if (vips_thumbnail(source.toStringz, &img, edge, "height".ptr, edge, null) != 0)
		throw new Exception("stats: " ~ vipsError());
	scope (exit)
		g_object_unref(img);
	void* rgb;
	if (vips_colourspace(img, &rgb, 22 /* sRGB */, null) != 0)
		throw new Exception("stats colourspace: " ~ vipsError());
	scope (exit)
		g_object_unref(rgb);
	void* flat = rgb;
	void* flattened;
	if (vips_image_get_bands(rgb) == 4)
	{
		if (vips_flatten(rgb, &flattened, null) != 0)
			throw new Exception("stats flatten: " ~ vipsError());
		flat = flattened;
	}
	scope (exit)
		if (flattened)
			g_object_unref(flattened);
	void* three = flat;
	void* extracted;
	if (vips_image_get_bands(flat) > 3)
	{
		if (vips_extract_band(flat, &extracted, 0, "n".ptr, 3, null) != 0)
			throw new Exception("stats bands: " ~ vipsError());
		three = extracted;
	}
	scope (exit)
		if (extracted)
			g_object_unref(extracted);
	void* bytes;
	if (vips_cast_uchar(three, &bytes, null) != 0)
		throw new Exception("stats cast: " ~ vipsError());
	scope (exit)
		g_object_unref(bytes);
	immutable bands = vips_image_get_bands(bytes);
	immutable w = vips_image_get_width(bytes), h = vips_image_get_height(bytes);
	size_t len;
	auto mem = vips_image_write_to_memory(bytes, &len);
	if (mem is null)
		throw new Exception("stats memory: " ~ vipsError());
	scope (exit)
		g_free(mem);
	auto px = (cast(ubyte*) mem)[0 .. len];
	return statsOf(px, w, h, bands);
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
