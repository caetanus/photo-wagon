/// One pass over the photos whose date came from the file's mtime: a date in the
/// name or the folder is better (a 2019 WhatsApp picture copied in 2026 showed as
/// 2026). Runs once per `dateVersion`, at startup, before the indexer.
module photowagon.core.library.datefix;

import std.conv : to;
import std.json;

import vibe.core.log : logInfo;

import photowagon.core.db.sqlite : Database;
import photowagon.core.db.schema : getSetting, setSetting;
import photowagon.core.ipc.events : Events;
import photowagon.core.library.calendar : isoTime;
import photowagon.core.metadata.datefromname : dateFromPath;
import photowagon.core.metadata.exifparse : readExifCore, parseExifTimestamp;

enum dateVersion = 1;

/// Returns how many photos moved.
long fixDates(Database db, Events events)
{
	if (getSetting(db, "date_version") == dateVersion.to!string)
		return 0;
	// camera IS NULL: nothing came from EXIF at import (a camera always writes both)
	auto q = db.prepare("SELECT id, path, taken_ts FROM photos WHERE camera IS NULL");
	long[] ids;
	string[] paths;
	long[] olds;
	while (q.step())
	{
		ids ~= q.getLong(0);
		paths ~= q.getString(1);
		olds ~= q.getLong(2);
	}
	long moved;
	db.transaction!void({
		auto u = db.prepare("UPDATE photos SET taken_ts = ?, taken_at = ? WHERE id = ?");
		foreach (i, id; ids)
		{
			long ts;
			try
			{
				auto exif = readExifCore(paths[i]);   // the header only: cheap
				if (exif.found && exif.dateTimeOriginal.length)
					ts = parseExifTimestamp(exif.dateTimeOriginal);
			}
			catch (Exception) {}
			if (!ts)
				ts = dateFromPath(paths[i]);
			if (!ts || ts == olds[i])
				continue;
			u.reset();
			u.bind(1, ts).bind(2, isoTime(ts)).bind(3, id);
			u.run();
			moved++;
		}
		setSetting(db, "date_version", dateVersion.to!string);
	});
	logInfo("dates: %s of %s photos without EXIF dated from their name or folder", moved, ids.length);
	if (moved && events !is null)
		events.emit("library.changed", JSONValue.emptyObject);
	return moved;
}
