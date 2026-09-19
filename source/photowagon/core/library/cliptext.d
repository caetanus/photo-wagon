/// CLIP's text tokenizer (byte-level BPE, ViT-B/32), ported to D so a search query
/// can be turned into the 77 token ids the text tower wants. It reproduces OpenAI's
/// simple_tokenizer exactly: bytes→unicode map, a pre-tokenizer, then greedy BPE by
/// the merge ranks. Vocabulary and merges are compiled in from data/clip (extracted
/// from Xenova/clip-vit-base-patch32's tokenizer.json). Verified against the reference
/// tokenizer in the unittest below.
module photowagon.core.library.cliptext;

import std.array : appender;
import std.conv : to;
import std.string : lineSplitter, strip, toLower;
import std.uni : isAlpha, isNumber, isWhite;

enum int startOfText = 49406;
enum int endOfText = 49407;
enum int contextLength = 77;

private __gshared dchar[256] byteToUni;
private __gshared int[string] vocabId;     // byte-mapped subword → id
private __gshared int[string] mergeRank;   // "a b" → rank (lower merges first)
private __gshared bool ready;

private void ensureInit() @trusted
{
	synchronized
	{
		if (ready)
			return;
		// bytes_to_unicode: a reversible map of every byte to a printable code point.
		bool[int] printable;
		void mark(int lo, int hi)
		{
			foreach (b; lo .. hi + 1)
				printable[b] = true;
		}
		mark('!', '~');
		mark('¡', '¬');
		mark('®', 'ÿ');
		int n = 0;
		foreach (b; 0 .. 256)
		{
			if (b in printable)
				byteToUni[b] = cast(dchar) b;
			else
			{
				byteToUni[b] = cast(dchar)(256 + n);
				n++;
			}
		}
		int id = 0;
		foreach (line; import("vocab.txt").lineSplitter)
		{
			vocabId[line] = id;
			id++;
		}
		int rank = 0;
		foreach (line; import("merges.txt").lineSplitter)
		{
			if (line.length)
				mergeRank[line] = rank;
			rank++;
		}
		ready = true;
	}
}

// One pre-token (already byte-mapped) → its BPE subwords, in order.
private string[] bpe(string mapped)
{
	import std.range : walkLength;

	// symbols: each code point its own symbol; the last carries the end-of-word mark.
	dchar[] cps;
	foreach (dchar c; mapped)
		cps ~= c;
	if (cps.length == 0)
		return null;
	string[] symbols;
	foreach (i, c; cps)
		symbols ~= (i + 1 == cps.length) ? (c.to!string ~ "</w>") : c.to!string;

	while (symbols.length > 1)
	{
		// the adjacent pair with the lowest merge rank
		int best = int.max;
		size_t at = size_t.max;
		foreach (i; 0 .. symbols.length - 1)
		{
			auto p = symbols[i] ~ " " ~ symbols[i + 1];
			if (auto r = p in mergeRank)
				if (*r < best)
				{
					best = *r;
					at = i;
				}
		}
		if (at == size_t.max)
			break;
		// merge every adjacent occurrence of that exact pair (as CLIP does), in one pass
		immutable a = symbols[at], b = symbols[at + 1];
		string[] merged;
		for (size_t i = 0; i < symbols.length;)
		{
			if (i + 1 < symbols.length && symbols[i] == a && symbols[i + 1] == b)
			{
				merged ~= a ~ b;
				i += 2;
			}
			else
			{
				merged ~= symbols[i];
				i++;
			}
		}
		symbols = merged;
	}
	return symbols;
}

// Split cleaned, lowercased text the way CLIP's regex does — hand-rolled (no std.regex,
// which leaks under this toolchain): contractions, letter runs, single digits, and runs
// of everything else that is not whitespace.
private string[] preTokenize(string text)
{
	static immutable string[] contractions = ["'re", "'ve", "'ll", "'s", "'t", "'m", "'d"];
	dchar[] cps;
	foreach (dchar c; text)
		cps ~= c;
	string[] out_;
	size_t i = 0;
	while (i < cps.length)
	{
		immutable c = cps[i];
		if (c == '\'')
		{
			string got;
			foreach (suf; contractions)
			{
				bool ok = true;
				foreach (k, dchar sc; suf)
					if (i + k >= cps.length || cps[i + k] != sc)
					{
						ok = false;
						break;
					}
				if (ok)
				{
					got = suf;
					break;
				}
			}
			if (got.length)
			{
				out_ ~= got;
				i += got.length; // suffixes are ASCII, so char count == length
				continue;
			}
		}
		if (isAlpha(c))
		{
			auto app = appender!string;
			while (i < cps.length && isAlpha(cps[i]))
				app.put(cps[i++].to!string);
			out_ ~= app.data;
		}
		else if (isNumber(c))
		{
			out_ ~= c.to!string; // one digit at a time
			i++;
		}
		else if (!isWhite(c))
		{
			auto app = appender!string;
			while (i < cps.length && !isWhite(cps[i]) && !isAlpha(cps[i]) && !isNumber(cps[i]))
				app.put(cps[i++].to!string);
			out_ ~= app.data;
		}
		else
			i++; // whitespace between tokens
	}
	return out_;
}

private string whitespaceClean(string text)
{
	// collapse any run of whitespace to a single space, then trim
	auto app = appender!string;
	bool inSpace = false;
	foreach (dchar c; text)
	{
		if (isWhite(c))
			inSpace = true;
		else
		{
			if (inSpace && app.data.length)
				app.put(' ');
			inSpace = false;
			app.put(c.to!string);
		}
	}
	return app.data;
}

/// The token ids for `text`, exactly as CLIP produces them (without the special tokens
/// or padding). Mostly for the unittest; callers usually want `encode`.
int[] tokenize(string text)
{
	ensureInit();
	immutable clean = whitespaceClean(text).toLower;
	int[] ids;
	foreach (tok; preTokenize(clean))
	{
		// byte-map the UTF-8 bytes of the pre-token
		auto app = appender!string;
		foreach (ubyte b; cast(immutable(ubyte)[]) tok)
			app.put(byteToUni[b].to!string);
		foreach (sym; bpe(app.data))
			if (auto p = sym in vocabId)
				ids ~= *p;
	}
	return ids;
}

/// `text` → the 77 token ids the CLIP text tower takes: <sot>, the tokens, <eot>,
/// padded (or truncated) to 77 with <eot>.
int[contextLength] encode(string text)
{
	auto body_ = tokenize(text);
	int[contextLength] out_;
	out_[] = endOfText;
	out_[0] = startOfText;
	size_t n = body_.length;
	if (n > contextLength - 2)
		n = contextLength - 2;
	foreach (i; 0 .. n)
		out_[1 + i] = body_[i];
	out_[1 + n] = endOfText;
	return out_;
}

unittest
{
	// ground truth from the reference tokenizer (HuggingFace `tokenizers`,
	// Xenova/clip-vit-base-patch32) — see the CLIP search work, 2026-09-19.
	assert(tokenize("a photo of a cat") == [320, 1125, 539, 320, 2368]);
	assert(tokenize("praia ao pôr do sol") == [1865, 1073, 5703, 79, 26815, 337, 818, 9941]);
	assert(tokenize("birthday cake") == [1166, 2972]);
	assert(tokenize("Dog Running!!") == [1929, 2761, 748]);
	assert(tokenize("café") == [15304]);
	// encode wraps with the special tokens and pads to 77
	auto e = encode("birthday cake");
	assert(e.length == 77);
	assert(e[0] == startOfText && e[1] == 1166 && e[2] == 2972 && e[3] == endOfText && e[76] == endOfText);
}
