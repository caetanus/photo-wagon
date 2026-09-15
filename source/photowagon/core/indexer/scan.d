/// Walking a root for image files. Pure functions of paths; worker-safe.
module photowagon.core.indexer.scan;

import std.file : dirEntries, SpanMode, DirEntry, isDir;
import std.path : extension;
import std.uni : toLower;

immutable string[] imageExtensions = [
	".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".avif", ".tif", ".tiff",
	".gif", ".bmp", ".jxl", ".dng", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".raf", ".rw2"
];

/// Camera and phone video containers. A frame becomes the thumbnail; the viewer plays them.
immutable string[] videoExtensions = [
	".mp4", ".mov", ".m4v", ".3gp", ".avi", ".mkv", ".webm", ".mts", ".m2ts", ".wmv", ".flv"
];

bool isImagePath(string path) pure
{
	import std.algorithm : canFind;

	return imageExtensions.canFind(path.extension.toLower);
}

bool isVideoPath(string path) pure
{
	import std.algorithm : canFind;

	return videoExtensions.canFind(path.extension.toLower);
}

struct Candidate
{
	string path;
	long size;
	long mtimeMs;
	bool isVideo;
}

/// Every image under `root`, without following symlinks or entering hidden
/// directories. Unreadable subtrees are skipped, not fatal.
Candidate[] scanImages(string root)
{
	import std.path : baseName;
	import std.string : startsWith;

	Candidate[] out_;
	if (!root.isDir)
		return out_;
	void walk(string dir)
	{
		DirEntry[] entries;
		try
		{
			foreach (DirEntry e; dirEntries(dir, SpanMode.shallow, false))
				entries ~= e;
		}
		catch (Exception)
			return;
		foreach (ref e; entries)
		{
			immutable name = e.name.baseName;
			if (name.startsWith("."))
				continue;
			try
			{
				if (e.isSymlink)
					continue;
				if (e.isDir)
				{
					walk(e.name);
					continue;
				}
				if (!e.isFile || !(isImagePath(e.name) || isVideoPath(e.name)))
					continue;
				out_ ~= Candidate(e.name, cast(long) e.size, e.timeLastModified.toUnixTime!long * 1000
						+ e.timeLastModified.fracSecs.total!"msecs", isVideoPath(e.name));
			}
			catch (Exception)
			{
			}
		}
	}

	walk(root);
	return out_;
}

unittest
{
	assert(isImagePath("/a/b.JPG"));
	assert(isImagePath("x.heic"));
	assert(!isImagePath("x.txt"));
	assert(!isImagePath("noext"));
}
