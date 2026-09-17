// CastService — the "cast to TV" glue: find the Cast devices on the network,
// serve a photo over a tiny HTTP endpoint, and drive one CastSession so the photo
// (and the next, and the next) shows on the chosen screen.
//
// Only Google Cast for now (Chromecast, Cast-enabled TVs). DLNA for the older
// smart TVs can slot in beside this later — the media server and the photo
// rendering are already protocol-neutral.
module photowagon.core.casting.service;

import std.array : split;
import std.conv : to;
import std.json;
import std.process : execute;
import std.string : strip, startsWith, indexOf, replace;

import vibe.core.net : listenTCP, TCPConnection, TCPListener;
import vibe.core.concurrency : async;
import vibe.core.log : logInfo, logDiagnostic;
import vibe.stream.operations : readLine;

import photowagon.core.casting.chromecast : CastSession;
import photowagon.core.library.photos : PhotoRepo, Photo;
import photowagon.core.thumbs.vips : smallJpegOfBytes;

import std.file : read, exists;

/// dlnaShow on the worker pool (blocking HTTP/SOAP).
private bool dlnaShowSync(string control, string url)
{
	import photowagon.core.casting.dlna : dlnaShow;
	try
		dlnaShow(control, url);
	catch (Exception e)
	{
		import vibe.core.log : logDiagnostic;
		logDiagnostic("cast: dlna show: %s", e.msg);
	}
	return true;
}

/// avahi-browse, off the event loop.
private string avahiCast()
{
	try
	{
		auto r = execute(["avahi-browse", "-rptk", "_googlecast._tcp"]);
		return r.status == 0 ? r.output : "";
	}
	catch (Exception e)
		return "";
}

final class CastService
{
	private PhotoRepo photos;
	private TCPListener listener;
	private bool mediaUp;
	private ushort mediaPort;
	private ubyte[][string] blobs;   // key → JPEG bytes the TV fetches
	private CastSession session;
	private long counter;
	private int slideGen;   // bumped to end a running slideshow

	this(PhotoRepo photos)
	{
		this.photos = photos;
	}

	/// `{devices:[{name, host, port}]}` — the Cast screens seen on the LAN right now.
	JSONValue devices()
	{
		JSONValue[] out_;
		immutable text = async(&avahiCast).getResult();
		foreach (line; text.split("\n"))
		{
			// `=;iface;proto;instance;type;domain;host;address;port;txt`
			if (!line.startsWith("="))
				continue;
			auto f = line.split(";");
			if (f.length < 9)
				continue;
			immutable address = f[7];
			immutable port = f[8];
			string name = f[3].replace("\\032", " ");   // avahi escapes spaces
			// a nicer name from the TXT record's fn= (the TXT is a quoted blob after the port)
			import std.array : join;
			immutable txt = f.length > 9 ? f[9 .. $].join(";") : "";
			immutable fi = txt.indexOf("fn=");
			if (fi >= 0)
			{
				auto rest = txt[fi + 3 .. $];
				immutable end = rest.indexOf('"');   // fn=Name"
				name = end >= 0 ? rest[0 .. end] : rest;
			}
			if (address.length && port.length)
				out_ ~= JSONValue([
					"name": JSONValue(name),
					"host": JSONValue(address),
					"port": JSONValue(port),
					"kind": JSONValue("chromecast"),
					"control": JSONValue(""),
				]);
		}
		// DLNA renderers (LG WebOS, Samsung, most smart TVs) over SSDP
		import photowagon.core.casting.dlna : discoverDlna;
		foreach (d; async(&discoverDlna).getResult())
			out_ ~= JSONValue([
				"name": JSONValue(d.name),
				"host": JSONValue(d.host),
				"port": JSONValue("0"),
				"kind": JSONValue("dlna"),
				"control": JSONValue(d.control),
			]);
		return JSONValue(["devices": JSONValue(out_)]);
	}

	/// Show photo `id` on a device (Chromecast at host:port, or a DLNA renderer at `control`).
	void castPhoto(string host, ushort port, string kind, string control, long id)
	{
		slideGen++;   // a single cast ends any running slideshow
		showPhoto(host, port, kind, control, id);
	}

	/// A slideshow of every photograph, oldest first, one every `intervalMs`, looping,
	/// until `stop()` or another cast supersedes it.
	void castSlideshow(string host, ushort port, string kind, string control, int intervalMs)
	{
		import photowagon.core.library.photos : Filter;
		import vibe.core.core : runTask, sleep;
		import core.time : msecs;

		Filter f;
		f.kind = "photo";
		auto page = photos.page(f, 0, 100_000);   // ids in time order; the set is bounded by the library
		long[] ids;
		foreach (ref ph; page)
			ids ~= ph.id;
		if (ids.length == 0)
			return;

		slideGen++;
		immutable myGen = slideGen;
		immutable ms = intervalMs < 1000 ? 1000 : intervalMs;
		logInfo("cast: slideshow of %s photos every %s ms on %s", ids.length, ms, host);
		runTask(() nothrow {
			size_t i;
			while (true)
			{
				if (myGen != slideGen)
					break;
				try
				{
					showPhoto(host, port, kind, control, ids[i % ids.length]);
					i++;
					sleep(ms.msecs);
				}
				catch (Exception e)
				{
					try logDiagnostic("cast: slideshow: %s", e.msg); catch (Exception) {}
					break;
				}
			}
		});
	}

	void stop() nothrow
	{
		slideGen++;
		try
		{
			if (session !is null)
			{
				session.close();
				session = null;
			}
			blobs = null;
		}
		catch (Exception)
		{
		}
	}

	// --- rendering one photo onto the current session -------------------------------

	private void showPhoto(string host, ushort port, string kind, string control, long id)
	{
		auto p = photos.get(id);
		if (!p.path.exists)
			throw new Exception("the photo's file is missing");
		// A TV-sized JPEG: fast to fetch, correctly rotated, and every screen reads it.
		auto jpeg = smallJpegOfBytes(cast(ubyte[]) read(p.path), 1920, 85);
		immutable key = (counter++).to!string;
		blobs[key] = jpeg;
		// keep only the last few blobs — the TV may still be fetching the one before this
		if (blobs.length > 4)
			foreach (k; blobs.keys)
				if (k.to!long < counter - 4)
					blobs.remove(k);
		ensureMediaServer();

		immutable url = "http://" ~ localIpToward(host) ~ ":" ~ mediaPort.to!string ~ "/cast/" ~ key;
		if (kind == "dlna")
			async(&dlnaShowSync, control, url).getResult();   // SOAP off the event loop
		else
		{
			if (session is null)
			{
				session = new CastSession(host, port);
				session.start();
			}
			session.show(url);
		}
		logInfo("cast: showing photo %s on %s (%s)", id, host, kind);
	}

	// --- the media server -----------------------------------------------------------

	private void ensureMediaServer()
	{
		if (mediaUp)
			return;
		listener = listenTCP(0, &serve, "0.0.0.0");   // port 0 = the kernel picks one
		mediaPort = listener.bindAddress.port;
		mediaUp = true;
		logDiagnostic("cast: media server on :%s", mediaPort);
	}

	private void serve(TCPConnection c) nothrow
	{
		try
		{
			auto reqLine = cast(string) c.readLine(4096).idup;   // "GET /cast/<key> HTTP/1.1"
			while (c.connected)
			{
				auto h = c.readLine(8192);
				if (h.length == 0)
					break;   // blank line ends the headers
			}
			auto parts = reqLine.split(" ");
			string key;
			if (parts.length >= 2 && parts[1].startsWith("/cast/"))
				key = parts[1]["/cast/".length .. $];
			auto blob = key in blobs;
			if (blob is null)
			{
				c.write(cast(const(ubyte)[]) "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
				c.close();
				return;
			}
			string head = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: "
				~ blob.length.to!string ~ "\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
			c.write(cast(const(ubyte)[]) head);
			c.write(*blob);
			c.close();
		}
		catch (Exception e)
		{
			try c.close(); catch (Exception) {}
		}
	}

	/// Our own IP on the route to `host` — the address the TV will fetch the photo from.
	private static string localIpToward(string host)
	{
		import std.socket : UdpSocket, InternetAddress, Address;
		try
		{
			auto s = new UdpSocket();
			scope (exit) s.close();
			s.connect(new InternetAddress(host, 9));   // no packet is sent; this just picks a source
			return (cast(InternetAddress) s.localAddress).toAddrString();
		}
		catch (Exception)
			return "127.0.0.1";
	}
}
