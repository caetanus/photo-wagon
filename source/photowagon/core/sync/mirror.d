/// Mirroring another computer's photos: the client half of a computer↔computer link. It
/// runs over the same mux as this node's server session on that connection (a link between
/// two computers is used both ways: each serves its library, each mirrors the other's), and
/// speaks what a phone speaks: the control channel ('i') with daemon.auth — and daemon.pair
/// the first time, confirmed on the other computer — then `mirror.hello` (our token and
/// name, so the other side mirrors us back), then it pages through `library.hashes` and pulls
/// every file it lacks by sha256 on piece streams ('p'), resumable and verified piece by
/// piece (core/sync/pieces.d pullFile), landing each under imports/<that computer>/.
///
/// A computer we only know by the code the user typed (pending) must first PROVE it is that
/// code's computer (`mirror.prove`: an HMAC of its token over our nonce and both keys): the
/// token is sent only to the one that proves it, and that also says which pending code this
/// connection is.
///
/// Never pulled: a hash with a local file here, one deleted here in the app (declined) or
/// removed from Wagon here. A file that vanished from disk outside the app left the library
/// at the next rescan — so it IS pulled again (the user's rule: only in-app deletion counts).
/// Exchanges run when the link comes up, after either library changes (at most every 10 s)
/// and every 3 minutes; a failed exchange is retried after 30 s.
module photowagon.core.sync.mirror;

import std.json;
import std.conv : to;

import core.time : Duration, MonoTime, seconds, minutes, hours;

import vibe.core.core : runTask, sleep;
import vibe.core.task : Task;
import vibe.core.sync : LocalManualEvent, createManualEvent, TaskMutex;
import vibe.core.log : logInfo, logWarn;

import libp2p.core.stream : Stream, readLengthPrefixed, writeLengthPrefixed;

import photowagon.core.api.import_api : LandFn;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.sync.muxstream : LinkMux, muxTagControl, muxTagPiece;
import photowagon.core.sync.pieces : PieceStore, pullFile;
import photowagon.core.sync.meta : MetaSync;

enum exchangeEvery = 3.minutes;
enum exchangeAfterChangeMin = 10.seconds;
enum retryAfterFailure = 30.seconds;
enum pingEvery = 5.seconds;
enum callTimeout = 30.seconds;
enum pairTimeout = 10.minutes;
/// No piece for this long while pulls are in flight: those streams are cut (and retried).
enum pieceStall = 60.seconds;
/// A file the other computer could not give (its bytes no longer match the hash it lists —
/// tags written into it there): not asked again for this long.
enum unfetchableFor = 6.hours;
/// Files pulled at once from one computer.
enum size_t pullConcurrency = 3;
private enum size_t pageLimit = 500;
private enum size_t maxMissing = 500_000;
private enum maxLine = 16 * 1024 * 1024;

/// Where one mirror stands, for the UI.
struct MirrorStatus
{
	string state;      // connecting · waiting (for approval, `code`) · syncing · idle · refused · offline
	string code;       // the 4 digits to confirm on the other computer while waiting
	string peerAlias;
	long missing;      // files the other computer has that are not here yet (last exchange)
	long pulled;       // files brought over since the link came up
	long failed;
	long lastSync;     // unix seconds of the last complete exchange
	long held;         // its in-app deletions waiting for the user here (too many at once)
}

final class MirrorClient
{
	private LinkMux mux;
	private string[] tokens;          // the other computer's token, or the pending candidates
	private bool mustProve;           // pending: it proves which token is its own first
	private string ownToken, ownAlias, ownKey, peerKey;
	private PhotoRepo photos;
	private PieceStore pieces;
	private LandFn land;
	private string tmpDir;            // <data>/imports/.mirror — hidden: the indexer skips it
	private Stream ctl;
	private TaskMutex ctlLock;
	private long nextId, pingSeq;
	private bool[long] waiting;       // request ids we wait for (anything else is dropped)
	private JSONValue[long] replies;
	private LocalManualEvent ev;
	private long changes, seenChanges;
	private bool stopped;
	private bool[Stream] open_;       // piece streams in use (stop() cuts them)
	private MonoTime lastProgress;
	private MonoTime[string] unfetchable;

	MirrorStatus status;
	/// The organization (core/sync/meta.d), pulled after the files on every exchange; null: files only.
	MetaSync meta;
	private bool metaUnsupported;     // the other computer is older: it has no meta.since
	/// The other computer's token once known (the pending code it proved, or the kept one).
	string chosenToken;
	/// Called whenever `status` moves (from the mirror's task).
	void delegate() nothrow onStatus;
	/// The other computer accepted us (auth, and the pairing confirmed there if it was new):
	/// called BEFORE we greet it, so this side trusts it back before its own client knocks.
	void delegate(string token) nothrow onTrusted;
	/// After the greeting: which token it was, and its name (persist the peer).
	void delegate(string token, string peerAlias) nothrow onAuthed;
	/// The client ended (the link, a refusal, stop()).
	void delegate() nothrow onEnded;

	this(LinkMux mux, string[] tokens, bool mustProve, string ownToken, string ownAlias, string ownKey,
		string peerKey, PhotoRepo photos, PieceStore pieces, LandFn land, string tmpDir)
	{
		this.mux = mux;
		this.tokens = tokens;
		this.mustProve = mustProve;
		this.ownToken = ownToken;
		this.ownAlias = ownAlias;
		this.ownKey = ownKey;
		this.peerKey = peerKey;
		this.photos = photos;
		this.pieces = pieces;
		this.land = land;
		this.tmpDir = tmpDir;
		ev = createManualEvent();
		ctlLock = new TaskMutex;
		status.state = "connecting";
	}

	void start()
	{
		runTask(&run);
	}

	/// End now: the control stream and every piece stream are cut, so a blocked read ends.
	void stop() nothrow
	{
		if (stopped)
			return;
		stopped = true;
		try
			if (ctl !is null)
				ctl.reset();
		catch (Exception)
		{
		}
		cutPieces();
		ev.emit();
	}

	/// Something changed on THIS side (a file vanished and left the library at a rescan):
	/// look again soon — what went missing here comes back from the other computer.
	void poke() nothrow
	{
		changes++;
		ev.emit();
	}

	bool running() const nothrow
	{
		return !stopped;
	}

	private void cutPieces() nothrow
	{
		foreach (s; open_.keys)
			try
				s.reset();
			catch (Exception)
			{
			}
		open_ = null;
	}

	private void setState(string s) nothrow
	{
		status.state = s;
		if (onStatus !is null)
			onStatus();
	}

	private void run() nothrow
	{
		scope (exit)
		{
			stop();
			waiting = null;
			replies = null;
			if (status.state != "refused")
				setState("offline");
			if (onEnded !is null)
				onEnded();
		}
		try
		{
			ctl = mux.open();
			ubyte[1] tag = [muxTagControl];
			ctl.write(tag[]);
			runTask(&reader);
			// pings from the start: while the other computer's operator confirms the pairing
			// nothing else flows, and a silent link is dropped on both sides
			runTask(&pinger);

			if (mustProve)
			{
				immutable t = provenToken();
				if (!t.length)
				{
					logInfo("mirror: %s… is not the computer of any code entered here", peerKey[0 .. 12]);
					setState("refused");
					return;
				}
				tokens = [t];
			}
			if (tokens.length == 1)
				chosenToken = tokens[0];
			string good;
			JSONValue authRes;
			foreach (t; tokens)
			{
				auto r = call("daemon.auth", JSONValue(["token": JSONValue(t), "name": JSONValue(ownAlias),
					"kind": JSONValue("computer")]), callTimeout);
				if ("result" in r)
				{
					good = t;
					authRes = r["result"];
					break;
				}
			}
			if (!good.length)
			{
				setState("refused");
				return;
			}
			if (authRes.type == JSONType.object && "needsPairing" in authRes && authRes["needsPairing"].type == JSONType.true_)
			{
				import std.random : uniform;
				import std.format : format;

				status.code = format("%04d", uniform(0, 10_000));
				setState("waiting");
				logInfo("mirror: waiting for the other computer to accept us — code %s", status.code);
				auto r = call("daemon.pair", JSONValue(["code": JSONValue(status.code), "name": JSONValue(ownAlias)]),
					pairTimeout);
				status.code = null;
				if ("result" !in r)
				{
					setState("refused");
					return;
				}
			}
			if (onTrusted !is null)
				onTrusted(good);
			auto hello = call("mirror.hello", JSONValue(["token": JSONValue(ownToken), "alias": JSONValue(ownAlias)]),
				callTimeout);
			if ("result" in hello && hello["result"].type == JSONType.object && "alias" in hello["result"]
				&& hello["result"]["alias"].type == JSONType.string)
				status.peerAlias = hello["result"]["alias"].str;
			if (onAuthed !is null)
				onAuthed(good, status.peerAlias);

			auto lastExchange = MonoTime.zero;
			bool failedLast;
			while (!stopped)
			{
				seenChanges = changes;
				immutable t0 = MonoTime.currTime;
				try
				{
					exchange();
					metaExchange();
					failedLast = false;
				}
				catch (Exception e)
				{
					if (stopped)
						break;
					failedLast = true;
					logWarn("mirror %s: exchange failed (again in %s s): %s", status.peerAlias,
						retryAfterFailure.total!"seconds", e.msg);
					setState("idle");
				}
				lastExchange = t0;
				// wait: a library changed (not more often than every 10 s), or 3 min, or the retry
				auto c = ev.emitCount;
				while (!stopped)
				{
					immutable since = MonoTime.currTime - lastExchange;
					immutable due = failedLast ? retryAfterFailure : exchangeEvery;
					if (since >= due || (changes != seenChanges && since >= exchangeAfterChangeMin))
						break;
					immutable wait = changes != seenChanges ? exchangeAfterChangeMin - since : due - since;
					c = ev.wait(wait, c);
				}
			}
		}
		catch (Exception e)
		{
			try
				logInfo("mirror %s: link ended: %s", status.peerAlias, e.msg);
			catch (Exception)
			{
			}
		}
	}

	// the pending code this computer proves to be its own (HMAC of its token over our nonce
	// and both keys — see HsMuxServe mirror.prove), or null
	private string provenToken()
	{
		import std.digest.hmac : hmac;
		import std.digest.sha : SHA256;
		import std.digest : toHexString, LetterCase;
		import std.random : uniform;
		import std.format : format;

		ubyte[32] nb;
		foreach (ref b; nb)
			b = cast(ubyte) uniform(0, 256);
		immutable nonce = format("%(%02x%)", nb[]);
		auto r = call("mirror.prove", JSONValue(["nonce": JSONValue(nonce)]), callTimeout);
		if ("result" !in r || r["result"].type != JSONType.object || "mac" !in r["result"]
			|| r["result"]["mac"].type != JSONType.string)
			return null;
		immutable got = r["result"]["mac"].str;
		foreach (t; tokens)
		{
			immutable want = hmac!SHA256(cast(const(ubyte)[]) (nonce ~ "|" ~ ownKey ~ "|" ~ peerKey), cast(const(ubyte)[]) t);
			if (toHexString!(LetterCase.lower)(want)[] == got)
				return t;
		}
		return null;
	}

	/// The organization: what the other computer did (albums, favorites, names, deletions in
	/// the app…) since the last time, taken where it is newer. After the files, so a fact
	/// about a photo that just arrived applies at once.
	private void metaExchange()
	{
		if (meta is null || metaUnsupported || stopped)
			return;
		try
		{
			auto r = meta.pull(peerKey, (string method, JSONValue params) {
				auto res = call(method, params, callTimeout);
				if ("result" in res)
					return res["result"];
				immutable code = "error" in res && res["error"].type == JSONType.object && "code" in res["error"]
					&& res["error"]["code"].type == JSONType.string ? res["error"]["code"].str : "";
				if (code == "unknown_method" || code == "unauthorized")
					metaUnsupported = true;
				throw new Exception(method ~ ": " ~ (code.length ? code : "no answer"));
			});
			if (r.taken || r.held)
				logInfo("mirror %s: organization — %s taken, %s applied, %s waiting for their photo, %s deletion(s) held",
					status.peerAlias, r.taken, r.applied, r.pending, r.held);
		}
		catch (Exception e)
		{
			if (stopped)
				return;
			logWarn("mirror %s: organization not exchanged: %s", status.peerAlias, e.msg);
		}
		immutable h = meta.heldCount(peerKey);
		if (h != status.held)
		{
			status.held = h;
			setState(status.state);   // tell the UI
		}
	}

	/// One pass: what the other computer has that is not here (and not turned away), pulled.
	private void exchange()
	{
		import std.file : mkdirRecurse;

		struct Want
		{
			string sha, name, takenAt;
			long size, mtimeMs;
		}

		Want[] missing;
		bool[string] seen;
		long after;
		do
		{
			auto r = call("library.hashes", JSONValue(["after": JSONValue(after), "limit": JSONValue(pageLimit)]), callTimeout);
			if ("result" !in r)
				throw new Exception("library.hashes failed");
			auto res = r["result"];
			size_t taken;
			foreach (it; res["items"].array)
			{
				if (++taken > pageLimit)
					break;   // more than asked for: the rest is not trusted
				immutable sha = it["sha256"].str;
				if (sha.length != 64 || sha in seen)
					continue;
				seen[sha] = true;
				if (auto u = sha in unfetchable)
				{
					if (MonoTime.currTime - *u < unfetchableFor)
						continue;
					unfetchable.remove(sha);
				}
				if (photos.hasLocalFile(sha) || photos.isDeclined(sha) || photos.isRemoved(sha))
					continue;
				missing ~= Want(sha, it["name"].str, "takenAt" in it && it["takenAt"].type == JSONType.string
					? it["takenAt"].str : null, it["size"].integer,
					"mtimeMs" in it && it["mtimeMs"].type == JSONType.integer ? it["mtimeMs"].integer : 0);
				if (missing.length >= maxMissing)
					break;
			}
			immutable next = res["next"].integer;
			if (next != 0 && next <= after)
				throw new Exception("library.hashes: the page cursor did not move");
			after = next;
		}
		while (after > 0 && !stopped && missing.length < maxMissing);

		status.missing = missing.length;
		if (missing.length)
		{
			logInfo("mirror %s: %s file(s) to bring over", status.peerAlias, missing.length);
			setState("syncing");
		}
		mkdirRecurse(tmpDir);
		// a few files at once, each on its own piece stream: one at a time left the link idle
		// between pieces (a request/answer per 1 MiB) and between files (landing, indexing)
		size_t next, done_, transient;
		void worker() nothrow
		{
			while (!stopped && next < missing.length)
			{
				auto w = missing[next++];
				bool skip;
				try
					skip = photos.hasLocalFile(w.sha) || photos.isDeclined(w.sha) || photos.isRemoved(w.sha);
				catch (Exception)
				{
				}
				if (!skip)
				{
					immutable r = pullOne(w.sha, w.name, w.takenAt, w.mtimeMs);
					if (r == Pulled.landed)
						status.pulled++;
					else if (!stopped)
					{
						status.failed++;
						if (r == Pulled.definitive)
							try
								unfetchable[w.sha] = MonoTime.currTime;   // the peer cannot give it: not every pass
							catch (Exception)
							{
							}
						else
							transient++;   // the link, not the file: the whole pass goes again soon
					}
				}
				done_++;
				status.missing = missing.length - done_;
				if (onStatus !is null)
					onStatus();
			}
		}
		// pulls that stop moving (a peer that answers pings but withholds pieces) are cut
		bool pulling = missing.length > 0;
		lastProgress = MonoTime.currTime;
		auto watchdog = runTask(() nothrow {
			while (pulling && !stopped)
			{
				try
					sleep(5.seconds);
				catch (Exception)
					return;
				if (pulling && MonoTime.currTime - lastProgress > pieceStall)
				{
					try
						logWarn("mirror %s: no piece for %s s — cutting the pulls", status.peerAlias, pieceStall.total!"seconds");
					catch (Exception)
					{
					}
					cutPieces();
					lastProgress = MonoTime.currTime;
				}
			}
		});
		immutable t0 = MonoTime.currTime;
		immutable pulledBefore = status.pulled;
		Task[] workers;
		foreach (k; 0 .. (missing.length < pullConcurrency ? missing.length : pullConcurrency))
			workers ~= runTask(&worker);
		foreach (t; workers)
			t.join();
		pulling = false;
		watchdog.join();
		if (missing.length)
		{
			long bytes;
			foreach (w; missing)
				bytes += w.size;
			immutable ms = (MonoTime.currTime - t0).total!"msecs";
			logInfo("mirror %s: %s of %s file(s), %s bytes in %s ms (%s MB/s)", status.peerAlias,
				status.pulled - pulledBefore, missing.length, bytes, ms, ms > 0 ? bytes / 1000 / ms : 0);
		}
		if (stopped)
			return;
		if (transient)
			throw new Exception(transient.to!string ~ " file(s) did not come over");
		import std.datetime.systime : Clock;

		status.lastSync = Clock.currTime.toUnixTime;
		setState("idle");
	}

	private enum Pulled { landed, transient, definitive }

	/// One file from the other computer, into imports/<it>/: landed; or failed for the link
	/// (transient: tried again on the next pass) or for the file (definitive: the peer does not
	/// have those bytes).
	private Pulled pullOne(string sha, string name, string takenAt, long mtimeMs) nothrow
	{
		import std.file : exists, remove;
		import std.path : buildPath;

		immutable dest = buildPath(tmpDir, sha);
		foreach (attempt; 0 .. 3)
		{
			if (stopped)
				return Pulled.transient;
			bool retry;
			Stream ps;
			try
			{
				ps = mux.open();
				open_[ps] = true;
				scope (exit)
				{
					open_.remove(ps);
					ps.close();
				}
				ubyte[1] tag = [muxTagPiece];
				ps.write(tag[]);
				pullFile(ps, pieces, sha, dest, retry, () { lastProgress = MonoTime.currTime; });
				if (stopped)   // removed meanwhile: nothing lands after that
				{
					if (dest.exists)
						remove(dest);
					return Pulled.transient;
				}
				cast(void) land(name, takenAt, dest, sha, mtimeMs, status.peerAlias.length ? status.peerAlias : "computer");
				return Pulled.landed;
			}
			catch (Exception e)
			{
				try
					if (dest.exists)
						remove(dest);
				catch (Exception)
				{
				}
				if (!retry || stopped)
				{
					if (!stopped)
						try
							logWarn("mirror %s: %s: %s", status.peerAlias, name, e.msg);
						catch (Exception)
						{
						}
					return retry || stopped ? Pulled.transient : Pulled.definitive;
				}
			}
		}
		return Pulled.transient;
	}

	/// One request on the control channel; the reply (an {"error":…} reply is returned as
	/// is). Throws on a timeout or a link that ended.
	private JSONValue call(string method, JSONValue params, Duration timeout)
	{
		immutable id = ++nextId;
		immutable line = JSONValue(["id": JSONValue(id), "method": JSONValue(method), "params": params]).toString();
		waiting[id] = true;
		scope (exit)
		{
			waiting.remove(id);
			replies.remove(id);
		}
		{
			ctlLock.lock();
			scope (exit)
				ctlLock.unlock();
			writeLengthPrefixed(ctl, cast(const(ubyte)[]) line);
		}
		immutable deadline = MonoTime.currTime + timeout;
		auto c = ev.emitCount;
		while (id !in replies)
		{
			if (stopped)
				throw new Exception("mirror: the link ended");
			immutable left = deadline - MonoTime.currTime;
			if (left <= Duration.zero)
				throw new Exception("mirror: " ~ method ~ " timed out");
			c = ev.wait(left, c);
		}
		return replies[id];
	}

	private void reader() nothrow
	{
		try
			while (!stopped)
			{
				auto line = cast(string) readLengthPrefixed(ctl, maxLine).idup;
				JSONValue msg;
				try
					msg = parseJSON(line);
				catch (Exception)
					continue;
				if (msg.type != JSONType.object)
					continue;
				if (auto id = "id" in msg)
				{
					// only an answer to a request we wait for (a ping's, or anything unasked, is
					// dropped — nothing a peer sends piles up here)
					if (id.type == JSONType.integer && id.integer in waiting)
					{
						replies[id.integer] = msg;
						ev.emit();
					}
				}
				else if (auto e = "event" in msg)
					if (e.type == JSONType.string && e.str == "library.changed")
					{
						changes++;
						ev.emit();
					}
			}
		catch (Exception)
		{
		}
		stop();
	}

	// the other server drops a silent peer: a request now and then keeps the link known alive
	private void pinger() nothrow
	{
		while (!stopped)
		{
			try
				sleep(pingEvery);
			catch (Exception)
				return;
			if (stopped)
				return;
			try
			{
				immutable id = -(++pingSeq);   // never in `waiting`: its answer is dropped
				immutable line = JSONValue(["id": JSONValue(id), "method": JSONValue("daemon.hello"),
					"params": JSONValue.emptyObject]).toString();
				ctlLock.lock();
				scope (exit)
					ctlLock.unlock();
				writeLengthPrefixed(ctl, cast(const(ubyte)[]) line);
			}
			catch (Exception)
			{
				stop();
				return;
			}
		}
	}
}
