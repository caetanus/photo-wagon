/// When a file has no EXIF date, its name or its folder usually still says when
/// it was taken: `IMG_20210321_150104.jpg`, `20220102_064744.jpg`,
/// `IMG-20200213-WA0000.jpg` (WhatsApp), `Screenshot_2020-10-07-09-11-02.png`,
/// `PXL_20230105_183000123.jpg`, or a `2020/02/13/` folder. The file's mtime is
/// the date of the last copy, which is why a 2019 photo showed as 2026.
/// Pure D: the phone uses this too.
module photowagon.core.metadata.datefromname;

import std.datetime : DateTime, SysTime, LocalTime, TimeException;
import std.path : baseName, dirName;
import std.regex : ctRegex, matchFirst, matchAll;
import std.conv : to;

/// Unix time inferred from the path, or 0 when nothing in it looks like a date.
/// A name with a time of day wins over a bare date; the folder comes last.
long dateFromPath(string path)
{
	immutable name = path.baseName;
	// YYYYMMDD_HHMMSS or YYYYMMDD-HHMMSS (cameras, Pixel PXL_, Samsung, VID_)
	if (auto m = name.matchFirst(ctRegex!`(20\d{2}|19\d{2})(\d{2})(\d{2})[-_](\d{2})(\d{2})(\d{2})`))
		if (auto t = make(m[1], m[2], m[3], m[4], m[5], m[6]))
			return t;
	// YYYY-MM-DD-HH-MM-SS / YYYY-MM-DD_HH.MM.SS / YYYY-MM-DD HH:MM:SS (screenshots, exports)
	if (auto m = name.matchFirst(ctRegex!`(20\d{2}|19\d{2})-(\d{2})-(\d{2})[-_ T](\d{2})[-.:h](\d{2})[-.:m]?(\d{2})?`))
		if (auto t = make(m[1], m[2], m[3], m[4], m[5], m[6].length ? m[6] : "00"))
			return t;
	// a bare YYYYMMDD in the name (WhatsApp IMG-20200213-WA0000, Telegram, most others): noon
	if (auto m = name.matchFirst(ctRegex!`(?<!\d)(20\d{2}|19\d{2})(0[1-9]|1[0-2])([0-2]\d|3[01])(?!\d)`))
		if (auto t = make(m[1], m[2], m[3], "12", "00", "00"))
			return t;
	if (auto m = name.matchFirst(ctRegex!`(?<!\d)(20\d{2}|19\d{2})-(0[1-9]|1[0-2])-([0-2]\d|3[01])(?!\d)`))
		if (auto t = make(m[1], m[2], m[3], "12", "00", "00"))
			return t;
	// the folders: .../2020/02/13/... or .../2020-02-13/... or .../2020/02/...
	immutable dir = path.dirName;
	if (auto m = dir.matchFirst(ctRegex!`(?<!\d)(20\d{2}|19\d{2})[/-](0[1-9]|1[0-2])[/-]([0-2]\d|3[01])(?!\d)`))
		if (auto t = make(m[1], m[2], m[3], "12", "00", "00"))
			return t;
	if (auto m = dir.matchFirst(ctRegex!`(?<!\d)(20\d{2}|19\d{2})[/-](0[1-9]|1[0-2])(?!\d)`))
		if (auto t = make(m[1], m[2], "15", "12", "00", "00"))
			return t;
	return 0;
}

private long make(string y, string mo, string d, string h, string mi, string s)
{
	try
	{
		immutable year = y.to!int, month = mo.to!int, day = d.to!int;
		immutable hour = h.to!int, minute = mi.to!int, second = s.to!int;
		if (month < 1 || month > 12 || day < 1 || day > 31 || hour > 23 || minute > 59 || second > 59)
			return 0;
		if (year < 1990 || year > 2100)
			return 0;
		return SysTime(DateTime(year, month, day, hour, minute, second), LocalTime()).toUnixTime;
	}
	catch (TimeException)
		return 0; // 31 February and friends
	catch (Exception)
		return 0;
}

unittest
{
	long y(long ts) { return ts ? SysTime.fromUnixTime(ts, LocalTime()).year : 0; }
	int month(long ts) { return ts ? cast(int) SysTime.fromUnixTime(ts, LocalTime()).month : 0; }
	assert(y(dateFromPath("/p/IMG_20210321_150104.jpg")) == 2021 && month(dateFromPath("/p/IMG_20210321_150104.jpg")) == 3);
	assert(y(dateFromPath("/p/20220102_064744.jpg")) == 2022);
	assert(y(dateFromPath("/home/x/Photos/2020/02/13/IMG-20200213-WA0000.jpg")) == 2020);
	assert(y(dateFromPath("/p/Screenshot_2020-10-07-09-11-02-123_com.app.png")) == 2020);
	assert(y(dateFromPath("/p/PXL_20230105_183000123.jpg")) == 2023);
	assert(y(dateFromPath("/home/x/Photos/2019/12/25/foto.jpg")) == 2019);
	assert(y(dateFromPath("/home/x/2019-08/foto.jpg")) == 2019 && month(dateFromPath("/home/x/2019-08/foto.jpg")) == 8);
	assert(dateFromPath("/p/DSC_0001.jpg") == 0);
	assert(dateFromPath("/p/IMG_1234567.jpg") == 0);
	assert(dateFromPath("/p/20211399_000000.jpg") == 0); // no 99th day
}
