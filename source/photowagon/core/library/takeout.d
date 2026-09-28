/// Google Photos → Photo Wagon, from a Google Takeout export.
///
/// Google's own API no longer lets an app read a whole library (2025), so the export is
/// the way: `takeout.google.com`, "Google Photos" only, unpacked into one folder. Next to
/// each photo it carries a JSON sidecar with what the file itself often lost — the date the
/// photo was taken (WhatsApp images, screenshots and edited copies have no EXIF date), the
/// location, the description, the favourite flag, the people named in Google — and every
/// named folder is an album ("Photos from 2019" / "Fotos de 2019" are only year buckets).
///
/// The import walks the export and, for each photo:
///   - a photo the library already has (same bytes: sha256) is not copied again — it only
///     gains what the sidecar knows (album, favourite, location when it has none, words);
///   - a photo deleted in Photo Wagon (declined) or removed from it (quarantine) stays out;
///   - a new one is COPIED to <data>/google-photos (the export can be deleted afterwards) —
///     a library folder of its own: not under imports/, whose "remove what the phones sent"
///     must not take these, and flat, since a YYYY-MM folder would be read as the date —
///     its file time set to when it was taken, indexed with that date as the hint (EXIF and a
///     dated name still win), then given the sidecar's data.
/// The description and the people named in Google become keywords (searchable, shown under
/// the photo, carried to the user's other computers) — the library has no caption field,
/// and Google's names are not faces here (the face clusters are left alone).
/// Re-running is harmless (by content: what is there is only re-labelled); a report of every
/// count and every failure is written to <data>/takeout-report-<time>.json — the check before
/// deleting anything from Google Photos.
module photowagon.core.library.takeout;

import std.json;
import std.path : baseName, buildPath, dirName, extension, stripExtension;
import std.string : toLower, endsWith, startsWith, strip, indexOf, lastIndexOf;
import std.conv : to;
import std.algorithm : canFind, sort;

// ---- the export's shape (pure; tested) ------------------------------------------------------

/// What a sidecar says about its photo.
struct Sidecar
{
	string title;        // the original file name
	string description;
	long takenTs;        // unix seconds (negative before 1970: an old scan)
	bool hasTaken;       // takenTs is known
	bool hasGeo;
	double lat = 0, lon = 0;
	bool favorited;
	string[] people;
}

/// Reads a sidecar (photo metadata). Missing fields stay empty; 0,0 is no location.
Sidecar parseSidecar(JSONValue j)
{
	Sidecar s;
	if (j.type != JSONType.object)
		return s;
	string str(JSONValue o, string k)
	{
		if (o.type == JSONType.object)
			if (auto v = k in o)
				if (v.type == JSONType.string)
					return v.str;
		return null;
	}
	long ts(string k)
	{
		if (auto o = k in j)
			if (o.type == JSONType.object)
				if (auto t = "timestamp" in *o)
				{
					if (t.type == JSONType.string)
						try
							return t.str.to!long;
						catch (Exception)
							return 0;
					if (t.type == JSONType.integer)
						return t.integer;
				}
		return 0;
	}
	double num(JSONValue o, string k)
	{
		if (auto v = k in o)
		{
			if (v.type == JSONType.float_)
				return v.floating;
			if (v.type == JSONType.integer)
				return cast(double) v.integer;
		}
		return 0;
	}
	s.title = str(j, "title");
	s.description = str(j, "description").strip;
	s.takenTs = ts("photoTakenTime");
	s.hasTaken = s.takenTs != 0;
	// geoData is Google's (possibly edited) location, geoDataExif what the camera wrote
	foreach (k; ["geoData", "geoDataExif"])
		if (auto g = k in j)
			if (g.type == JSONType.object)
			{
				immutable la = num(*g, "latitude"), lo = num(*g, "longitude");
				if (la != 0 || lo != 0)
				{
					s.hasGeo = true;
					s.lat = la;
					s.lon = lo;
					break;
				}
			}
	if (auto f = "favorited" in j)
		s.favorited = f.type == JSONType.true_;
	if (auto ps = "people" in j)
		if (ps.type == JSONType.array)
			foreach (p; ps.array)
			{
				immutable n = str(p, "name").strip;
				if (n.length)
					s.people ~= n;
			}
	return s;
}

/// An album folder's own metadata file (its title): "metadata.json", "metadados.json",
/// "metadatos.json", "métadonnées.json", "Metadaten.json", "metadati.json" — and their "(1)"s.
bool isAlbumMetadataName(string lowerName)
{
	return lowerName.endsWith(".json") && (lowerName.startsWith("metada") || lowerName.startsWith("métadonn"));
}

/// A sidecar (photo) as opposed to an album's own metadata file.
bool isPhotoSidecar(JSONValue j)
{
	return j.type == JSONType.object && ("photoTakenTime" in j || "creationTime" in j || "geoData" in j);
}

/// "Photos from 2019", "Fotos de 2019", "Fotos von 2019", "Photos de 2019", "Foto dal 2019"…:
/// Google's year buckets, not albums.
bool isYearBucket(string folder)
{
	import std.array : split;

	auto w = folder.toLower.split(" ");
	if (w.length < 2 || w.length > 3)
		return false;
	immutable y = w[$ - 1];
	if (y.length != 4 || !(y.startsWith("19") || y.startsWith("20")))
		return false;
	foreach (c; y)
		if (c < '0' || c > '9')
			return false;
	if (!["photos", "fotos", "foto", "photo", "zdjęcia", "фото"].canFind(w[0]))
		return false;
	return w.length == 2 || ["from", "de", "von", "du", "dal", "del", "van", "uit", "z", "från", "fra", "из", "da"].canFind(w[1]);
}

/// Google's trash in the export: never imported.
bool isTrashFolder(string folder)
{
	return ["trash", "bin", "lixeira", "papelera", "corbeille", "papierkorb", "cestino", "prullenbak"]
		.canFind(folder.toLower);
}

/// Google's archive: its photos are imported, the folder is not an album.
bool isArchiveFolder(string folder)
{
	return ["archive", "arquivar", "arquivo", "archivo", "archiv", "archives", "archivio", "archief"]
		.canFind(folder.toLower);
}

private immutable string[] mediaExts = [
	".jpg", ".jpeg", ".png", ".webp", ".heic", ".heif", ".avif", ".tif", ".tiff", ".gif", ".bmp",
	".jxl", ".dng", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".raf", ".rw2",
	".mp4", ".mov", ".m4v", ".3gp", ".avi", ".mkv", ".webm", ".mts", ".m2ts", ".wmv", ".flv",
];

/// Suffixes Google gives an edited copy (it shares the original's sidecar).
private immutable string[] editedSuffixes = [
	"-editado", "-edited", "-editada", "-bearbeitet", "-modifié", "-modificato", "-bewerkt", "-edytowane",
];

/// "IMG(1).jpg" → ("IMG.jpg", 1); "IMG.jpg" → ("IMG.jpg", 0).
private string dupOf(string name, out int dup)
{
	dup = 0;
	immutable ext = name.extension;
	auto stem = name[0 .. $ - ext.length];
	if (stem.endsWith(")"))
	{
		immutable open = stem.lastIndexOf('(');
		if (open > 0)
		{
			auto digits = stem[open + 1 .. $ - 1];
			bool ok = digits.length > 0 && digits.length <= 3;
			foreach (c; digits)
				ok = ok && c >= '0' && c <= '9';
			if (ok)
			{
				dup = digits.to!int;
				return stem[0 .. open] ~ ext;
			}
		}
	}
	return name;
}

/// A sidecar's name → the media name it describes (possibly truncated) and its duplicate
/// number: "IMG.jpg.supplemental-metadata.json", "IMG.jpg.json", "IMG.jpg.supplemental-
/// metad.json" (truncated), "IMG.jpg(1).json", "IMG.jpg.supplemental-metadata(1).json",
/// "a_very_long_name_cut_at_forty_si.json" (no extension left).
private string sidecarKey(string jsonName, out int dup, out bool truncated)
{
	dup = 0;
	truncated = false;
	auto b = jsonName[0 .. $ - ".json".length];
	if (b.endsWith(")"))
	{
		immutable open = b.lastIndexOf('(');
		if (open > 0)
		{
			auto digits = b[open + 1 .. $ - 1];
			bool ok = digits.length > 0 && digits.length <= 3;
			foreach (c; digits)
				ok = ok && c >= '0' && c <= '9';
			if (ok)
			{
				dup = digits.to!int;
				b = b[0 .. open];
			}
		}
	}
	// the media extension ends the media name; whatever follows is Google's suffix
	immutable lower = b.toLower;
	ptrdiff_t best = -1;
	foreach (e; mediaExts)
	{
		ptrdiff_t at = -1, from = 0;
		for (;;)
		{
			immutable i = lower[from .. $].indexOf(e);
			if (i < 0)
				break;
			at = from + i;
			from = at + 1;
		}
		if (at < 0)
			continue;
		immutable ptrdiff_t end = at + cast(ptrdiff_t) e.length;
		// the extension must end the name or be followed by Google's "." suffix
		if (end == cast(ptrdiff_t) lower.length || lower[end] == '.')
			if (end > best)
				best = end;
	}
	if (best > 0)
		return b[0 .. best];
	truncated = true;   // cut before the extension (a long name)
	return b;
}

/// Pairs the media of one folder with their sidecars (file names only). Returns media name →
/// sidecar name for every media that has one. Handles the known shapes: exact, `(n)`
/// duplicates, edited copies sharing the original's, names Google truncated, and a live
/// photo's video sharing its still's (same stem).
string[string] pairSidecars(const(string)[] names)
{
	struct J { string name; string key; int dup; bool truncated; }
	J[] jsons;
	string[] media;
	foreach (n; names)
	{
		immutable l = n.toLower;
		if (l.endsWith(".json"))
		{
			if (isAlbumMetadataName(l) || l.startsWith("print-subscriptions")
				|| l.startsWith("shared_album_comments") || l.startsWith("user-generated-memory"))
				continue;
			J j;
			j.name = n;
			j.key = sidecarKey(n, j.dup, j.truncated);
			jsons ~= j;
		}
		else if (mediaExts.canFind(n.extension.toLower))
			media ~= n;
	}
	// indexes: the exact keys (as written and case-folded), the stems, the cut ones
	string[string] exactCase;        // key|dup → sidecar
	string[][string] exactLower;     // lower key|dup → sidecars
	string[][string] byStem;         // lower stem (no extension)|dup → sidecars
	J[] cut;                         // names Google cut before the extension, or long keys
	foreach (ref j; jsons)
	{
		immutable d = "|" ~ j.dup.to!string;
		if (j.truncated)
		{
			cut ~= j;
			continue;
		}
		exactCase[j.key ~ d] = j.name;
		exactLower[j.key.toLower ~ d] ~= j.name;
		byStem[j.key.toLower.stripExtension ~ d] ~= j.name;
		if (j.key.length >= 20)
			cut ~= j;   // a full name can still be the cut prefix of a longer media name
	}
	int[string] mediaLower;   // media names that differ only by case must match exactly
	foreach (m; media)
		mediaLower[m.toLower]++;

	string[string] out_;
	foreach (m; media)
	{
		int dup;
		immutable clean = dupOf(m, dup);
		immutable ext = clean.extension;
		immutable stem = clean[0 .. $ - ext.length];
		string orig = clean;
		foreach (suf; editedSuffixes)
			if (stem.toLower.endsWith(suf))
			{
				orig = stem[0 .. $ - suf.length] ~ ext;
				break;
			}
		immutable caseOnly = mediaLower[m.toLower] > 1;   // "A.jpg" next to "a.jpg"
		string exact(string name, int d)
		{
			immutable k = "|" ~ d.to!string;
			if (auto p = (name ~ k) in exactCase)
				return *p;
			if (caseOnly)
				return null;
			if (auto p = (name.toLower ~ k) in exactLower)
				if ((*p).length == 1)
					return (*p)[0];
			return null;
		}
		// 0. the literal name ("IMG (1).jpg" ↔ "IMG (1).jpg.supplemental-metadata.json"),
		// 1. the name without its duplicate number, 2. the original's, for an edited copy
		string found = exact(m, 0);
		if (found is null)
			found = exact(clean, dup);
		if (found is null && orig != clean)
			found = exact(orig, dup);
		if (found is null && !caseOnly)
		{
			// 3. a name Google cut: the longest sidecar key that is a prefix of this name —
			// and only if no other key of that length also fits (ambiguous: none)
			immutable cl = clean.toLower, ol = orig.toLower, sl = stem.toLower;
			size_t best;
			string pick;
			bool tie;
			foreach (ref j; cut)
			{
				if (j.dup != dup)
					continue;
				immutable k = j.key.toLower;
				immutable fits = j.truncated ? (sl.startsWith(k) || ol.startsWith(k))
					: (k.length < cl.length && cl.startsWith(k));
				if (!fits)
					continue;
				if (k.length > best)
				{
					best = k.length;
					pick = j.name;
					tie = false;
				}
				else if (k.length == best && j.name != pick)
					tie = true;
			}
			if (pick !is null && !tie)
				found = pick;
		}
		if (found is null && !caseOnly)
			// 4. a live photo's video (or another same-stem sibling): one candidate only
			if (auto p = (stem.toLower ~ "|" ~ dup.to!string) in byStem)
				if ((*p).length == 1)
					found = (*p)[0];
		if (found !is null)
			out_[m] = found;
	}
	return out_;
}

/// Whether a sidecar's `title` (the name the photo had in Google) can be this media file's:
/// the same name, or the same up to Google's duplicate number, its "-edited" suffix, a
/// truncation (20 characters in common at least) or the extension (a live photo's video).
/// A sidecar that fails this is not applied — wrong data is worse than none.
bool titleFits(string mediaName, string title)
{
	if (title.strip.length == 0)
		return true;   // nothing to check against
	static string norm(string s)
	{
		import std.array : appender;

		auto a = appender!string;
		foreach (dchar c; s.toLower)
			// Google replaces what a file name cannot hold (':' '/' an apostrophe …) with '_':
			// compare on letters, digits and dots only
			a.put((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '.' ? c : '_');
		return a.data;
	}
	immutable t = norm(title), m = norm(mediaName);
	if (t == m)
		return true;
	int dup;
	immutable clean = norm(dupOf(mediaName.toLower, dup));   // "(1)" off before '(' becomes '_'
	if (t == clean)
		return true;
	immutable ts = t.stripExtension, ms = clean.stripExtension;
	string me = ms;
	foreach (suf; editedSuffixes)
		if (ms.endsWith(norm(suf)))
		{
			me = ms[0 .. $ - norm(suf).length];
			break;
		}
	if (ts == ms || ts == me)
		return true;
	foreach (a; [ms, me])
	{
		immutable shorter = ts.length < a.length ? ts : a, longer = ts.length < a.length ? a : ts;
		if (shorter.length >= 20 && longer.startsWith(shorter))
			return true;
	}
	return false;
}

unittest
{
	auto p = pairSidecars([
		"IMG_20201230_222007.jpg", "IMG_20201230_222007.jpg.supplemental-metadata.json",
		"a.jpg", "a.jpg.json",
		"b.jpg", "b(1).jpg", "b.jpg.supplemental-metadata.json", "b.jpg.supplemental-metadata(1).json",
		"c(2).jpg", "c.jpg(2).json",
		"d-editado.jpg", "d.jpg", "d.jpg.supplemental-metadata.json",
		"e-edited.JPG", "e.JPG.json",
		"Screenshot_20190101-101010_WhatsApp.jpg", "Screenshot_20190101-101010_Wh.json",
		"PXL_20230105_183000123.MP.jpg", "PXL_20230105_183000123.MP.jpg.supplemental-metad.json",
		"IMG_1234.HEIC", "IMG_1234.MOV", "IMG_1234.HEIC.supplemental-metadata.json",
		"metadados.json", "orphan.png", "metadata(1).json",
		"20250831_120507.jpg", "20250831_120507.jpg.supplemental-metadata.json",
		"20250831_120507 (1).jpg", "20250831_120507 (1).jpg.supplemental-metadata.json",
	]);
	assert(p["IMG_20201230_222007.jpg"] == "IMG_20201230_222007.jpg.supplemental-metadata.json");
	assert(p["a.jpg"] == "a.jpg.json");
	assert(p["b.jpg"] == "b.jpg.supplemental-metadata.json");
	assert(p["b(1).jpg"] == "b.jpg.supplemental-metadata(1).json");
	assert(p["c(2).jpg"] == "c.jpg(2).json");
	assert(p["d-editado.jpg"] == "d.jpg.supplemental-metadata.json");
	assert(p["d.jpg"] == "d.jpg.supplemental-metadata.json");
	assert(p["e-edited.JPG"] == "e.JPG.json");
	assert(p["Screenshot_20190101-101010_WhatsApp.jpg"] == "Screenshot_20190101-101010_Wh.json");
	assert(p["PXL_20230105_183000123.MP.jpg"] == "PXL_20230105_183000123.MP.jpg.supplemental-metad.json");
	assert(p["IMG_1234.HEIC"] == "IMG_1234.HEIC.supplemental-metadata.json");
	assert(p["IMG_1234.MOV"] == "IMG_1234.HEIC.supplemental-metadata.json");
	assert("orphan.png" !in p);
	assert(isAlbumMetadataName("metadados.json") && isAlbumMetadataName("metadata(1).json")
		&& isAlbumMetadataName("métadonnées.json") && !isAlbumMetadataName("meta.jpg.json"));
	assert(p["20250831_120507 (1).jpg"] == "20250831_120507 (1).jpg.supplemental-metadata.json");
	assert(p["20250831_120507.jpg"] == "20250831_120507.jpg.supplemental-metadata.json");
	// ambiguous: two names cut to the same prefix get nothing; case twins only exact
	auto q = pairSidecars(["Screenshot_20190101-101010_WhatsApp.jpg", "Screenshot_20190101-101010_WhatsBiz.jpg",
		"Screenshot_20190101-101010_Wh.json", "A.jpg", "a.jpg", "A.jpg.json"]);
	assert(q.get("Screenshot_20190101-101010_WhatsApp.jpg", "") == "Screenshot_20190101-101010_Wh.json");
	assert(q.get("Screenshot_20190101-101010_WhatsBiz.jpg", "") == "Screenshot_20190101-101010_Wh.json");   // titleFits decides
	assert(q.get("A.jpg", "") == "A.jpg.json" && "a.jpg" !in q);
	assert(titleFits("Screenshot_20190101-101010_WhatsApp.jpg", "Screenshot_20190101-101010_WhatsApp.jpg"));
	assert(!titleFits("Screenshot_20190101-101010_WhatsBiz.jpg", "Screenshot_20190101-101010_WhatsApp.jpg"));
	assert(titleFits("IMG_1(1).jpg", "IMG_1.jpg") && titleFits("d-editada.jpg", "d.jpg") && titleFits("IMG_1234.MOV", "IMG_1234.HEIC"));
	assert(titleFits("a_b.jpg", "a:b.jpg") && titleFits("x.jpg", "") && !titleFits("x.jpg", "y.jpg"));
	assert(titleFits("Screenshot_20220219-063142_Cube Escape Harvey_s Box.jpg", "Screenshot_20220219-063142_Cube Escape Harvey's Box.jpg"));
	assert(titleFits("a_very_long_file_name_that_goog.jpg", "a_very_long_file_name_that_google_cut_short.jpg"));
}

unittest
{
	assert(isYearBucket("Fotos de 2019") && isYearBucket("Photos from 2011") && isYearBucket("Fotos von 2020"));
	assert(!isYearBucket("Natália - Sp") && !isYearBucket("2019") && !isYearBucket("Fotos de viagem"));
	assert(isArchiveFolder("Arquivar") && isTrashFolder("Lixeira") && !isArchiveFolder("demorô!"));

	auto s = parseSidecar(parseJSON(`{"title":"IMG.jpg","description":" praia ","photoTakenTime":{"timestamp":"1609377611"},
		"geoData":{"latitude":0.0,"longitude":0.0},"geoDataExif":{"latitude":-24.29083,"longitude":-46.977714},
		"favorited":true,"people":[{"name":"Patricia"},{"name":""}]}`));
	assert(s.title == "IMG.jpg" && s.description == "praia" && s.takenTs == 1_609_377_611);
	assert(s.hasGeo && s.lat == -24.29083 && s.lon == -46.977714 && s.favorited && s.people == ["Patricia"]);
	auto n = parseSidecar(parseJSON(`{"title":"x","geoData":{"latitude":0,"longitude":0}}`));
	assert(!n.hasGeo && n.takenTs == 0 && !n.hasTaken && !n.favorited);
	auto old = parseSidecar(parseJSON(`{"photoTakenTime":{"timestamp":"-141782400"}}`));   // 1965
	assert(old.hasTaken && old.takenTs == -141_782_400);
	assert(isPhotoSidecar(parseJSON(`{"photoTakenTime":{}}`)) && !isPhotoSidecar(parseJSON(`{"title":"Álbum"}`)));
}

// ---- the import ------------------------------------------------------------------------------

import vibe.core.core : runTask, yield;
import vibe.core.task : Task, InterruptException;
import vibe.core.log : logInfo, logWarn;
import vibe.core.sync : LocalManualEvent, createManualEvent;

import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.library.albums : AlbumRepo;
import photowagon.core.library.keywords : KeywordService;
import photowagon.core.library.roots : RootRepo;
import photowagon.core.indexer.indexer : Indexer;
import photowagon.core.ipc.events : Events;

/// One media file of the export, with where it sits and what describes it.
private struct Item
{
	string path;
	string sidecar;   // "" = none found
	string album;     // "" = not in an album folder
}

final class TakeoutImporter
{
	private string dataDir;
	private PhotoRepo photos;
	private AlbumRepo albums;
	private KeywordService keywords;
	private RootRepo roots;
	private Indexer indexer;
	private Events events;
	/// After a run (the places pass: cities for the locations just added).
	void delegate() onFinished;

	private bool running, cancelRequested;
	private JSONValue state;   // what takeout.status answers
	private Task task;         // the running import (close() stops and waits for it)

	this(string dataDir, PhotoRepo photos, AlbumRepo albums, KeywordService keywords, RootRepo roots,
		Indexer indexer, Events events)
	{
		this.dataDir = dataDir;
		this.photos = photos;
		this.albums = albums;
		this.keywords = keywords;
		this.roots = roots;
		this.indexer = indexer;
		this.events = events;
		state = JSONValue(["running": JSONValue(false)]);
	}

	JSONValue status()
	{
		return state;
	}

	void cancel()
	{
		if (running)
			cancelRequested = true;
	}

	/// The core is stopping: the import stops at once (interrupted) and is waited for, before
	/// the indexer and the database it writes to go away.
	void close() nothrow
	{
		cancelRequested = true;
		if (task != Task.init && task.running)
		{
			try
			{
				task.interrupt();
				task.joinUninterruptible();
			}
			catch (Exception)
			{
			}
		}
	}

	/// Starts importing the export at `path` (the folder the Takeout was unpacked into, or
	/// its "Google Photos" folder inside). Throws when one is already running or the folder
	/// does not exist.
	void start(string path)
	{
		import std.file : exists, isDir;
		import photowagon.core.ipc.protocol : ApiError;

		if (running)
			throw new ApiError("busy", "an import from Google Photos is already running");
		if (!path.exists || !path.isDir)
			throw new ApiError("not_found", "not a folder: " ~ path);
		running = true;
		cancelRequested = false;
		// visible at once: the export is read before the first photo (a big one takes a while)
		state = JSONValue(["running": JSONValue(true), "path": JSONValue(path), "total": JSONValue(0L),
			"done": JSONValue(0L), "phase": JSONValue("reading the export")]);
		task = runTask((string p) nothrow {
			try
				run(p);
			catch (Exception e)
			{
				try
					logWarn("takeout: import failed: %s", e.msg);
				catch (Exception)
				{
				}
				try
				{
					state["running"] = false;
					state["error"] = e.msg;
				}
				catch (Exception)
				{
				}
			}
			running = false;
		}, path);
	}

	private void run(string root)
	{
		import std.datetime.systime : Clock;
		import std.file : dirEntries, SpanMode, exists, isDir, readText, write;

		// ---- 1. the export: its folders, their media and sidecars (read on a worker: a big
		// export on a slow disk must not hold the core)
		import vibe.core.concurrency : async;

		auto found = parseJSON(async(&discover, root).getResult());
		if ("error" in found)
			throw new Exception(found["error"].str);
		Item[] items;
		foreach (x; found["items"].array)
			items ~= Item(x["p"].str, x["s"].str, x["a"].str);
		long[string] unsupported;
		foreach (k, v; found["unsupported"].object)
			unsupported[k] = v.integer;
		string[] skippedFolders;
		foreach (f; found["skipped"].array)
			skippedFolders ~= f.str;
		immutable long jsonFiles = found["json"].integer;
		if (cancelRequested)
		{
			// stopped while the export was read: say so (the UI waits on `running`)
			import std.datetime.systime : Clock;

			state["running"] = false;
			state["cancelled"] = true;
			state["finishedAt"] = Clock.currTime.toUnixTime;
			return;
		}

		// ---- 2. the report, kept current as the import goes
		JSONValue rep = JSONValue.emptyObject;
		foreach (k; ["media", "withSidecar", "withoutSidecar", "imported", "alreadyPresent",
				"skippedDeleted", "favorites", "locations", "keywords", "albumsCreated",
				"albumMemberships", "failuresTotal", "sidecarFiles", "sidecarMismatch"])
			rep[k] = 0L;
		rep["media"] = cast(long) items.length;
		rep["sidecarFiles"] = jsonFiles;
		foreach (ref it; items)
			rep[it.sidecar.length ? "withSidecar" : "withoutSidecar"] = rep[it.sidecar.length ? "withSidecar" : "withoutSidecar"].integer + 1;
		JSONValue uns = JSONValue.emptyObject;
		foreach (k, v; unsupported)
			uns[k] = v;
		rep["unsupported"] = uns;
		rep["skippedFolders"] = JSONValue(skippedFolders);
		JSONValue[] failures;
		immutable started = Clock.currTime.toUnixTime;
		state = JSONValue([
			"running": JSONValue(true), "path": JSONValue(root), "total": JSONValue(cast(long) items.length),
			"done": JSONValue(0L), "startedAt": JSONValue(started), "report": rep, "phase": JSONValue("importing"),
		]);
		logInfo("takeout: %s media (%s with a sidecar) in %s", items.length, rep["withSidecar"].integer, root);

		void bump(string k, long by = 1)
		{
			rep[k] = rep[k].integer + by;
		}
		void fail(string path, string why)
		{
			bump("failuresTotal");
			if (failures.length < 500)
				failures ~= JSONValue(["path": JSONValue(path), "reason": JSONValue(why)]);
		}

		// albums by name: an existing one of the same name is reused
		long[string] albumIds;
		foreach (a; albums.list())
			if ((a.name in albumIds) is null && a.originPeer is null)
				albumIds[a.name] = a.id;

		immutable importsRoot = buildPath(dataDir, "google-photos");   // (see the module comment)
		{
			import std.file : mkdirRecurse;

			mkdirRecurse(importsRoot);
		}
		immutable rootId = roots.add(importsRoot);
		auto lastEmit = Clock.currTime;
		long done;
		foreach (ref it; items)
		{
			if (cancelRequested)
				break;
			try
				importOne(it, rootId, importsRoot, albumIds, &bump, &fail);
			catch (InterruptException e)
				throw e;   // the core is stopping
			catch (Exception e)
				fail(it.path, e.msg);
			done++;
			state["done"] = done;
			state["report"] = rep;
			if ((Clock.currTime - lastEmit).total!"msecs" >= 1000)
			{
				lastEmit = Clock.currTime;
				if (events !is null)
					events.emit("takeout.progress", state);
			}
		}
		rep["failures"] = JSONValue(failures);
		state["report"] = rep;
		state["running"] = false;
		state["cancelled"] = cancelRequested;
		state["finishedAt"] = Clock.currTime.toUnixTime;
		immutable file = buildPath(dataDir, "takeout-report-" ~ started.to!string ~ ".json");
		try
		{
			write(file, state.toPrettyString);
			state["reportFile"] = file;
		}
		catch (Exception e)
			logWarn("takeout: cannot write the report: %s", e.msg);
		logInfo("takeout: done — %s new, %s already here, %s kept out (deleted in Photo Wagon), %s failed%s",
			rep["imported"].integer, rep["alreadyPresent"].integer, rep["skippedDeleted"].integer,
			rep["failuresTotal"].integer, cancelRequested ? " (cancelled)" : "");
		if (events !is null)
		{
			events.emit("takeout.progress", state);
			events.emit("library.changed", JSONValue.emptyObject);
			events.emit("keywords.changed", JSONValue.emptyObject);
		}
		if (onFinished !is null)
			try
				onFinished();
			catch (Exception e)
				logWarn("takeout: after the import: %s", e.msg);
	}

	private void importOne(ref Item it, long rootId, string importsRoot, ref long[string] albumIds,
		void delegate(string, long) bump, void delegate(string, string) fail)
	{
		import std.file : exists, readText, getSize, mkdirRecurse, timeLastModified;
		import vibe.core.concurrency : async;
		import photowagon.core.util.fastsha : fileSha256;
		import photowagon.core.api.import_api : keepTimes;

		Sidecar sc;
		if (it.sidecar.length)
			try
			{
				sc = parseSidecar(parseJSON(readText(it.sidecar)));
				// a sidecar whose title is not this photo's is not applied: wrong data is
				// worse than none (a name Google cut, shared by two photos)
				if (!titleFits(it.path.baseName, sc.title))
				{
					sc = Sidecar.init;
					bump("sidecarMismatch", 1);
				}
			}
			catch (Exception e)
				fail(it.sidecar, "unreadable sidecar: " ~ e.msg);

		immutable hash = async(&fileSha256, it.path).getResult();
		if (hash.length != 64)
		{
			fail(it.path, "cannot read the file");
			return;
		}
		if (photos.isDeclined(hash) || photos.isRemoved(hash))
		{
			bump("skippedDeleted", 1);
			return;
		}
		auto existing = photos.byHash(hash);
		// "already here" means the file is really here: a row with no file (a photo seen
		// through another device's shared album) or whose file went missing behind our back is
		// not — the Takeout copy is imported
		if (existing.isNull || !photos.holdsHash(hash))
		{
			// the copy: <imports>/google-photos/YYYY-MM/<name>, the file time = taken
			long when = sc.takenTs;
			bool dated = sc.hasTaken;
			if (!dated)
				try
				{
					when = timeLastModified(it.path).toUnixTime;
					dated = true;
				}
				catch (Exception)
				{
				}
			immutable dir = importsRoot;
			immutable dest = async(&placeFor, dir, it.path.baseName, hash).getResult();
			if (!dest.exists)
			{
				import std.file : rename, remove;

				immutable tmp = dest ~ ".takeout-part";
				try
				{
					cast(void) async(&copyFile, it.path, tmp).getResult();
					rename(tmp, dest);
				}
				catch (Exception e)
				{
					try
						if (tmp.exists)
							remove(tmp);   // no half copy left behind (a full disk, a stop)
					catch (Exception)
					{
					}
					throw e;
				}
			}
			// the file time: when it was taken (sidecar), else the export file's own time
			if (sc.hasTaken)
				keepTimes(dest, sc.takenTs * 1000);   // (a time before 1990 is left alone by keepTimes)
			else if (dated)
				keepTimes(dest, when * 1000);
			// index it (the sidecar's date as the hint) and wait for the row
			auto ev = createManualEvent();
			bool landed;
			immutable c = ev.emitCount;
			indexer.indexOne(rootId, dest, () { landed = true; ev.emit(); }, sc.hasTaken ? sc.takenTs : 0);
			// the index pass waits its turn on the job lane: bounded, and a stop ends the wait
			import core.time : minutes, seconds;
			import std.datetime.systime : Clock;

			immutable deadline = Clock.currTime + 30.minutes;
			auto cnt = cast() c;
			while (!landed && !cancelRequested && Clock.currTime < deadline)
				cnt = ev.wait(5.seconds, cnt);
			if (!landed)
				throw new Exception(cancelRequested ? "stopped" : "not indexed in time");
			// the row of THIS copy — or, if the index kept another file of this content, that
			// file really on disk; a row still without a good file means the index failed
			existing = photos.byPath(dest);
			if (existing.isNull && photos.holdsHash(hash))
				existing = photos.byHash(hash);
			if (existing.isNull)
			{
				fail(it.path, "copied but not indexed (unreadable, or not a photo or video Photo Wagon can read)");
				return;
			}
			bump("imported", 1);
		}
		else
			bump("alreadyPresent", 1);

		immutable id = existing.get.id;
		// what the sidecar knows
		if (sc.favorited && !existing.get.favorite)
		{
			photos.setFavorite(id, true);
			bump("favorites", 1);
		}
		if (sc.hasGeo && photos.setLocationIfMissing(id, sc.lat, sc.lon))
			bump("locations", 1);
		string[] words;
		if (sc.description.length)
			words ~= sc.description;
		words ~= sc.people;
		if (words.length)
		{
			immutable before = keywords.ofPhoto(id).length;
			keywords.add([id], words, /*fromUser*/ false);   // the library only: the file stays as Google gave it
			immutable after = keywords.ofPhoto(id).length;
			if (after > before)
				bump("keywords", cast(long)(after - before));
		}
		if (it.album.length)
		{
			long aid;
			if (auto a = it.album in albumIds)
				aid = *a;
			else
			{
				aid = albums.create(it.album);
				albumIds[it.album] = aid;
				bump("albumsCreated", 1);
			}
			if (!albums.contains(aid, id))
			{
				albums.addPhotos(aid, [id]);
				bump("albumMemberships", 1);
			}
		}
	}
}

/// Reads the export (a worker's job: no library access): its media with their sidecars and
/// albums, what is not a photo, the folders skipped. Symbolic links are not followed — an
/// export must not reach outside itself. Returns JSON (strings cross threads safely).
private string discover(string root)
{
	import std.file : dirEntries, SpanMode, readText;

	try
	{
		string[] dirs = [root];
		foreach (e; dirEntries(root, SpanMode.breadth, false))
			if (!e.isSymlink && e.isDir)
				dirs ~= e.name;
		dirs.sort();
		JSONValue[] items;
		long[string] unsupported;
		string[] skipped;
		long jsonFiles;
		foreach (d; dirs)
		{
			immutable folder = d.baseName;
			if (isTrashFolder(folder))
			{
				skipped ~= folder;
				continue;
			}
			string[] names;
			try
				foreach (e; dirEntries(d, SpanMode.shallow, false))
					if (!e.isSymlink && e.isFile)
						names ~= e.name.baseName;
			catch (Exception)
				continue;
			names.sort();
			// an album: a named folder that is not a year bucket, the archive or the root
			string album;
			if (d != root && !isYearBucket(folder) && !isArchiveFolder(folder) && folder != "Google Photos"
				&& folder != "Google Fotos" && folder != "Takeout")
			{
				album = folder;
				foreach (n; names)
					if (isAlbumMetadataName(n.toLower))
						try
						{
							auto j = parseJSON(readText(buildPath(d, n)));
							if (!isPhotoSidecar(j) && "title" in j && j["title"].type == JSONType.string
								&& j["title"].str.strip.length)
								album = j["title"].str.strip;
						}
						catch (Exception)
						{
						}
			}
			auto pairs = pairSidecars(names);
			foreach (n; names)
			{
				immutable ext = n.extension.toLower;
				if (ext == ".json")
				{
					jsonFiles++;
					continue;
				}
				if (!mediaExts.canFind(ext))
				{
					unsupported[ext.length ? ext : "(none)"]++;
					continue;
				}
				auto sc = n in pairs;
				items ~= JSONValue(["p": JSONValue(buildPath(d, n)), "s": JSONValue(sc ? buildPath(d, *sc) : ""),
					"a": JSONValue(album)]);
			}
		}
		JSONValue uns = JSONValue.emptyObject;
		foreach (k, v; unsupported)
			uns[k] = v;
		return JSONValue(["items": JSONValue(items), "unsupported": uns, "skipped": JSONValue(skipped),
			"json": JSONValue(jsonFiles)]).toString;
	}
	catch (Exception e)
		return JSONValue(["error": JSONValue("cannot read " ~ root ~ ": " ~ e.msg)]).toString;
}

/// Where a copy of `name` with content `hash` goes in `dir`: its own name when free or when
/// the file there already is this content (an import resumed after a crash), else "name (n)".
private string placeFor(string dir, string name, string hash)
{
	import std.file : exists;
	import photowagon.core.util.fastsha : fileSha256;

	immutable ext = name.extension;
	immutable stem = name[0 .. $ - ext.length];
	for (int n = 0; n < 10_000; n++)
	{
		immutable cand = buildPath(dir, n == 0 ? name : stem ~ " (" ~ n.to!string ~ ")" ~ ext);
		if (!cand.exists || fileSha256(cand) == hash)
			return cand;
	}
	throw new Exception("no free name for " ~ name ~ " in " ~ dir);
}

/// A copy streamed by the OS (off the event loop: run through `async`).
private bool copyFile(string from, string to)
{
	import std.file : copy;

	copy(from, to);
	return true;
}
