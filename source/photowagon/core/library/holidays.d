/// Which celebration a date falls on. A photo taken on Christmas Day is a Christmas
/// photo whatever the model sees in it, so the calendar speaks first for the
/// `holiday` group and CLIP fills in the rest (a birthday, a wedding, a graduation
/// have no date). Brazilian calendar for the moveable family days.
module photowagon.core.library.holidays;

import std.datetime : Date, DayOfWeek, SysTime, LocalTime, dur;

/// Easter Sunday of `year` (Gregorian computus).
Date easter(int year) pure @safe
{
	immutable a = year % 19, b = year / 100, c = year % 100;
	immutable d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3;
	immutable h = (19 * a + b - d - g + 15) % 30;
	immutable i = c / 4, k = c % 4;
	immutable l = (32 + 2 * e + 2 * i - h - k) % 7;
	immutable m = (a + 11 * h + 22 * l) / 451;
	immutable month = (h + l - 7 * m + 114) / 31;
	immutable day = (h + l - 7 * m + 114) % 31 + 1;
	return Date(year, month, day);
}

/// The n-th `weekday` of a month (1 = first).
Date nthWeekday(int year, int month, DayOfWeek weekday, int n) pure @safe
{
	auto d = Date(year, month, 1);
	while (d.dayOfWeek != weekday)
		d += dur!"days"(1);
	return d + dur!"days"(7 * (n - 1));
}

/// The celebration of `date`, or null. Names match data/scenes/labels.tsv (group `holiday`).
string holidayOf(Date date) pure @safe
{
	immutable y = date.year, m = date.month, d = date.day;
	if (m == 12 && (d == 24 || d == 25))
		return "Christmas";
	if ((m == 12 && d == 31) || (m == 1 && d == 1))
		return "New Year";
	if (m == 10 && d == 31)
		return "Halloween";
	if (m == 10 && d == 12)
		return "Children's Day";      // Brazil
	if (m == 6 && d == 12)
		return "Valentine's Day";     // Dia dos Namorados
	if (m == 6 && (d == 23 || d == 24))
		return "Festa Junina";        // São João
	immutable e = easter(y);
	if (date == e)
		return "Easter";
	immutable carnivalSaturday = e - dur!"days"(50), carnivalTuesday = e - dur!"days"(47);
	if (date >= carnivalSaturday && date <= carnivalTuesday)
		return "Carnival";
	if (m == 5 && date == nthWeekday(y, 5, DayOfWeek.sun, 2))
		return "Mother's Day";        // Brazil: second Sunday of May
	if (m == 8 && date == nthWeekday(y, 8, DayOfWeek.sun, 2))
		return "Father's Day";        // Brazil: second Sunday of August
	return null;
}

/// The same for a unix time, in local time.
string holidayOf(long unixTime)
{
	if (unixTime <= 0)
		return null;
	try
		return holidayOf(cast(Date) SysTime.fromUnixTime(unixTime, LocalTime()));
	catch (Exception)
		return null;
}

unittest
{
	assert(easter(2024) == Date(2024, 3, 31));
	assert(easter(2025) == Date(2025, 4, 20));
	assert(easter(2026) == Date(2026, 4, 5));
	assert(holidayOf(Date(2025, 12, 25)) == "Christmas");
	assert(holidayOf(Date(2026, 1, 1)) == "New Year");
	assert(holidayOf(Date(2026, 4, 5)) == "Easter");
	assert(holidayOf(Date(2026, 2, 14)) == "Carnival");   // Saturday before Ash Wednesday (Feb 18, 2026)
	assert(holidayOf(Date(2026, 2, 17)) == "Carnival");   // Tuesday
	assert(holidayOf(Date(2026, 2, 18)) is null);         // Ash Wednesday
	assert(holidayOf(Date(2026, 5, 10)) == "Mother's Day");
	assert(holidayOf(Date(2026, 8, 9)) == "Father's Day");
	assert(holidayOf(Date(2026, 10, 12)) == "Children's Day");
	assert(holidayOf(Date(2026, 6, 12)) == "Valentine's Day");
	assert(holidayOf(Date(2026, 6, 24)) == "Festa Junina");
	assert(holidayOf(Date(2026, 3, 3)) is null);
	assert(holidayOf(0L) is null);
}
