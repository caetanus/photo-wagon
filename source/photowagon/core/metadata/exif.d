/// EXIF/XMP through gexiv2. `readExif` is a plain function of a path that
/// returns a value type, so it can run on a worker thread via `async`.
module photowagon.core.metadata.exif;

import std.string : fromStringz, toStringz, strip;

public import photowagon.core.metadata.exifparse : cameraName, parseExifTimestamp;

private extern (C) nothrow @nogc
{
	int gexiv2_initialize();
	void* gexiv2_metadata_new();
	int gexiv2_metadata_open_path(void* self, const char* path, void** error);
	char* gexiv2_metadata_try_get_tag_string(void* self, const char* tag, void** error);
	int gexiv2_metadata_try_get_orientation(void* self, void** error);
	int gexiv2_metadata_try_get_gps_info(void* self, double* lon, double* lat, double* alt, void** error);
	char** gexiv2_metadata_try_get_tag_multiple(void* self, const char* tag, void** error);
	int gexiv2_metadata_try_set_tag_multiple(void* self, const char* tag, const(char*)* values, void** error);
	int gexiv2_metadata_try_clear_tag(void* self, const char* tag, void** error);
	int gexiv2_metadata_save_file(void* self, const char* path, void** error);
	void g_strfreev(char** v);
	void g_object_unref(void* obj);
	void g_free(void* p);
	void g_error_free(void* err);
	uint g_log_set_handler(const char* domain, int levels, void* func, void* data);
}

private extern (C) void quietLog(const char*, int, const char*, void*) nothrow
{
}

/// Call once per process before any `readExif`.
void initExif()
{
	gexiv2_initialize();
	// gexiv2 and exiv2 log every unknown tag to stderr; keep the daemon quiet
	g_log_set_handler("GExiv2".ptr, 0xFF, &quietLog, null);
}

struct ExifInfo
{
	/// false when the file could not be opened by exiv2 at all
	bool ok;
	/// unix seconds of DateTimeOriginal (or CreateDate / DateTime); 0 when absent
	long takenTs;
	/// "Make Model" with the make deduplicated, or null
	string camera;
	/// EXIF orientation 1..8; 1 when absent
	int orientation = 1;
	bool hasGps;
	double lat;
	double lon;
	/// XMP dc:subject and IPTC keywords, in file order, deduplicated
	string[] keywords;
	string error;
}

/// The tags other programs read and write keywords into.
private enum subjectTags = ["Xmp.dc.subject", "Iptc.Application2.Keywords"];

private string[] readSubjects(void* meta)
{
	string[] out_;
	bool[string] seen;
	foreach (tag; subjectTags)
	{
		void* e;
		auto v = gexiv2_metadata_try_get_tag_multiple(meta, tag.ptr, &e);
		if (e)
			g_error_free(e);
		if (v is null)
			continue;
		scope (exit)
			g_strfreev(v);
		for (size_t i = 0; v[i] !is null; i++)
		{
			auto k = v[i].fromStringz.idup;
			import std.string : strip;
			k = k.strip;
			if (!k.length || k in seen)
				continue;
			seen[k] = true;
			out_ ~= k;
		}
	}
	return out_;
}

/// Writes `subjects` as the file's keywords (XMP dc:subject and IPTC), keeping the
/// pixels and every other tag, and puts the modification time back so the indexer
/// does not see a changed file. Plain function of value types: runs on a worker.
/// Returns null, or the error.
string writeSubjects(string path, string[] subjects)
{
	import std.file : getTimes, setTimes;

	auto meta = gexiv2_metadata_new();
	if (meta is null)
		return "gexiv2_metadata_new failed";
	scope (exit)
		g_object_unref(meta);
	{
		void* e;
		if (!gexiv2_metadata_open_path(meta, path.toStringz, &e))
		{
			auto msg = e ? "cannot open for writing" : "cannot open";
			if (e)
				g_error_free(e);
			return msg;
		}
	}
	const(char)*[] values;
	foreach (s; subjects)
		values ~= s.toStringz;
	values ~= null;
	foreach (tag; subjectTags)
	{
		void* e;
		if (subjects.length)
			gexiv2_metadata_try_set_tag_multiple(meta, tag.ptr, values.ptr, &e);
		else
			gexiv2_metadata_try_clear_tag(meta, tag.ptr, &e);
		if (e)
			g_error_free(e);
	}
	import std.datetime : SysTime;
	SysTime accessed, modified;
	bool haveTimes;
	try
	{
		getTimes(path, accessed, modified);
		haveTimes = true;
	}
	catch (Exception)
	{
	}
	{
		void* e;
		if (!gexiv2_metadata_save_file(meta, path.toStringz, &e))
		{
			if (e)
				g_error_free(e);
			return "save failed (read-only file or unsupported format?)";
		}
	}
	if (haveTimes)
		try
			setTimes(path, accessed, modified);
		catch (Exception)
		{
		}
	return null;
}

ExifInfo readExif(string path)
{
	ExifInfo info;
	auto meta = gexiv2_metadata_new();
	if (meta is null)
	{
		info.error = "gexiv2_metadata_new failed";
		return info;
	}
	scope (exit)
		g_object_unref(meta);

	void* err;
	if (!gexiv2_metadata_open_path(meta, path.toStringz, &err))
	{
		info.error = "exiv2 cannot open";
		if (err)
			g_error_free(err);
		return info;
	}
	info.ok = true;

	string tag(string name)
	{
		void* e;
		auto p = gexiv2_metadata_try_get_tag_string(meta, name.toStringz, &e);
		if (e)
			g_error_free(e);
		if (p is null)
			return null;
		scope (exit)
			g_free(p);
		return p.fromStringz.idup.strip;
	}

	foreach (name; ["Exif.Photo.DateTimeOriginal", "Exif.Photo.DateTimeDigitized",
			"Exif.Image.DateTime", "Xmp.xmp.CreateDate", "Xmp.photoshop.DateCreated"])
	{
		immutable v = tag(name);
		if (v.length)
		{
			info.takenTs = parseExifTimestamp(v);
			if (info.takenTs)
				break;
		}
	}

	info.camera = cameraName(tag("Exif.Image.Make"), tag("Exif.Image.Model"));

	{
		void* e;
		immutable o = gexiv2_metadata_try_get_orientation(meta, &e);
		if (e)
			g_error_free(e);
		info.orientation = (o >= 1 && o <= 8) ? o : 1;
	}
	{
		void* e;
		double lon, lat, alt;
		if (gexiv2_metadata_try_get_gps_info(meta, &lon, &lat, &alt, &e))
		{
			info.hasGps = true;
			info.lat = lat;
			info.lon = lon;
		}
		if (e)
			g_error_free(e);
	}
	info.keywords = readSubjects(meta);
	return info;
}

unittest
{
	assert(cameraName("Canon", "Canon EOS R6") == "Canon EOS R6");
	assert(cameraName("NIKON CORPORATION", "NIKON D750") == "NIKON D750");
	assert(cameraName("Apple", "iPhone 13") == "Apple iPhone 13");
	assert(cameraName("", "") is null);
	assert(parseExifTimestamp("2024:05:01 12:00:00") != 0);
	assert(parseExifTimestamp("2024-05-01T12:00:00Z") == 1_714_564_800);
	assert(parseExifTimestamp("2024-05-01T12:00:00+02:00") == 1_714_557_600);
	assert(parseExifTimestamp("garbage") == 0);
	assert(parseExifTimestamp("0000:00:00 00:00:00") == 0);
}
