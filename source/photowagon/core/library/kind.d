/// What kind of picture a file is: a photograph, a screenshot, or a meme
/// (anything downloaded or drawn: images with text, stickers, graphics).
///
/// No model, just the signals that separate them in practice: a camera in the
/// EXIF means a photograph; a screen-sized image, a "Screenshots" folder or a
/// "Screenshot_" name means a screenshot; among the rest, the look of the
/// pixels decides — memes have flat colour areas, few distinct colours, lots
/// of white, hard edges from text. Thresholds were tuned on a real library.
module photowagon.core.library.kind;

import std.path : baseName, dirName;
import std.string : toLower, indexOf, startsWith, endsWith;

import photowagon.core.thumbs.vips : ImageStats;

enum Kind : string
{
	photo = "photo",
	screenshot = "screenshot",
	meme = "meme",
}

struct Signals
{
	string path;
	int width;
	int height;
	bool hasCamera;
	ImageStats stats;
}

/// Widths of phone/tablet/desktop screens; a screenshot is one of these on
/// its short side, with no camera metadata.
immutable int[] screenShorts = [
	540, 640, 720, 750, 768, 800, 828, 900, 1080, 1125, 1170, 1179, 1200, 1206, 1242, 1284, 1290, 1320,
	1440, 1536, 1600, 1620, 1668, 1800, 1920, 2048, 2160, 2560
];

bool looksScreenSized(int w, int h) pure nothrow @nogc
{
	immutable short_ = w < h ? w : h;
	immutable long_ = w < h ? h : w;
	if (long_ < 800)
		return false;
	foreach (s; screenShorts)
		if (s == short_)
			return true;
	return false;
}

Kind classify(ref const Signals s) pure
{
	immutable name = s.path.baseName.toLower;
	immutable dir = s.path.dirName.toLower;
	if (dir.indexOf("screenshot") >= 0 || name.startsWith("screenshot") || name.startsWith("screen_"))
		return Kind.screenshot;
	if (s.hasCamera)
		return Kind.photo;
	immutable g = graphic(s.stats);
	// a screen-sized graphic is a screenshot; a screen-sized photograph is a photograph
	// someone saved from a screen, which is still a photograph
	if (looksScreenSized(s.width, s.height) && (name.endsWith(".png") || g))
		return Kind.screenshot;
	return g ? Kind.meme : Kind.photo;
}

/// A drawn or composed image rather than a photograph: a logistic model over
/// the pixel statistics, fitted on a real library with camera-tagged photos
/// against its Screenshots folder (3 % of photographs flagged, 90 % of
/// screenshots caught, cross-validated). The statistics must come from the
/// original file: a re-compressed thumbnail turns noise into flat plateaus.
bool graphic(ref const ImageStats st) pure nothrow @nogc
{
	if (!st.ok)
		return false;
	return graphicScore(st) >= graphicThreshold;
}

enum graphicThreshold = 0.582f;

/// Probability-like score in 0..1; above `graphicThreshold` it is a graphic.
float graphicScore(ref const ImageStats st) pure nothrow @nogc
{
	import std.math : exp;

	immutable z = 16.5094f * st.flatFraction + 0.2683f * st.dominantFraction + 56.5365f * st.uniqueFraction
		+ 5.1302f * st.meanSaturation + 29.405f * st.edgeDensity + 0.3268f * st.lightFraction
		+ 2.0579f * st.darkFraction - 8.1859f;
	return 1 / (1 + exp(-z));
}

/// Bump when the rules or the model change: automatic kinds are redone at startup.
enum kindVersion = 3;

unittest
{
	// a photograph: little flatness, few hard edges; a meme: flat, edgy
	ImageStats photoLike = {ok: true, dominantFraction: 0.09, uniqueFraction: 0.04, meanSaturation: 0.24, edgeDensity: 0.09, lightFraction: 0.0, darkFraction: 0.02, flatFraction: 0.09};
	ImageStats memeLike = {ok: true, dominantFraction: 0.40, uniqueFraction: 0.03, meanSaturation: 0.15, edgeDensity: 0.16, lightFraction: 0.3, darkFraction: 0.1, flatFraction: 0.5};
	assert(!graphic(photoLike) && graphic(memeLike));
	Signals a = {path: "/x/IMG_1.jpg", width: 4000, height: 3000, hasCamera: true, stats: memeLike};
	assert(classify(a) == Kind.photo); // the camera wins
	Signals b = {path: "/x/Screenshots/Screenshot_2024.jpg", width: 1080, height: 2400, stats: photoLike};
	assert(classify(b) == Kind.screenshot);
	Signals c = {path: "/x/IMG-2024-WA0001.jpg", width: 1080, height: 2400, stats: memeLike};
	assert(classify(c) == Kind.screenshot); // screen-sized and graphic
	Signals c2 = {path: "/x/IMG-2024-WA0009.jpg", width: 1080, height: 2400, stats: photoLike};
	assert(classify(c2) == Kind.photo); // screen-sized but a photograph
	Signals d = {path: "/x/IMG-2024-WA0002.jpg", width: 1280, height: 960, stats: memeLike};
	assert(classify(d) == Kind.meme);
	Signals e = {path: "/x/IMG-2024-WA0003.jpg", width: 1280, height: 960, stats: photoLike};
	assert(classify(e) == Kind.photo);
	assert(looksScreenSized(1080, 2400) && !looksScreenSized(4000, 3000));
}
