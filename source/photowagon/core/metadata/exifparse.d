/// A small EXIF reader in plain D for the fields the library needs — the
/// capture time and the orientation — where gexiv2 is not available (the phone).
/// Handles JPEG (APP1 Exif) and bare TIFF headers. Anything it does not
/// understand yields `found = false`, never a throw.
module photowagon.core.metadata.exifparse;

import std.bitmanip : bigEndianToNative, littleEndianToNative;
import std.string : startsWith;

struct ExifCore
{
	bool found;
	/// "YYYY:MM:DD HH:MM:SS" as stored, or null
	string dateTimeOriginal;
	/// 1..8; 1 when absent
	int orientation = 1;
}

/// Reads at most the first 256 KiB of `path`; EXIF lives in the first APP1 segment.
ExifCore readExifCore(string path)
{
	import std.stdio : File;

	ExifCore r;
	try
	{
		auto f = File(path, "rb");
		auto buf = new ubyte[256 * 1024];
		auto head = f.rawRead(buf);
		return parseExif(head);
	}
	catch (Exception)
		return r;
}

ExifCore parseExif(const(ubyte)[] data) pure nothrow
{
	ExifCore r;
	const(ubyte)[] tiff;
	if (data.length >= 4 && data[0] == 0xFF && data[1] == 0xD8)
		tiff = findApp1Exif(data);
	else if (data.length >= 8 && ((data[0] == 'I' && data[1] == 'I') || (data[0] == 'M' && data[1] == 'M')))
		tiff = data;
	if (tiff.length < 8)
		return r;
	immutable bigEndian = tiff[0] == 'M';
	uint u16(size_t at)
	{
		if (at + 2 > tiff.length)
			return 0;
		ubyte[2] b = tiff[at .. at + 2];
		return bigEndian ? bigEndianToNative!ushort(b) : littleEndianToNative!ushort(b);
	}

	uint u32(size_t at)
	{
		if (at + 4 > tiff.length)
			return 0;
		ubyte[4] b = tiff[at .. at + 4];
		return bigEndian ? bigEndianToNative!uint(b) : littleEndianToNative!uint(b);
	}

	if (u16(2) != 42)
		return r;
	immutable ifd0 = u32(4);
	if (ifd0 == 0 || ifd0 + 2 > tiff.length)
		return r;

	uint exifIfd;
	string dateTime; // Image.DateTime, the fallback
	void walk(uint ifd, int depth)
	{
		if (depth > 2 || ifd + 2 > tiff.length)
			return;
		immutable n = u16(ifd);
		foreach (i; 0 .. n)
		{
			immutable e = ifd + 2 + i * 12;
			if (e + 12 > tiff.length)
				return;
			immutable tag = u16(e);
			immutable type = u16(e + 2);
			immutable count = u32(e + 4);
			switch (tag)
			{
			case 0x0112: // Orientation, SHORT
				if (type == 3)
				{
					immutable v = u16(e + 8);
					if (v >= 1 && v <= 8)
						r.orientation = cast(int) v;
				}
				break;
			case 0x8769: // ExifIFDPointer
				exifIfd = u32(e + 8);
				break;
			case 0x9003: // DateTimeOriginal, ASCII 20
			case 0x9004: // DateTimeDigitized
			case 0x0132: // DateTime
				if (type == 2 && count >= 19)
				{
					immutable off = count > 4 ? u32(e + 8) : e + 8;
					if (off + 19 <= tiff.length)
					{
						auto s = cast(string)(cast(const(char)[]) tiff[off .. off + 19]).idup;
						if (tag == 0x9003)
							r.dateTimeOriginal = s;
						else if (tag == 0x9004 && r.dateTimeOriginal is null)
							r.dateTimeOriginal = s;
						else if (tag == 0x0132)
							dateTime = s;
					}
				}
				break;
			default:
				break;
			}
		}
	}

	walk(ifd0, 0);
	if (exifIfd)
		walk(exifIfd, 1);
	if (r.dateTimeOriginal is null)
		r.dateTimeOriginal = dateTime;
	r.found = true;
	return r;
}

/// The TIFF block inside the first APP1 segment tagged "Exif\0\0", or null.
private const(ubyte)[] findApp1Exif(const(ubyte)[] jpeg) pure nothrow
{
	size_t i = 2;
	while (i + 4 <= jpeg.length)
	{
		if (jpeg[i] != 0xFF)
			return null;
		immutable marker = jpeg[i + 1];
		if (marker == 0xD8 || (marker >= 0xD0 && marker <= 0xD7) || marker == 0x01)
		{
			i += 2;
			continue;
		}
		if (marker == 0xDA || marker == 0xD9) // start of scan / end: no more headers
			return null;
		immutable len = (cast(size_t) jpeg[i + 2] << 8) | jpeg[i + 3];
		if (len < 2 || i + 2 + len > jpeg.length)
			return null;
		if (marker == 0xE1 && len >= 8 && jpeg[i + 4 .. i + 10] == cast(const(ubyte)[]) "Exif\0\0")
			return jpeg[i + 10 .. i + 2 + len];
		i += 2 + len;
	}
	return null;
}

unittest
{
	// A minimal little-endian TIFF: IFD0 with Orientation=6 and DateTime, then an
	// Exif IFD with DateTimeOriginal.
	ubyte[] t;
	void u16(uint v) { t ~= cast(ubyte) v; t ~= cast(ubyte)(v >> 8); }
	void u32(uint v) { u16(v & 0xFFFF); u16(v >> 16); }
	t ~= cast(ubyte[]) "II"; u16(42); u32(8);
	// IFD0 at 8: 3 entries
	u16(3);
	u16(0x0112); u16(3); u32(1); u16(6); u16(0);
	u16(0x0132); u16(2); u32(20); u32(0); // offset patched below
	u16(0x8769); u16(4); u32(1); u32(0);   // patched below
	u32(0); // next IFD
	immutable dtOff = cast(uint) t.length;
	t ~= cast(ubyte[]) "2020:01:02 03:04:05\0";
	immutable exifOff = cast(uint) t.length;
	u16(1);
	u16(0x9003); u16(2); u32(20); u32(0); // patched
	u32(0);
	immutable dtoOff = cast(uint) t.length;
	t ~= cast(ubyte[]) "2021:06:07 08:09:10\0";
	// patch offsets (entry i at 10 + i*12, value at +8)
	void patch(size_t at, uint v) { t[at] = cast(ubyte) v; t[at + 1] = cast(ubyte)(v >> 8); t[at + 2] = cast(ubyte)(v >> 16); t[at + 3] = cast(ubyte)(v >> 24); }
	patch(10 + 1 * 12 + 8, dtOff);
	patch(10 + 2 * 12 + 8, exifOff);
	patch(exifOff + 2 + 8, dtoOff);

	auto r = parseExif(t);
	assert(r.found);
	assert(r.orientation == 6);
	assert(r.dateTimeOriginal == "2021:06:07 08:09:10");

	// wrapped in a JPEG APP1
	ubyte[] jpeg = [0xFF, 0xD8, 0xFF, 0xE1];
	immutable len = cast(uint)(t.length + 8);
	jpeg ~= cast(ubyte)(len >> 8); jpeg ~= cast(ubyte) len;
	jpeg ~= cast(ubyte[]) "Exif\0\0";
	jpeg ~= t;
	jpeg ~= [0xFF, 0xDA];
	auto j = parseExif(jpeg);
	assert(j.found && j.orientation == 6 && j.dateTimeOriginal == "2021:06:07 08:09:10");

	assert(!parseExif(cast(ubyte[]) "not an image").found);
	assert(!parseExif([0xFF, 0xD8, 0xFF, 0xDA]).found);
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

