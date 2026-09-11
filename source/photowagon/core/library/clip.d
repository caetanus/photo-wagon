/// The CLIP ViT-B/32 image encoder through the C++ shim (csrc/clip_opencv).
/// `clipEncode` is a plain function of a path returning a value: it runs on a
/// worker thread via `async`, and the shim serialises calls itself.
module photowagon.core.library.clip;

import std.string : toStringz;

private extern (C) nothrow @nogc
{
	int pw_clip_init(const char* onnx);
	int pw_clip_encode(const char* path, float* out512);
}

enum clipDim = 512;

/// Loads the model once. Throws if OpenCV cannot read it.
void initClip(string onnxPath)
{
	if (pw_clip_init(onnxPath.toStringz) != 0)
		throw new Exception("cannot load the CLIP image model (" ~ onnxPath ~ ")");
}

/// Unit-length embedding of the image at `path`; throws when it cannot be read.
float[clipDim] clipEncode(string path)
{
	float[clipDim] e = void;
	if (pw_clip_encode(path.toStringz, e.ptr) != 0)
		throw new Exception("CLIP encoding failed for " ~ path);
	return e;
}
