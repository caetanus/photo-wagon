/// Time and URL helpers shared by the desktop core and the phone index. Pure D.
module photowagon.core.library.calendar;

/// [from, to) in unix seconds, local time, for a year, a month or a day.
long[2] dateRange(int year, int month, int day)
{
	import std.datetime : DateTime, SysTime, LocalTime, Date, TimeOfDay;
	import core.time : days;

	long ts(Date d)
	{
		return SysTime(DateTime(d, TimeOfDay(0, 0, 0)), LocalTime()).toUnixTime;
	}

	if (month == 0)
		return [ts(Date(year, 1, 1)), ts(Date(year + 1, 1, 1))];
	if (day == 0)
	{
		auto next = month == 12 ? Date(year + 1, 1, 1) : Date(year, month + 1, 1);
		return [ts(Date(year, month, 1)), ts(next)];
	}
	auto d = Date(year, month, day);
	return [ts(d), ts(d + 1.days)];
}

/// Local calendar date of a unix time: [year, month, day].
int[3] localDate(long unix)
{
	import std.datetime : SysTime, LocalTime;

	auto t = SysTime.fromUnixTime(unix, LocalTime());
	return [t.year, t.month, t.day];
}

/// ISO-8601 in UTC with a Z, as `takenAt` is defined in docs/ipc.md.
string isoTime(long unix)
{
	import std.datetime : SysTime, UTC;

	return SysTime.fromUnixTime(unix, UTC()).toISOExtString();
}

/// `file://` URL for an absolute path, percent-encoding what QUrl would trip on.
string fileUrl(string path) pure
{
	import std.ascii : isAlphaNum;
	import std.format : format;

	string out_ = "file://";
	foreach (char c; path)
	{
		if (c.isAlphaNum || c == '/' || c == '-' || c == '_' || c == '.' || c == '~')
			out_ ~= c;
		else
			out_ ~= format("%%%02X", cast(ubyte) c);
	}
	return out_;
}

unittest
{
	assert(fileUrl("/a b/c#1.jpg") == "file:///a%20b/c%231.jpg");
	auto r = dateRange(2024, 2, 0);
	assert(r[1] - r[0] == 29 * 86_400);
	auto y = dateRange(2023, 0, 0);
	assert(y[1] - y[0] == 365 * 86_400);
	assert(isoTime(0) == "1970-01-01T00:00:00Z");
	auto d = localDate(dateRange(2024, 5, 17)[0] + 3600);
	assert(d == [2024, 5, 17]);
}
