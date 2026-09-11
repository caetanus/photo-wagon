/// Face detection + embedding through the vision worker (core/vision/worker.d):
/// OpenCV runs in a child process for the length of a pass. `detectFaces` is a
/// plain function of value types: it runs on a worker thread via `async`.
module photowagon.core.faces.detect;

import std.array : split;
import std.conv : to;

import photowagon.core.vision.worker : visionRequest;

/// One detected face: box as fractions of the (rotated) image, SFace feature.
struct FaceHit
{
	float x, y, w, h;
	float score;
	float[128] embedding;
}

/// SFace's published cosine threshold for "same person".
enum sameFaceCosine = 0.363f;

/// Longest edge the detector works on; larger photos are downscaled first.
enum detectMaxEdge = 1280;

/// Checks that the models are there (the worker loads them on its first face).
void initFaces(string yunetPath, string sfacePath)
{
	import std.file : exists;

	if (!yunetPath.exists || !sfacePath.exists)
		throw new Exception("cannot find the face models (" ~ yunetPath ~ ", " ~ sfacePath ~ ")");
}

/// Faces in `path`, or an empty array; throws when the image cannot be read.
/// `edgeHint` is the picture's longest edge when known (0 otherwise): a big JPEG
/// is then decoded reduced instead of in full.
immutable(FaceHit)[] detectFaces(string path, int edgeHint = 0)
{
	auto parts = visionRequest("face " ~ detectMaxEdge.to!string ~ " " ~ edgeHint.to!string ~ " " ~ path).split(' ');
	if (!parts.length)
		throw new Exception("face detection: empty answer for " ~ path);
	immutable n = parts[0].to!int;
	enum per = 5 + 128;
	if (parts.length != 1 + n * per)
		throw new Exception("face detection: malformed answer for " ~ path);
	FaceHit[] hits;
	hits.reserve(n);
	foreach (i; 0 .. n)
	{
		auto f = parts[1 + i * per .. 1 + (i + 1) * per];
		FaceHit h;
		h.x = f[0].to!float;
		h.y = f[1].to!float;
		h.w = f[2].to!float;
		h.h = f[3].to!float;
		h.score = f[4].to!float;
		foreach (k; 0 .. 128)
			h.embedding[k] = f[5 + k].to!float;
		hits ~= h;
	}
	return cast(immutable) hits;
}

/// Cosine similarity of two embeddings.
float cosine(const ref float[128] a, const ref float[128] b) pure nothrow @nogc
{
	import std.math : sqrt;

	double dot = 0, na = 0, nb = 0;
	foreach (i; 0 .. 128)
	{
		dot += cast(double) a[i] * b[i];
		na += cast(double) a[i] * a[i];
		nb += cast(double) b[i] * b[i];
	}
	immutable d = sqrt(na) * sqrt(nb);
	return d < 1e-12 ? 0 : cast(float)(dot / d);
}

unittest
{
	float[128] a = 0, b = 0;
	a[0] = 1;
	b[0] = 1;
	assert(cosine(a, b) > 0.999);
	b[0] = 0;
	b[1] = 1;
	assert(cosine(a, b) < 0.001);
}
