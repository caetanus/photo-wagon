/// `/photowagon/push/1.0.0` — the raw-bytes pipe for a photo or video the phone pushes.
///
/// The metadata pipe (the JSON IPC stream) stays small and responsive; the bytes ride
/// this separate stream so a 31 MB video no longer means a 41 MB base64 line that blocks
/// the keepalive and trips the link. Wire, big-endian: `(long ticket)(long size)(size raw
/// bytes)`, and one `1` byte back as the ack. The phone then sends `library.import
/// {name, takenAt, sha256, ticket}` on the IPC stream; the desktop pairs the two by ticket.
module photowagon.core.p2p.blobpush;

import vibe.core.log : logDiagnostic, logInfo;
import vibe.core.sync : TaskMutex;

import libp2p.core.stream : Stream, readExact;
import libp2p.host.host : Host;
import libp2p.swarm.connection : Connection;

import photowagon.core.p2p.devices : DeviceRepo, DeviceState;
import photowagon.core.store.partials : PartialStore;
import photowagon.core.sync.pieces : PieceService, PieceStore, ThumbSource, pieceProtocol;

enum pushProtocol = "/photowagon/push/1.0.0";
/// The resumable pipe. Header, big-endian: `(32 bytes sha256)(long size)(long offset)`; the
/// desktop answers one status byte — 0 = go on from that offset, 2 = wrong offset, followed
/// by the `long` it has (the phone re-probes and resumes from there), 3 = refused — then the
/// bytes from `offset` to `size` follow and every 64 KiB slice lands on disk as it arrives
/// (PartialStore, by sha256), so a dropped link keeps what got through. One `1` byte back
/// at the end; the phone then sends `library.import {complete: true, sha256, …}`.
enum pushProtocolV2 = "/photowagon/push/2.0.0";
enum pushChunk = 64 * 1024;
/// The resumable pull: a phone fetches a photo's ORIGINAL by id. Request `(long id)(long
/// offset)`; the desktop answers one status byte — 0 = here it comes, then `(long size)
/// (32 bytes sha256)` and the bytes from `offset`; 3 = no such file / not allowed — so a
/// download that dropped continues from what the phone already has on disk.
enum pullProtocol = "/photowagon/pull/1.0.0";

/// Bytes that have arrived on the push pipe, waiting for their `library.import` to claim
/// them by ticket. The phone acks the blob before sending the metadata, so the bytes are
/// here by the time the import request lands; a cap drops the oldest if a phone dies mid-push.
final class BlobStash
{
	private ubyte[][long] byTicket;
	private size_t held;
	private TaskMutex m;
	private enum size_t cap = 384 * 1024 * 1024;

	this()
	{
		m = new TaskMutex;
	}

	void put(long ticket, ubyte[] bytes)
	{
		synchronized (m)
		{
			if (auto old = ticket in byTicket)
				held -= old.length;
			byTicket[ticket] = bytes;
			held += bytes.length;
			while (held > cap && byTicket.length > 1)
				foreach (k, v; byTicket)
				{
					held -= v.length;
					byTicket.remove(k);
					break;
				}
		}
	}

	/// The bytes for `ticket`, removed from the stash (null if never arrived).
	ubyte[] take(long ticket)
	{
		synchronized (m)
		{
			auto p = ticket in byTicket;
			if (p is null)
				return null;
			auto b = *p;
			held -= b.length;
			byTicket.remove(ticket);
			return b;
		}
	}
}

/// Serves the push pipe: reads one file's bytes into the stash under its ticket.
final class BlobOverP2p
{
	private BlobStash stash;
	private DeviceRepo devices;
	private PartialStore partials;
	private enum long maxBlob = 512L * 1024 * 1024;

	this(Host host, BlobStash stash, DeviceRepo devices, PartialStore partials = null)
	{
		this.stash = stash;
		this.devices = devices;
		this.partials = partials;
		host.setStreamHandler(pushProtocol, &serve);
		if (partials !is null)
			host.setStreamHandler(pushProtocolV2, &serveResumable);
	}

	private bool admitted(Connection c)
	{
		if (devices is null)
			return true;
		immutable st = devices.stateOf(c.remotePeer.toString);
		return !(st is null || st == DeviceState.revoked || st == DeviceState.paused);
	}

	/// The resumable pipe (see pushProtocolV2).
	private void serveResumable(Stream s, Connection c, string protocol)
	{
		import std.digest : toHexString, LetterCase;

		cast(void) protocol;
		scope (exit)
			s.close();
		try
		{
			if (!admitted(c))
			{
				s.write([cast(ubyte) 3]);
				return;
			}
			ubyte[32] shaRaw;
			s.readExact(shaRaw[]);
			immutable sha = toHexString!(LetterCase.lower)(shaRaw[]).idup;
			ubyte[8] head;
			s.readExact(head[]);
			immutable size = beToLong(head);
			s.readExact(head[]);
			immutable offset = beToLong(head);
			if (size <= 0 || size > maxBlob || offset < 0 || offset > size)
			{
				s.write([cast(ubyte) 3]);
				return;
			}
			long cur = partials.have(sha);
			if (offset != cur)
			{
				// stale sender (it did not re-probe): tell it where we really are
				s.write(cast(ubyte[])[2] ~ longToBe(cur)[]);
				return;
			}
			s.write([cast(ubyte) 0]);
			ubyte[pushChunk] buf;
			while (cur < size)
			{
				immutable n = cast(size_t)(size - cur < pushChunk ? size - cur : pushChunk);
				s.readExact(buf[0 .. n]);
				partials.append(sha, cur, buf[0 .. n]);   // on disk before the next slice
				cur += n;
			}
			ubyte[1] ack = [1];
			s.write(ack[]);
		}
		catch (Exception e)
		{
			try
				logDiagnostic("push2: ended: %s", e.msg);   // a drop is normal here: the spool keeps what landed
			catch (Exception)
			{
			}
		}
	}

	private void serve(Stream s, Connection c, string protocol)
	{
		cast(void) protocol;
		scope (exit)
			s.close();
		try
		{
			// only a device the desktop has admitted may push bytes (libp2p proves who the
			// peer is; the device repo says whether it is allowed)
			if (devices !is null)
			{
				immutable st = devices.stateOf(c.remotePeer.toString);
				if (st is null || st == DeviceState.revoked || st == DeviceState.paused)
					return;
			}
			ubyte[8] head;
			s.readExact(head[]);
			immutable ticket = beToLong(head);
			s.readExact(head[]);
			immutable size = beToLong(head);
			if (size <= 0 || size > maxBlob)
				return;
			auto bytes = new ubyte[cast(size_t) size];
			s.readExact(bytes);
			stash.put(ticket, bytes);
			ubyte[1] ack = [1];
			s.write(ack[]);
		}
		catch (Exception e)
		{
			try
				logDiagnostic("push: failed: %s", e.msg);
			catch (Exception)
			{
			}
		}
	}
}

/// The piece protocol (core/sync/pieces.d) on this node: complete files come from the library
/// by sha256, arriving ones live in the piece store; only admitted devices may ask.
final class PieceOverP2p
{
	import photowagon.core.library.photos : PhotoRepo;

	private PieceService service;
	private DeviceRepo devices;

	this(Host host, PhotoRepo photos, DeviceRepo devices, PieceStore store)
	{
		this.devices = devices;
		service = new PieceService((string sha) {
			import std.file : exists;

			auto have = photos.byHash(sha);
			return !have.isNull && have.get.path !is null && have.get.path.exists ? have.get.path : null;
		}, store);
		host.setStreamHandler(pieceProtocol, &serve);
	}

	/// Thumbnails ride this same piece stream (THUMB op, raw bytes); `t`: photo id → JPEG.
	void serveThumbsFrom(ThumbSource t) { service.serveThumbsFrom(t); }

	private void serve(Stream s, Connection c, string protocol)
	{
		cast(void) protocol;
		scope (exit)
			s.close();
		try
		{
			if (devices !is null)
			{
				immutable st = devices.stateOf(c.remotePeer.toString);
				if (st is null || st == DeviceState.revoked || st == DeviceState.paused)
					return;
			}
			service.serve(s);
		}
		catch (Exception e)
		{
			// a status byte back if the stream is still there, and the reason in the log
			try
				s.write([cast(ubyte) 2]);
			catch (Exception)
			{
			}
			try
				logInfo("pieces: request from %s failed: %s", c.remotePeer.toString, e.msg);
			catch (Exception)
			{
			}
		}
	}
}

/// Serves the pull pipe: a phone downloads an original (see pullProtocol). Only an admitted
/// device may; the id is the library id the phone saw in `library.page`.
final class BlobPullOverP2p
{
	import photowagon.core.library.photos : PhotoRepo;

	private PhotoRepo photos;
	private DeviceRepo devices;

	this(Host host, PhotoRepo photos, DeviceRepo devices)
	{
		this.photos = photos;
		this.devices = devices;
		host.setStreamHandler(pullProtocol, &serve);
	}

	private void serve(Stream s, Connection c, string protocol)
	{
		import std.conv : to;
		import std.file : exists, getSize;
		import vibe.core.file : openFile, FileMode;

		cast(void) protocol;
		scope (exit)
			s.close();
		try
		{
			if (devices !is null)
			{
				immutable st = devices.stateOf(c.remotePeer.toString);
				if (st is null || st == DeviceState.revoked || st == DeviceState.paused)
				{
					s.write([cast(ubyte) 3]);
					return;
				}
			}
			ubyte[8] head;
			s.readExact(head[]);
			immutable id = beToLong(head);
			s.readExact(head[]);
			immutable offset = beToLong(head);
			auto photo = photos.get(id);
			if (photo.path is null || !photo.path.exists || photo.hash.length != 64)
			{
				s.write([cast(ubyte) 3]);
				return;
			}
			immutable size = cast(long) getSize(photo.path);
			if (offset < 0 || offset > size)
			{
				s.write([cast(ubyte) 3]);
				return;
			}
			ubyte[32] sha;
			foreach (i; 0 .. 32)
				sha[i] = cast(ubyte) photo.hash[2 * i .. 2 * i + 2].to!int(16);
			s.write(cast(ubyte[])[0] ~ longToBe(size)[] ~ sha[]);
			auto fh = openFile(photo.path, FileMode.read);
			scope (exit)
				fh.close();
			fh.seek(offset);
			ubyte[pushChunk] buf;
			long remaining = size - offset;
			while (remaining > 0)
			{
				immutable n = cast(size_t)(remaining < pushChunk ? remaining : pushChunk);
				fh.read(buf[0 .. n]);
				s.write(buf[0 .. n]);
				remaining -= n;
			}
		}
		catch (Exception e)
		{
			try
				logDiagnostic("pull: ended: %s", e.msg);
			catch (Exception)
			{
			}
		}
	}
}

/// 8 big-endian bytes → long.
long beToLong(const ubyte[8] b) @safe @nogc nothrow pure
{
	long v = 0;
	foreach (x; b[])
		v = (v << 8) | x;
	return v;
}

/// long → 8 big-endian bytes.
ubyte[8] longToBe(long v) @safe @nogc nothrow pure
{
	ubyte[8] b;
	foreach_reverse (i; 0 .. 8)
	{
		b[i] = cast(ubyte)(v & 0xff);
		v >>= 8;
	}
	return b;
}
