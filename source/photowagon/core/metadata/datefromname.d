/// When a file has no EXIF date, its name or its folder usually still says when
/// it was taken: `IMG_20210321_150104.jpg`, `20220102_064744.jpg`,
/// `IMG-20200213-WA0000.jpg` (WhatsApp), `Screenshot_2020-10-07-09-11-02.png`,
/// `PXL_20230105_183000123.jpg`, or a `2020/02/13/` folder. The file's mtime is
/// the date of the last copy, which is why a 2019 photo showed as 2026.
/// Pure D: the phone uses this too.
///
/// This used to lean on `std.regex` (ctRegex), but the lookbehind/lookahead patterns
/// forced std.regex onto its backtracking matcher, whose working memory is allocated
/// with malloc and was never freed — ~1.4 MB leaked per imported file, C-side, which
/// heaptrack traced straight here from indexer.importCandidate. This hand-rolled scan
/// allocates nothing and is faster; the unittest below pins the behaviour it replaces.
module photowagon.core.metadata.datefromname;

import std.datetime : DateTime, SysTime, LocalTime, TimeException;
import std.path : baseName, dirName;
import std.conv : to;

/// Unix time inferred from the path, or 0 when nothing in it looks like a date.
/// A name with a time of day wins over a bare date; the folder comes last.
long dateFromPath(string path)
{
	immutable name = path.baseName;
	// YYYYMMDD_HHMMSS or YYYYMMDD-HHMMSS (cameras, Pixel PXL_, Samsung, VID_)
	if (auto t = compactDateTime(name))
		return t;
	// YYYY-MM-DD-HH-MM-SS / YYYY-MM-DD_HH.MM.SS / YYYY-MM-DD HH:MM:SS (screenshots, exports)
	if (auto t = separatedDateTime(name))
		return t;
	// a bare YYYYMMDD in the name (WhatsApp IMG-20200213-WA0000, Telegram, most others): noon
	if (auto t = bareDate(name, false))
		return t;
	if (auto t = bareDate(name, true))
		return t;
	// the folders: .../2020/02/13/... or .../2020-02-13/... or .../2020/02/...
	immutable dir = path.dirName;
	if (auto t = folderDate(dir))
		return t;
	return 0;
}

private bool dig(char c) { return c >= '0' && c <= '9'; }

/// `n` digits starting at `a` (false if it runs off the end).
private bool digits(string s, size_t a, size_t n)
{
	if (a + n > s.length)
		return false;
	foreach (i; a .. a + n)
		if (!dig(s[i]))
			return false;
	return true;
}

/// s[i..i+4] is a 19xx or 20xx year.
private bool yhead(string s, size_t i)
{
	return i + 4 <= s.length && (s[i .. i + 2] == "19" || s[i .. i + 2] == "20")
		&& dig(s[i + 2]) && dig(s[i + 3]);
}

/// The char at `i` is not a digit — treating the ends of the string as boundaries
/// (this is the `(?!\d)` lookahead).
private bool notDigAt(string s, size_t i) { return i >= s.length || !dig(s[i]); }

/// The char before `i` is not a digit (the `(?<!\d)` lookbehind).
private bool notDigBefore(string s, size_t i) { return i == 0 || !dig(s[i - 1]); }

private bool validMonth(string mo)
{
	immutable m = (mo[0] - '0') * 10 + (mo[1] - '0');
	return m >= 1 && m <= 12;   // 0[1-9] | 1[0-2]
}

private bool validMoDay(string mo, string d)
{
	immutable dd = (d[0] - '0') * 10 + (d[1] - '0');
	return validMonth(mo) && dd <= 31;   // day [0-2]\d | 3[01]
}

// YYYYMMDD [-_] HHMMSS — leftmost structural match, like matchFirst: make() once, then fall through.
private long compactDateTime(string s)
{
	for (size_t i = 0; i + 15 <= s.length; i++)
	{
		if (!yhead(s, i) || !digits(s, i, 8))
			continue;
		immutable sep = s[i + 8];
		if (sep != '-' && sep != '_')
			continue;
		if (!digits(s, i + 9, 6))
			continue;
		return make(s[i .. i + 4], s[i + 4 .. i + 6], s[i + 6 .. i + 8],
			s[i + 9 .. i + 11], s[i + 11 .. i + 13], s[i + 13 .. i + 15]);
	}
	return 0;
}

// YYYY-MM-DD <sep> HH <sep> MM [<sep> SS]  (SS and its separator both optional)
private long separatedDateTime(string s)
{
	for (size_t i = 0; i + 10 <= s.length; i++)
	{
		if (!yhead(s, i) || s[i + 4] != '-' || !digits(s, i + 5, 2)
			|| s[i + 7] != '-' || !digits(s, i + 8, 2))
			continue;
		immutable size_t p = i + 10;   // after YYYY-MM-DD
		if (p >= s.length)
			continue;
		immutable c1 = s[p];
		if (c1 != '-' && c1 != '_' && c1 != ' ' && c1 != 'T')
			continue;
		if (!digits(s, p + 1, 2))   // HH
			continue;
		if (p + 3 >= s.length)
			continue;
		immutable c2 = s[p + 3];
		if (c2 != '-' && c2 != '.' && c2 != ':' && c2 != 'h')
			continue;
		if (!digits(s, p + 4, 2))   // MM
			continue;
		string ss = "00";
		immutable size_t q = p + 6;
		if (q < s.length)
		{
			immutable c3 = s[q];
			if ((c3 == '-' || c3 == '.' || c3 == ':' || c3 == 'm') && digits(s, q + 1, 2))
				ss = s[q + 1 .. q + 3];
			else if (dig(c3) && digits(s, q, 2))
				ss = s[q .. q + 2];
		}
		return make(s[i .. i + 4], s[i + 5 .. i + 7], s[i + 8 .. i + 10],
			s[p + 1 .. p + 3], s[p + 4 .. p + 6], ss);
	}
	return 0;
}

// An isolated YYYYMMDD (dashed=false) or YYYY-MM-DD (dashed=true): not part of a
// longer digit run, month 01-12, day 00-31. Noon, since the name carries no time.
private long bareDate(string s, bool dashed)
{
	immutable size_t span = dashed ? 10 : 8;
	for (size_t i = 0; i + span <= s.length; i++)
	{
		if (!notDigBefore(s, i) || !yhead(s, i))
			continue;
		string mo, d;
		if (dashed)
		{
			if (s[i + 4] != '-' || !digits(s, i + 5, 2) || s[i + 7] != '-' || !digits(s, i + 8, 2))
				continue;
			mo = s[i + 5 .. i + 7];
			d = s[i + 8 .. i + 10];
		}
		else
		{
			if (!digits(s, i, 8))
				continue;
			mo = s[i + 4 .. i + 6];
			d = s[i + 6 .. i + 8];
		}
		if (!notDigAt(s, i + span))
			continue;
		if (!validMoDay(mo, d))
			continue;
		return make(s[i .. i + 4], mo, d, "12", "00", "00");
	}
	return 0;
}

// A folder date: YYYY[/-]MM[/-]DD first, then a bare YYYY[/-]MM (day defaults to the 15th).
private long folderDate(string dir)
{
	for (size_t i = 0; i + 10 <= dir.length; i++)
	{
		if (!notDigBefore(dir, i) || !yhead(dir, i))
			continue;
		immutable s1 = dir[i + 4];
		if ((s1 != '/' && s1 != '-') || !digits(dir, i + 5, 2))
			continue;
		immutable s2 = dir[i + 7];
		if ((s2 != '/' && s2 != '-') || !digits(dir, i + 8, 2))
			continue;
		if (!notDigAt(dir, i + 10))
			continue;
		immutable mo = dir[i + 5 .. i + 7], d = dir[i + 8 .. i + 10];
		if (!validMoDay(mo, d))
			continue;
		return make(dir[i .. i + 4], mo, d, "12", "00", "00");
	}
	for (size_t i = 0; i + 7 <= dir.length; i++)
	{
		if (!notDigBefore(dir, i) || !yhead(dir, i))
			continue;
		immutable s1 = dir[i + 4];
		if ((s1 != '/' && s1 != '-') || !digits(dir, i + 5, 2))
			continue;
		if (!notDigAt(dir, i + 7))
			continue;
		immutable mo = dir[i + 5 .. i + 7];
		if (!validMonth(mo))
			continue;
		return make(dir[i .. i + 4], mo, "15", "12", "00", "00");
	}
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
	immutable pix = dateFromPath("/p/IMG_20210321_150104.jpg");
	assert(y(pix) == 2021 && month(pix) == 3);
	assert(y(dateFromPath("/p/20220102_064744.jpg")) == 2022);
	assert(y(dateFromPath("/home/x/Photos/2020/02/13/IMG-20200213-WA0000.jpg")) == 2020);
	assert(y(dateFromPath("/p/Screenshot_2020-10-07-09-11-02-123_com.app.png")) == 2020);
	assert(y(dateFromPath("/p/PXL_20230105_183000123.jpg")) == 2023);
	assert(y(dateFromPath("/home/x/Photos/2019/12/25/foto.jpg")) == 2019);
	assert(y(dateFromPath("/home/x/2019-08/foto.jpg")) == 2019 && month(dateFromPath("/home/x/2019-08/foto.jpg")) == 8);
	assert(dateFromPath("/p/DSC_0001.jpg") == 0);
	assert(dateFromPath("/p/IMG_1234567.jpg") == 0);
	assert(dateFromPath("/p/20211399_000000.jpg") == 0); // no 99th day
	// extra guards for the hand-rolled scan (behaviour the regexes had):
	assert(y(dateFromPath("/p/2020-02-13.jpg")) == 2020 && month(dateFromPath("/p/2020-02-13.jpg")) == 2); // bare dashed
	assert(month(dateFromPath("/p/Screenshot_2021-07-04_09.30.jpg")) == 7);  // no seconds
	assert(dateFromPath("/p/v123456789.jpg") == 0);   // 9-digit run, not an isolated YYYYMMDD
	immutable fd = dateFromPath("/home/x/2018-11-30/a.jpg");   // folder dashed
	assert(y(fd) == 2018 && month(fd) == 11);
}
