/// EXIF/XMP through gexiv2. `readExif` is a plain function of a path that
/// returns a value type, so it can run on a worker thread via `async`.
module photowagon.core.metadata.exif;

import std.string : fromStringz, toStringz, strip, startsWith;

private extern (C) nothrow @nogc
{
	int gexiv2_initialize();
	void* gexiv2_metadata_new();
	int gexiv2_metadata_open_path(void* self, const char* path, void** error);
	char* gexiv2_metadata_try_get_tag_string(void* self, const char* tag, void** error);
	int gexiv2_metadata_try_get_orientation(void* self, void** error);
	int gexiv2_metadata_try_get_gps_info(void* self, double* lon, double* lat, double* alt, void** error);
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
	string error;
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
	return info;
}

/// "Canon" + "Canon EOS R6" → "Canon EOS R6"; "NIKON CORPORATION" + "NIKON D750" → "NIKON D750".
string cameraName(string make, string model) pure
{
	import std.uni : toLower;
	import std.string : split;

	if (model.length == 0)
		return make.length ? make : null;
	if (make.length == 0)
		return model;
	immutable firstWord = make.split.length ? make.split[0] : make;
	if (model.toLower.startsWith(firstWord.toLower))
		return model;
	return make ~ " " ~ model;
}

/// EXIF "YYYY:MM:DD HH:MM:SS" (also tolerates ISO-8601 from XMP). Local time
/// zone, which is what EXIF timestamps mean. 0 on failure.
long parseExifTimestamp(string s)
{
	import std.datetime : DateTime, SysTime, LocalTime, UTC;
	import std.conv : to;

	try
	{
		if (s.length < 19)
			return 0;
		immutable year = s[0 .. 4].to!int;
		immutable month = s[5 .. 7].to!int;
		immutable day = s[8 .. 10].to!int;
		immutable hour = s[11 .. 13].to!int;
		immutable minute = s[14 .. 16].to!int;
		immutable second = s[17 .. 19].to!int;
		if (year < 1900 || month < 1 || month > 12 || day < 1 || day > 31)
			return 0;
		auto dt = DateTime(year, month, day, hour, minute, second);
		// XMP may carry an explicit zone; honour Z / ±hh:mm
		if (s.length > 19)
		{
			auto rest = s[19 .. $];
			if (rest.length && (rest[0] == '.'))
			{
				size_t i = 1;
				while (i < rest.length && rest[i] >= '0' && rest[i] <= '9')
					i++;
				rest = rest[i .. $];
			}
			if (rest == "Z")
				return SysTime(dt, UTC()).toUnixTime;
			if (rest.length == 6 && (rest[0] == '+' || rest[0] == '-'))
			{
				immutable off = (rest[1 .. 3].to!int * 60 + rest[4 .. 6].to!int) * 60;
				immutable base = SysTime(dt, UTC()).toUnixTime;
				return rest[0] == '+' ? base - off : base + off;
			}
		}
		return SysTime(dt, LocalTime()).toUnixTime;
	}
	catch (Exception)
		return 0;
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
