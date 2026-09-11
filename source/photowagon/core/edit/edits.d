/// Non-destructive edits: what the user did to a photo, as a small value the
/// core renders (thumbs/vips.d `renderEdited`) and stores next to the photo as
/// JSON. The original file is never touched; "Save" keeps a rendered copy in
/// the store and points the thumbnail at it, "Revert" forgets everything.
module photowagon.core.edit.edits;

import std.json;
import std.math : abs;

struct Edits
{
	int rotate;          // 0, 90, 180, 270 — clockwise, applied first
	bool flipH, flipV;   // after the rotation
	double cropX = 0, cropY = 0, cropW = 0, cropH = 0; // fractions of the rotated image; w/h 0 = no crop
	double brightness = 0;  // -1 .. 1
	double contrast = 0;    // -1 .. 1
	double saturation = 0;  // -1 (grey) .. 1
	double warmth = 0;      // -1 (cool) .. 1 (warm)
	double fade = 0;        // 0 .. 1: lifted blacks, softer
	double vignette = 0;    // 0 .. 1
	double sharpen = 0;     // 0 .. 1
	double sepia = 0;       // 0 .. 1
	string preset;          // the filter the user picked, for the panel; the numbers above are the truth

	bool hasCrop() const pure nothrow @safe
	{
		return cropW > 0.001 && cropH > 0.001 && (cropW < 0.999 || cropH < 0.999 || cropX > 0.001 || cropY > 0.001);
	}

	bool hasColour() const pure nothrow @safe
	{
		return abs(brightness) > 0.001 || abs(contrast) > 0.001 || abs(saturation) > 0.001 || abs(warmth) > 0.001
			|| fade > 0.001 || vignette > 0.001 || sharpen > 0.001 || sepia > 0.001;
	}

	bool isIdentity() const pure nothrow @safe
	{
		return rotate % 360 == 0 && !flipH && !flipV && !hasCrop() && !hasColour();
	}

	JSONValue toJson() const
	{
		JSONValue j = JSONValue.emptyObject;
		j["rotate"] = rotate;
		j["flipH"] = flipH;
		j["flipV"] = flipV;
		j["crop"] = hasCrop() ? JSONValue([cropX, cropY, cropW, cropH]) : JSONValue(null);
		j["brightness"] = brightness;
		j["contrast"] = contrast;
		j["saturation"] = saturation;
		j["warmth"] = warmth;
		j["fade"] = fade;
		j["vignette"] = vignette;
		j["sharpen"] = sharpen;
		j["sepia"] = sepia;
		j["preset"] = preset is null ? JSONValue(null) : JSONValue(preset);
		return j;
	}

	/// Tolerant: missing fields keep their defaults, numbers are clamped.
	static Edits fromJson(JSONValue j)
	{
		Edits e;
		if (j.type != JSONType.object)
			return e;
		double num(string k, double lo, double hi, double def = 0)
		{
			auto v = k in j;
			if (v is null)
				return def;
			double x = v.type == JSONType.float_ ? v.floating : v.type == JSONType.integer ? cast(double) v.integer : def;
			return x < lo ? lo : (x > hi ? hi : x);
		}

		e.rotate = ((cast(int) num("rotate", -100_000, 100_000) % 360) + 360) % 360;
		e.rotate = (e.rotate / 90) * 90;
		if (auto v = "flipH" in j)
			e.flipH = v.type == JSONType.true_;
		if (auto v = "flipV" in j)
			e.flipV = v.type == JSONType.true_;
		if (auto c = "crop" in j)
			if (c.type == JSONType.array && c.array.length == 4)
			{
				double f(size_t i)
				{
					auto v = c.array[i];
					double x = v.type == JSONType.float_ ? v.floating : v.type == JSONType.integer ? cast(double) v.integer : 0;
					return x < 0 ? 0 : (x > 1 ? 1 : x);
				}

				e.cropX = f(0);
				e.cropY = f(1);
				e.cropW = f(2);
				e.cropH = f(3);
				if (e.cropX + e.cropW > 1)
					e.cropW = 1 - e.cropX;
				if (e.cropY + e.cropH > 1)
					e.cropH = 1 - e.cropY;
			}
		e.brightness = num("brightness", -1, 1);
		e.contrast = num("contrast", -1, 1);
		e.saturation = num("saturation", -1, 1);
		e.warmth = num("warmth", -1, 1);
		e.fade = num("fade", 0, 1);
		e.vignette = num("vignette", 0, 1);
		e.sharpen = num("sharpen", 0, 1);
		e.sepia = num("sepia", 0, 1);
		if (auto v = "preset" in j)
			if (v.type == JSONType.string)
				e.preset = v.str;
		return e;
	}
}

/// A filter of the panel: a name and the colour numbers it sets (geometry untouched).
struct Preset
{
	string name;
	Edits edits;
}

/// The Instagram-style filters, in the order of the strip.
Preset[] presets()
{
	Preset p(string name, double bri = 0, double con = 0, double sat = 0, double warm = 0, double fade = 0,
			double vig = 0, double sharp = 0, double sepia = 0)
	{
		Preset r;
		r.name = name;
		r.edits.preset = name;
		r.edits.brightness = bri;
		r.edits.contrast = con;
		r.edits.saturation = sat;
		r.edits.warmth = warm;
		r.edits.fade = fade;
		r.edits.vignette = vig;
		r.edits.sharpen = sharp;
		r.edits.sepia = sepia;
		return r;
	}

	return [
		p("Original"),
		p("Vivid", 0.02, 0.18, 0.40, 0.05),
		p("Warm", 0.04, 0.05, 0.12, 0.55),
		p("Cool", 0.02, 0.05, 0.05, -0.55),
		p("Bright", 0.20, 0.06, 0.12, 0.05),
		p("Fade", 0.08, -0.22, -0.28, 0.05, 0.55),
		p("Vintage", 0.03, -0.05, -0.18, 0.40, 0.45, 0.40),
		p("Drama", -0.03, 0.42, 0.10, 0, 0, 0.35, 0.25),
		p("Chrome", 0, 0.28, 0.32, -0.05, 0, 0, 0.55),
		p("Mono", 0.02, 0.08, -1),
		p("Noir", -0.05, 0.40, -1, 0, 0, 0.55, 0.2),
		p("Sepia", 0.03, 0.10, -0.6, 0.25, 0.15, 0.25, 0, 0.85),
	];
}

/// A preset applied on top of the geometry (rotation, flips, crop) of `current`.
Edits withPreset(Edits current, Preset preset)
{
	Edits e = preset.edits;
	e.rotate = current.rotate;
	e.flipH = current.flipH;
	e.flipV = current.flipV;
	e.cropX = current.cropX;
	e.cropY = current.cropY;
	e.cropW = current.cropW;
	e.cropH = current.cropH;
	return e;
}

unittest
{
	Edits e;
	assert(e.isIdentity);
	e.rotate = 90;
	assert(!e.isIdentity && !e.hasColour);
	auto back = Edits.fromJson(e.toJson);
	assert(back.rotate == 90 && back.isIdentity == false);
	auto j = parseJSON(`{"rotate": 450, "crop": [0.1, 0.2, 0.5, 0.9], "saturation": 7, "fade": -1, "preset": "Vivid"}`);
	auto f = Edits.fromJson(j);
	assert(f.rotate == 90 && f.cropX == 0.1 && f.cropH == 0.8 && f.saturation == 1 && f.fade == 0 && f.preset == "Vivid");
	assert(f.hasCrop);
	assert(presets()[0].edits.isIdentity && presets().length == 12);
	auto v = withPreset(f, presets()[1]);
	assert(v.rotate == 90 && v.cropX == 0.1 && v.saturation == 0.40 && v.preset == "Vivid");
	assert(Edits.fromJson(JSONValue(null)).isIdentity);
}
