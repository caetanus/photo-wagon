/// `/photowagon/push/1.0.0` — the raw-bytes pipe for a photo or video the phone pushes.
///
/// The metadata pipe (the JSON IPC stream) stays small and responsive; the bytes ride
/// this separate stream so a 31 MB video no longer means a 41 MB base64 line that blocks
/// the keepalive and trips the link. Wire, big-endian: `(long ticket)(long size)(size raw
/// bytes)`, and one `1` byte back as the ack. The phone then sends `library.import
/// {name, takenAt, sha256, ticket}` on the IPC stream; the desktop pairs the two by ticket.
module photowagon.core.p2p.blobpush;

import vibe.core.log : logDiagnostic;
import vibe.core.sync : TaskMutex;

import libp2p.core.stream : Stream, readExact;
import libp2p.host.host : Host;
import libp2p.swarm.connection : Connection;

import photowagon.core.p2p.devices : DeviceRepo, DeviceState;

enum pushProtocol = "/photowagon/push/1.0.0";

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
	private enum long maxBlob = 512L * 1024 * 1024;

	this(Host host, BlobStash stash, DeviceRepo devices)
	{
		this.stash = stash;
		this.devices = devices;
		host.setStreamHandler(pushProtocol, &serve);
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
