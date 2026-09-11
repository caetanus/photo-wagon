/// `edit.*` and `photo.preview / applyEdits / revertEdits / saveCopy` of docs/ipc.md:
/// filters, adjustments, rotation and crop, rendered by the core (thumbs/vips.d)
/// and never written into the original file.
module photowagon.core.api.edit_api;

import std.conv : to;
import std.file : exists, mkdirRecurse, remove, write, dirEntries, SpanMode;
import std.json;
import std.path : baseName, buildPath, dirName, extension, stripExtension;

import vibe.core.concurrency : async;

import photowagon.core.jobs.scheduler : jobs;
import vibe.core.log : logInfo, logWarn;

import photowagon.core.config : Config;
import photowagon.core.edit.edits : Edits, Preset, presets, withPreset;
import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.protocol;
import photowagon.core.library.calendar : fileUrl;
import photowagon.core.library.photos : Photo, PhotoRepo;
import photowagon.core.store.store : ContentStore;
import photowagon.core.thumbs.vips : renderEdited, thumbnailOfBytes, jpegSize;

/// Longest edge of a preview in the viewer; the filter strip asks for much less.
enum previewEdge = 1600;

/// `renderEdited` for `async`, whose arguments must stay small: the edits travel as JSON.
private ubyte[] renderJson(string source, string editsJson, int maxEdge, int quality)
{
	return renderEdited(source, Edits.fromJson(parseJSON(editsJson)), maxEdge, quality);
}

void registerEditApi(Registry r, Config cfg, PhotoRepo photos, ContentStore store, Events events,
		void delegate(string path) fileAdded = null)
{
	immutable previewDir = buildPath(cfg.runtimeDir, "preview");
	try
	{
		mkdirRecurse(previewDir);
		foreach (f; dirEntries(previewDir, SpanMode.shallow))
			remove(f.name);   // last session's leftovers
	}
	catch (Exception)
	{
	}
	long seq;

	Edits editsOf(JSONValue p)
	{
		return p.type == JSONType.object && "edits" in p ? Edits.fromJson(p["edits"]) : Edits.init;
	}

	Photo local(JSONValue p)
	{
		auto photo = photos.get(requireLong(p, "id"));
		if (photo.path is null || !photo.path.exists)
			throw new ApiError("not_found", "the original is not on this machine");
		return photo;
	}

	/// A preview file for the viewer; the previous one of the same photo is dropped.
	string writePreview(long id, const(ubyte)[] bytes, string tag = "")
	{
		immutable name = id.to!string ~ (tag.length ? "-" ~ tag : "") ~ "-" ~ (++seq).to!string ~ ".jpg";
		immutable path = buildPath(previewDir, name);
		write(path, bytes);
		if (!tag.length)
			try
				foreach (f; dirEntries(previewDir, id.to!string ~ "-[0-9]*.jpg", SpanMode.shallow))
					if (f.name != path)
						remove(f.name);
			catch (Exception)
			{
			}
		return fileUrl(path);
	}

	// → {presets: [{name, edits}]}
	r.add("edit.presets", (JSONValue p) {
		JSONValue[] out_;
		foreach (pr; presets())
			out_ ~= JSONValue(["name": JSONValue(pr.name), "edits": pr.edits.toJson()]);
		return JSONValue(["presets": JSONValue(out_)]);
	});

	// {id, edits, maxEdge?} → {url, width, height}: what the edits look like, rendered by the core
	r.add("photo.preview", (JSONValue p) {
		auto photo = local(p);
		auto e = editsOf(p);
		immutable maxEdge = cast(int) getLong(p, "maxEdge", previewEdge);
		auto bytes = jobs.foreground({ return async(&renderJson, photo.path, e.toJson().toString(), maxEdge < 64 ? 64 : (maxEdge > 4096 ? 4096 : maxEdge), 88).getResult(); });
		auto size = jpegSize(bytes);
		return JSONValue(["url": JSONValue(writePreview(photo.id, bytes)), "width": JSONValue(size[0]), "height": JSONValue(size[1])]);
	});

	// {id, edits?, maxEdge?} → {items: [{name, url, edits}]}: every filter on this photo, small,
	// with the photo's current geometry (rotation, crop) kept
	r.add("photo.presetPreviews", (JSONValue p) {
		auto photo = local(p);
		auto current = editsOf(p);
		immutable maxEdge = cast(int) getLong(p, "maxEdge", 160);
		JSONValue[] out_;
		foreach (pr; presets())
		{
			auto e = withPreset(current, pr);
			auto bytes = jobs.foreground({ return async(&renderJson, photo.path, e.toJson().toString(), maxEdge < 32 ? 32 : (maxEdge > 512 ? 512 : maxEdge), 80).getResult(); });
			out_ ~= JSONValue(["name": JSONValue(pr.name), "url": JSONValue(writePreview(photo.id, bytes, "p" ~ pr.name)), "edits": e.toJson()]);
		}
		return JSONValue(["items": JSONValue(out_)]);
	});

	// {id, edits} → Photo: renders the result at full size into the store, re-thumbnails,
	// keeps the edits; identity edits revert
	r.add("photo.applyEdits", (JSONValue p) {
		auto photo = local(p);
		auto e = editsOf(p);
		if (e.isIdentity())
		{
			revert(photos, cfg, photo);
			events.emit("library.changed", JSONValue.emptyObject);
			auto now = photos.get(photo.id);
			return photos.toJson(now);
		}
		auto bytes = jobs.foreground({ return async(&renderJson, photo.path, e.toJson().toString(), 0, 92).getResult(); });
		immutable hash = store.put(bytes);
		auto thumb = thumbnailOfBytes(bytes, cfg.storeDir, cfg.thumbSize);
		if (!thumb.ok)
			throw new ApiError("internal", "thumbnail: " ~ thumb.error);
		auto size = jpegSize(bytes);
		photos.setEdits(photo.id, e.toJson().toString(), hash, thumb.hash, size[0], size[1]);
		logInfo("edit: photo %s saved with %s (%s×%s)", photo.id, e.preset.length ? e.preset : "adjustments", size[0], size[1]);
		events.emit("library.changed", JSONValue.emptyObject);
		auto now = photos.get(photo.id);
		return photos.toJson(now);
	});

	// {id} → Photo: back to the original
	r.add("photo.revertEdits", (JSONValue p) {
		auto photo = local(p);
		revert(photos, cfg, photo);
		events.emit("library.changed", JSONValue.emptyObject);
		auto now = photos.get(photo.id);
		return photos.toJson(now);
	});

	// {id, edits?} → {path}: a JPEG next to the original ("name-edited.jpg"), indexed like any file
	r.add("photo.saveCopy", (JSONValue p) {
		auto photo = local(p);
		Edits e = "edits" in p ? editsOf(p) : (photo.edits.length ? Edits.fromJson(parseJSON(photo.edits)) : Edits.init);
		auto bytes = jobs.foreground({ return async(&renderJson, photo.path, e.toJson().toString(), 0, 92).getResult(); });
		immutable dir = photo.path.dirName, base = photo.path.baseName.stripExtension;
		string target = buildPath(dir, base ~ "-edited.jpg");
		for (int n = 2; target.exists; n++)
			target = buildPath(dir, base ~ "-edited-" ~ n.to!string ~ ".jpg");
		write(target, bytes);
		logInfo("edit: copy of photo %s written to %s", photo.id, target);
		if (fileAdded !is null)
			fileAdded(target);
		return JSONValue(["path": JSONValue(target)]);
	});
}

private void revert(PhotoRepo photos, Config cfg, ref Photo photo)
{
	import photowagon.core.thumbs.vips : makeThumbnail;

	if (photo.editedHash is null && photo.edits is null)
		return;
	auto thumb = jobs.foreground({ return async(&makeThumbnail, photo.path, cfg.storeDir, cfg.thumbSize).getResult(); });
	if (!thumb.ok)
		throw new ApiError("internal", "thumbnail: " ~ thumb.error);
	immutable swap = photo.orientation >= 5;
	photos.setEdits(photo.id, null, null, thumb.hash, swap ? thumb.srcHeight : thumb.srcWidth, swap ? thumb.srcWidth : thumb.srcHeight);
	logInfo("edit: photo %s reverted", photo.id);
}
