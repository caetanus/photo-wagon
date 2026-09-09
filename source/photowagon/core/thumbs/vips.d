/// Thumbnails through libvips, straight into the content store.
/// `makeThumbnail` is a plain function of value types: it runs on a worker.
module photowagon.core.thumbs.vips;

import std.string : fromStringz, toStringz;

import photowagon.core.store.store : storeBytes;

private extern (C) nothrow @nogc
{
	int vips_init(const char* argv0);
	void vips_concurrency_set(int n);
	void* vips_image_new_from_file(const char* name, ...);
	int vips_image_get_width(void* image);
	int vips_image_get_height(void* image);
	int vips_thumbnail(const char* filename, void** out_, int width, ...);
	int vips_jpegsave_buffer(void* in_, void** buf, size_t* len, ...);
	int vips_thumbnail_buffer(void* buf, size_t len, void** out_, int width, ...);
	int vips_autorot(void* in_, void** out_, ...);
	int vips_extract_area(void* in_, void** out_, int left, int top, int width, int height, ...);
	int vips_resize(void* in_, void** out_, double scale, ...);
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
