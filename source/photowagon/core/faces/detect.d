/// Face detection + embedding through the one C++ shim (csrc/face_opencv).
/// `detectFaces` is a plain function of a path returning value types: it runs
/// on a worker thread via `async`, and the shim serialises calls itself.
module photowagon.core.faces.detect;

import std.string : toStringz;

private extern (C) nothrow @nogc
{
	struct PwFace
	{
		float x, y, w, h;
		float score;
		float[128] embedding;
	}

	int pw_face_init(const char* yunet, const char* sface);
	int pw_face_detect(const char* path, int maxEdge, PwFace* out_, int maxFaces);
}

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

/// Loads the models once. Throws if OpenCV cannot read them.
void initFaces(string yunetPath, string sfacePath)
{
	if (pw_face_init(yunetPath.toStringz, sfacePath.toStringz) != 0)
		throw new Exception("cannot load the face models (" ~ yunetPath ~ ", " ~ sfacePath ~ ")");
}

/// Faces in `path`, or an empty array; throws when the image cannot be read.
immutable(FaceHit)[] detectFaces(string path)
{
	PwFace[64] raw = void;
	immutable n = pw_face_detect(path.toStringz, detectMaxEdge, raw.ptr, cast(int) raw.length);
	if (n < 0)
		throw new Exception("face detection failed for " ~ path);
	FaceHit[] hits;
	hits.reserve(n);
	foreach (i; 0 .. n)
	{
		FaceHit h;
		h.x = raw[i].x;
		h.y = raw[i].y;
		h.w = raw[i].w;
		h.h = raw[i].h;
		h.score = raw[i].score;
		h.embedding = raw[i].embedding;
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
