/// The freedesktop trash: `$XDG_DATA_HOME/Trash` (or `~/.local/share/Trash`),
/// a `files/` folder and an `info/` folder with a `.trashinfo` per entry, which
/// is what the desktop's trash can shows and restores from.
module photowagon.core.library.trash;

import std.datetime : Clock;
import std.file : exists, mkdirRecurse, rename, copy, remove, write, isDir;
import std.path : baseName, buildPath, absolutePath, extension, stripExtension;
import std.process : environment;
import std.string : format;

string trashDir()
{
	immutable data = environment.get("XDG_DATA_HOME", buildPath(environment.get("HOME", "/tmp"), ".local", "share"));
	return buildPath(data, "Trash");
}

/// Moves `path` to the trash; returns where it went. Throws when it cannot.
string moveToTrash(string path)
{
	immutable abs = path.absolutePath;
	if (!abs.exists)
		throw new Exception("no such file: " ~ abs);
	immutable root = trashDir();
	mkdirRecurse(buildPath(root, "files"));
	mkdirRecurse(buildPath(root, "info"));
	// a free name in the trash: photo.jpg, photo.2.jpg, photo.3.jpg…
	string name = abs.baseName;
	int n = 1;
	while (buildPath(root, "files", name).exists || buildPath(root, "info", name ~ ".trashinfo").exists)
	{
		n++;
		name = abs.baseName.stripExtension ~ "." ~ format("%d", n) ~ abs.extension;
	}
	immutable dest = buildPath(root, "files", name);
	auto now = Clock.currTime();
	write(buildPath(root, "info", name ~ ".trashinfo"),
		"[Trash Info]\nPath=" ~ encode(abs) ~ "\nDeletionDate=" ~ format("%04d-%02d-%02dT%02d:%02d:%02d",
			now.year, cast(int) now.month, now.day, now.hour, now.minute, now.second) ~ "\n");
	try
		rename(abs, dest);
	catch (Exception)
	{
		// another file system: copy, then remove
		copy(abs, dest);
		remove(abs);
	}
	return dest;
}

/// Percent-encoding of a path as the trash spec wants it (reserved characters only).
private string encode(string path)
{
	import std.array : appender;

	auto out_ = appender!string;
	foreach (char c; path)
	{
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '/' || c == '.' || c == '-' || c == '_' || c == '~')
			out_ ~= c;
		else
			out_ ~= format("%%%02X", cast(ubyte) c);
	}
	return out_.data;
}

unittest
{
	import std.file : tempDir, readText, rmdirRecurse;

	immutable dir = buildPath(tempDir, "pw-trash-ut");
	if (dir.exists) rmdirRecurse(dir);
	mkdirRecurse(dir);
	scope (exit) rmdirRecurse(dir);
	immutable old = environment.get("XDG_DATA_HOME", "");
	environment["XDG_DATA_HOME"] = buildPath(dir, "data");
	scope (exit) if (old.length) environment["XDG_DATA_HOME"] = old; else environment.remove("XDG_DATA_HOME");
	immutable f = buildPath(dir, "a b.jpg");
	write(f, "x");
	immutable where = moveToTrash(f);
	assert(!f.exists && where.exists);
	assert(readText(buildPath(dir, "data", "Trash", "info", "a b.jpg.trashinfo")).length > 20);
	write(f, "y");
	assert(moveToTrash(f).baseName == "a b.2.jpg");
}
