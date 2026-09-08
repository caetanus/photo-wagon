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
