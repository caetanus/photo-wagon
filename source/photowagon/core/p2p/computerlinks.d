/// The user's other computers, mirrored both ways (see core/sync/computers.d for the pairing
/// record and core/sync/mirror.d for the pulling). This ties them to the hyperswarm node and
/// its sessions: which topics this node dials, a MirrorClient on every session with another
/// computer (over that session's own mux — one connection per pair, used both ways), trust
/// in the device gate, and the `computers.*` API the UI drives.
module photowagon.core.p2p.computerlinks;

import std.json;

import vibe.core.log : logInfo;
import vibe.core.core : runTask, sleep;
import core.time : seconds;

import hyperswarm.connection : Connection;

import photowagon.core.api.import_api : LandFn;
import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.protocol : Registry, ApiError, getString;
import photowagon.core.library.photos : PhotoRepo;
import photowagon.core.p2p.devices : DeviceRepo;
import photowagon.core.p2p.hsmux : HsMuxServe;
import photowagon.core.sync.computers : ComputerPeers, Computer;
import photowagon.core.sync.mirror : MirrorClient, MirrorStatus;
import photowagon.core.sync.pieces : PieceStore;

final class ComputerLinks
{
	private ComputerPeers peers;
	private DeviceRepo devices;
	private PhotoRepo photos;
	private PieceStore pieces;
	private LandFn land;
	private Events events;
	private string ownToken, ownAlias, tmpDir;
	private void delegate(string token) join;
	private void delegate(string token) nothrow leave;
	private string delegate() nothrow ownKey;
	private MirrorClient[HsMuxServe] clients;
	private bool[string] removed;           // keys the user removed during this run
	private string[string] tokenOfKey;      // the token a key's client proved / uses
	private HsMuxServe[][string] sessions;   // live sessions by the peer's key (a pair may hold several paths)
	private string[][string] tokensOf;      // the tokens to try on a key's sessions
	private MirrorStatus[string] status;   // by the other computer's key (or token while pending)

	this(ComputerPeers peers, DeviceRepo devices, PhotoRepo photos, PieceStore pieces, LandFn land,
		Events events, string ownToken, string ownAlias, string tmpDir, void delegate(string) join,
		void delegate(string) nothrow leave, string delegate() nothrow ownKey)
	{
		this.peers = peers;
		this.devices = devices;
		this.photos = photos;
		this.pieces = pieces;
		this.land = land;
		this.events = events;
		this.ownToken = ownToken;
		this.ownAlias = ownAlias;
		this.tmpDir = tmpDir;
		this.join = join;
		this.leave = leave;
		this.ownKey = ownKey;
		// this library changed (a rescan dropped a file deleted behind our back): every mirror
		// looks again, so the file comes back from the other computer
		if (events !is null)
			events.attach((string line) nothrow {
				import std.algorithm.searching : canFind;

				if (line.canFind(`"event":"library.changed"`))
					foreach (m; clients.byValue)
						m.poke();
			});
	}

	/// Dial what this node dials: pending codes, and known computers whose key is larger.
	void start()
	{
		foreach (c; peers.list)
			if (ComputerPeers.weDial(ownKey(), c.key))
				join(c.token);
	}

	/// Whether a connection is (or is being made) to another computer — its session gets its
	/// mux at once (protomux; this side speaks first when it dialed).
	bool isComputer(Connection c) nothrow
	{
		try
			return c.isInitiator || peers.byKey(hexOf(c)) !is null;
		catch (Exception)
			return false;
	}

	/// Every hyperswarm session: a computer's gets a mirror client; any session may turn out
	/// to be a computer's when it greets us (mirror.hello).
	void onSession(HsMuxServe s, Connection c) nothrow
	{
		s.ownAlias = ownAlias;
		s.ownKey = ownKey();
		s.onMirrorHello = &greeted;
		string key;
		try
			key = hexOf(c);
		catch (Exception)
			return;
		try
			sessions[key] ~= s;
		catch (Exception)
			return;
		s.onGone = () nothrow {
			HsMuxServe[] rest;
			if (auto list = key in sessions)
				foreach (x; *list)
					if (x !is s)
						rest ~= x;
			try
				sessions[key] = rest;
			catch (Exception)
			{
			}
			if (auto m = s in clients)
			{
				(*m).stop();
				clients.remove(s);
				// ONE client per computer: another live path to it takes over
				if (rest.length)
					try
						if (auto t = key in tokensOf)
							mirror(rest[$ - 1], key, *t, peers.byKey(key) is null);   // pending: it proves again
					catch (Exception)
					{
					}
			}
		};
		try
		{
			auto known = peers.byKey(key);
			if (known !is null)
				mirror(s, key, [known.token]);
			else if (c.isInitiator)
			{
				// a computer we dialed for a code the user typed: it proves which code is its
				// own before any token leaves (MirrorClient.provenToken)
				auto pending = peers.pendingTokens();
				if (pending.length)
					mirror(s, key, pending, /*mustProve*/ true);
			}
		}
		catch (Exception e)
			try logInfo("computers: session: %s", e.msg); catch (Exception) {}
	}

	// the other computer authenticated on OUR server and told us its token: remember it and
	// mirror it back over the same session
	private void greeted(HsMuxServe s, string key, string token, string alias_) nothrow
	{
		try
		{
			removed.remove(key);   // paired again (it authenticated): its retries count again
			peers.remember(key, token, alias_);
			dialPolicy(key, token);
			mirror(s, key, [token], false);
			changed();
		}
		catch (Exception e)
			try logInfo("computers: hello from %s: %s", key[0 .. 12], e.msg); catch (Exception) {}
	}

	private void mirror(HsMuxServe s, string key, string[] tokens, bool mustProve = false)
	{
		if (s.isGone)
			return;
		tokensOf[key] = tokens;
		// one client per computer, whatever number of paths (LAN addresses, the DHT) reach it:
		// two would knock twice, and a second pairing request cancels the first
		foreach (x; sessions.get(key, null))
			if (auto m = x in clients)
				if ((*m).running)
					return;
		if (s in clients)
			return;
		auto mux = s.linkMux();
		if (mux is null)
			return;   // the peer has said nothing yet (not a computer's session)
		auto m = new MirrorClient(mux, tokens, mustProve, ownToken, ownAlias, ownKey(), key, photos, pieces, land, tmpDir);
		m.onEnded = () nothrow {
			if (auto x = s in clients)
				if (*x is m)
					clients.remove(s);
			// a pending attempt that ended leaves no stale code on the pending row
			try
				if (peers.byKey(key) is null)
				{
					status.remove(key);
					tokenOfKey.remove(key);
					changed();
				}
			catch (Exception)
			{
			}
			// the session lives on (a refusal, a control stream the peer closed): try again
			// later on it, unless that computer was removed meanwhile
			if (!s.isGone && (key in removed) is null)
				try
					runTask(() nothrow {
						try
							sleep(30.seconds);
						catch (Exception)
							return;
						try
							if (!s.isGone && (key in removed) is null)
								if (auto t = key in tokensOf)
									mirror(s, key, *t, peers.byKey(key) is null);
						catch (Exception)
						{
						}
					});
				catch (Exception)
				{
				}
		};
		m.onTrusted = (string token) nothrow {
			// it accepted us: trust it back BEFORE greeting it, so its own client passes our
			// device gate straight away (no second pairing on this side)
			try
			{
				removed.remove(key);   // it accepted us (again): a removal before no longer holds
				tokensOf[key] = [token];   // its own token only: other pending codes never go to it
				if (devices !is null && !devices.exists(key))
					devices.add(key, "computer");
				peers.remember(key, token, peers.byKey(key) is null ? null : peers.byKey(key).alias_);
				dialPolicy(key, token);
			}
			catch (Exception)
			{
			}
		};
		m.onAuthed = (string token, string peerAlias) nothrow {
			try
			{
				peers.remember(key, token, peerAlias);
				if (devices !is null && peerAlias.length)
					devices.rename(key, peerAlias);
				logInfo("computers: mirroring %s (%s)", peerAlias, key[0 .. 12]);
			}
			catch (Exception)
			{
			}
			changed();
		};
		m.onStatus = () nothrow {
			try
			{
				status[key] = m.status;
				if (m.chosenToken.length)
					tokenOfKey[key] = m.chosenToken;
			}
			catch (Exception)
			{
			}
			changed();
		};
		clients[s] = m;
		m.start();
	}

	private void dialPolicy(string key, string token)
	{
		if (ComputerPeers.weDial(ownKey(), key))
			join(token);
		else
			leave(token);   // the other side dials; we would only race it
	}

	private void changed() nothrow
	{
		try
			events.emit("computers.changed", JSONValue.emptyObject);
		catch (Exception)
		{
		}
	}

	// the tokens a key's client was given (to find a pending one by its token)
	private bool[string] tokenSet(string key) nothrow
	{
		bool[string] set;
		try
			if (auto t = key in tokensOf)
				foreach (x; *t)
					set[x] = true;
		catch (Exception)
		{
		}
		return set;
	}

	/// What the UI calls a pending computer (never its token: the list is readable by any
	/// authenticated peer through the shared registry).
	private static string pendingId(string token)
	{
		import photowagon.core.util.fastsha : sha256Of;
		import std.format : format;

		auto h = sha256Of(cast(const(ubyte)[]) token);
		return "pending:" ~ format("%(%02x%)", h[0 .. 8]);
	}

	private static string hexOf(Connection c)
	{
		import std.format : format;

		return format("%(%02x%)", c.remotePublicKey[]);
	}

	// ---- the API ---------------------------------------------------------------------------

	/// computers.code, computers.pair, computers.list, computers.remove.
	void register(Registry r)
	{
		r.add("computers.code", (JSONValue p) {
			import photowagon.core.pairingcode : pairingCode;

			return JSONValue(["code": JSONValue(pairingCode(ownToken)), "alias": JSONValue(ownAlias)]);
		});
		r.add("computers.pair", (JSONValue p) {
			import photowagon.core.pairingcode : parsePairingCode;

			immutable code = getString(p, "code");
			string token;
			try
				token = parsePairingCode(code).token;
			catch (Exception e)
				throw new ApiError("bad_code", e.msg);
			if (token == ownToken)
				throw new ApiError("own_code", "that is this computer's own code");
			peers.addPending(token);
			join(token);
			changed();
			return JSONValue(["ok": JSONValue(true)]);
		});
		r.add("computers.list", (JSONValue p) {
			// a pending pairing's client is filed under the key it reached (unknown to the peer
			// list yet): its state and code go on the row of the code it proved to be
			string keyOfPending(string token)
			{
				foreach (k, t; tokenOfKey)
					if (t == token && peers.byKey(k) is null && (k in status) !is null)
						return k;
				return null;
			}
			JSONValue[] out_;
			foreach (c; peers.list)
			{
				MirrorStatus* st = c.key in status;
				if (st is null && c.key.length == 0)
					if (auto k = keyOfPending(c.token))
						st = k in status;
				JSONValue j = ["key": JSONValue(c.key.length ? c.key : pendingId(c.token)), "alias": JSONValue(c.alias_),
					"pending": JSONValue(c.key.length == 0),
					"state": JSONValue(st is null ? (c.key.length ? "offline" : "connecting") : st.state)];
				if (st !is null)
				{
					j["code"] = st.code;
					j["missing"] = st.missing;
					j["pulled"] = st.pulled;
					j["failed"] = st.failed;
					j["lastSync"] = st.lastSync;
				}
				out_ ~= j;
			}
			return JSONValue(["computers": JSONValue(out_), "alias": JSONValue(ownAlias)]);
		});
		r.add("computers.remove", (JSONValue p) {
			immutable key = getString(p, "key");
			if (!key.length)
				throw new ApiError("bad_params", "key wanted");
			string token, peerKey;
			if (auto c = peers.byKey(key))
			{
				token = c.token;
				peerKey = c.key;
			}
			else
				foreach (c; peers.list)
					if (!c.key.length && pendingId(c.token) == key)
						token = c.token;
			if (!token.length)
				throw new ApiError("not_found", "no such computer");
			peers.remove(peerKey.length ? peerKey : token);
			leave(token);
			// its clients stop — a pending one too (it holds the token among its candidates)
			foreach (s, m; clients)
				if ((peerKey.length && s.peerKey == peerKey) || (token in tokenSet(s.peerKey)))
					m.stop();
			// the removed code leaves every pending attempt's candidates; an attempt left with
			// none is over (no restart, its sessions closed)
			foreach (k; tokensOf.keys)
			{
				string[] rest;
				foreach (t; tokensOf[k])
					if (t != token)
						rest ~= t;
				if (rest.length == tokensOf[k].length)
					continue;
				if (rest.length)
					tokensOf[k] = rest;
				else if (peers.byKey(k) is null)
				{
					tokensOf.remove(k);
					removed[k] = true;
					status.remove(k);
					tokenOfKey.remove(k);
					foreach (x; sessions.get(k, null).dup)
						x.drop();
				}
			}
			if (peerKey.length)
			{
				removed[peerKey] = true;
				tokensOf.remove(peerKey);
				status.remove(peerKey);
				// it may not come back without a new pairing: forget it in the device gate
				// and close the link, so it stops mirroring this computer too
				if (devices !is null && devices.exists(peerKey))
					devices.remove(peerKey);
				foreach (x; sessions.get(peerKey, null).dup)
					x.drop();
			}
			changed();
			return JSONValue(["ok": JSONValue(true)]);
		});
	}
}
