/// OCR: the text read out of screenshots, memes and text-bearing photos, so search
/// finds words that live inside the picture. Recognition runs on the vision worker
/// (Tesseract, csrc/ocr_tesseract); this module is the parent side and the pass.
///
/// Which photos: kind screenshot | meme, or a photo the scene classifier tagged
/// 'Text' (a document, a screen, a receipt) — so it never reads text out of foliage.
/// The choice reuses work already done (kinds + scenes), so no whole-library pass.
module photowagon.core.library.ocr;

import std.base64 : Base64;
import std.conv : to;
import std.string : strip, split;

import vibe.core.concurrency : async;
import vibe.core.log : logInfo, logWarn;
import vibe.core.task : InterruptException;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.config : Config;
import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.events : Events;
import photowagon.core.jobs.scheduler : jobs, Priority;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.store.store : ContentStore;
import photowagon.core.vision.worker : visionRequest;

struct OcrResult
{
	string text;
	int conf;   // mean word confidence, 0..100
}

/// Recognise the text in the image at `path` (blocking; meant for a worker thread).
/// Talks to the vision worker, which answers "<conf> <base64 of the UTF-8 text>".
OcrResult ocrImage(string path)
{
	auto ans = visionRequest("ocr " ~ path);
	auto sp = ans.split(' ');
	OcrResult r;
	if (sp.length >= 1)
		try
			r.conf = sp[0].to!int;
		catch (Exception)
		{
		}
	if (sp.length >= 2 && sp[1].length)
		r.text = cast(string) Base64.decode(sp[1]);
	return r;
}

final class OcrService
{
	private Config cfg;
	private Database db;
	private PhotoRepo photos;
	private ContentStore store;
	private Events events;
	private FiberGroup fibers;
	private bool running, again, closed;
	/// Turned off if the worker cannot load Tesseract.
	bool available = true;
	/// Called after a pass finishes.
	void delegate() onDone;

	this(Config cfg, Database db, PhotoRepo photos, ContentStore store, Events events)
	{
		this.cfg = cfg;
		this.db = db;
		this.photos = photos;
		this.store = store;
		this.events = events;
		fibers = new FiberGroup((Exception e) nothrow {
			try
				logWarn("ocr: job failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	void close() nothrow
	{
		closed = true;
		fibers.stopAll();
	}

	bool busy() const
	{
		return running;
	}

	void start()
	{
		if (!available || closed)
			return;
		if (running)
		{
			again = true;
			return;
		}
		running = true;
		fibers.spawn(() {
			scope (exit)
				running = false;
			do
			{
				again = false;
				if (pending(1).length)
					jobs.pass(Priority.ocr, "reading text (OCR)", &run);
			}
			while (again);
			if (onDone)
				onDone();
		});
	}

	// ---- the pass -----------------------------------------------------------------

	/// Photos to read and not yet read: screenshots / memes, or the ones CLIP called
	/// 'Text'. `ocr_scanned` keeps a photo from being read twice.
	private long[] pending(long limit = 1_000_000)
	{
		auto s = db.prepare(`SELECT p.id FROM photos p
			WHERE p.ocr_scanned = 0 AND p.thumb_hash IS NOT NULL
			  AND (p.kind IN ('screenshot', 'meme')
			       OR EXISTS (SELECT 1 FROM photo_tags t
			                  WHERE t.photo_id = p.id AND t.grp = 'scene' AND t.tag = 'Text'))
			ORDER BY p.id LIMIT ?`);
		s.bind(1, limit);
		long[] out_;
		while (s.step())
			out_ ~= s.getLong(0);
		return out_;
	}

	private void run()
	{
		import std.file : exists;

		auto ids = pending();
		if (ids.length)
			logInfo("ocr: reading text in %s images", ids.length);
		long found;
		foreach (id; ids)
		{
			if (closed)
				return;
			string text;
			try
			{
				auto p = photos.get(id);
				// the original: Tesseract wants resolution, and a thumbnail loses the text
				if (p.path.exists)
				{
					auto r = jobs.background({ return async(&ocrImage, p.path).getResult(); });
					text = r.text.strip;
				}
			}
			catch (InterruptException)
				throw new InterruptException;
			catch (Exception e)
				logWarn("ocr: photo %s: %s", id, e.msg);   // still marked below, so a bad file is not retried
			storeText(id, text);
			if (text.length)
				found++;
		}
		if (ids.length)
			logInfo("ocr: done — %s of %s had text", found, ids.length);
	}

	private void storeText(long id, string text)
	{
		auto s = db.prepare("UPDATE photos SET ocr_text = ?, ocr_scanned = 1 WHERE id = ?");
		s.bind(1, text).bind(2, id);
		s.run();
	}
}
