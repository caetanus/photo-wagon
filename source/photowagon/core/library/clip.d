/// The CLIP ViT-B/32 image encoder, through the vision worker (core/vision/worker.d):
/// the model's gigabyte lives in a child process for the length of a pass.
module photowagon.core.library.clip;

import std.array : split;
import std.conv : to;

import photowagon.core.vision.worker : startVision, releaseVision, visionRequest;

enum clipDim = 512;

/// Starts the worker (the model itself loads on the first request).
void initClip(string onnxPath)
{
	cast(void) onnxPath;   // the worker knows its models from the daemon's configuration
	startVision();
}

/// Ends the worker: its memory goes back to the system.
void releaseClip() nothrow
{
	releaseVision();
}

/// Unit-length embedding of the image at `path`; throws when it cannot be read.
float[clipDim] clipEncode(string path)
{
	auto parts = visionRequest("clip " ~ path).split(' ');
	if (parts.length != clipDim)
		throw new Exception("CLIP worker: wrong embedding size for " ~ path);
	float[clipDim] e;
	foreach (i, p; parts)
		e[i] = p.to!float;
	return e;
}
