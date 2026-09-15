/// Video thumbnails and metadata through ffmpeg/ffprobe, into the content store.
/// Like `makeThumbnail`, a plain function of value types so it runs on a worker.
module photowagon.core.thumbs.video;

import std.array : split;
import std.conv : to;
import std.process : execute, pipeProcess, Redirect, wait;
import std.string : splitLines, strip;

import photowagon.core.store.store : storeBytes;

struct VideoInfo
{
	bool ok;
	string hash; // sha256 of the thumbnail JPEG in the store
	int width;
	int height;
	long durationMs;
	string error;
}

/// Probes the video and extracts one frame as the thumbnail (longest edge `size`),
/// stored as JPEG. Needs `ffprobe` and `ffmpeg` on PATH.
VideoInfo makeVideoThumbnail(string source, string storeRoot, int size)
{
	VideoInfo r;

	// dimensions + duration
	auto probe = execute([
		"ffprobe", "-v", "error", "-select_streams", "v:0",
		"-show_entries", "stream=width,height:format=duration",
		"-of", "default=noprint_wrappers=1:nokey=0", source
	]);
	if (probe.status != 0)
	{
		r.error = "ffprobe: " ~ probe.output;
		return r;
	}
	double dur = 0;
	foreach (line; probe.output.splitLines)
	{
		auto kv = line.split("=");
		if (kv.length != 2)
			continue;
		try
		{
			if (kv[0] == "width")
				r.width = kv[1].strip.to!int;
			else if (kv[0] == "height")
				r.height = kv[1].strip.to!int;
			else if (kv[0] == "duration")
				dur = kv[1].strip.to!double;
		}
		catch (Exception)
		{
		}
	}
	r.durationMs = cast(long)(dur * 1000);

	// a frame a little way in (a black first frame is common), scaled to `size` longest edge
	immutable at = dur > 2 ? "1" : (dur > 0 ? (dur / 2).to!string : "0");
	immutable s = size.to!string;
	immutable vf = "scale='if(gt(iw,ih)," ~ s ~ ",-2)':'if(gt(iw,ih),-2," ~ s ~ ")'";
	auto p = pipeProcess([
		"ffmpeg", "-v", "error", "-ss", at, "-i", source,
		"-frames:v", "1", "-vf", vf, "-f", "mjpeg", "-q:v", "4", "pipe:1"
	], Redirect.stdout);
	ubyte[] data;
	foreach (chunk; p.stdout.byChunk(65536))
		data ~= chunk;
	immutable status = wait(p.pid);
	if (status != 0 || data.length == 0)
	{
		r.error = "ffmpeg: no frame";
		return r;
	}
	r.hash = storeBytes(storeRoot, data);
	r.ok = true;
	return r;
}
