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
			// a nicer name from the TXT record's fn= if present
			if (f.length >= 10)
				foreach (kv; f[9 .. $])
				{
					auto t = kv.strip;
					if (t.startsWith("fn="))
						name = t[3 .. $];
				}
			if (address.length && port.length)
				out_ ~= JSONValue([
					"name": JSONValue(name),
					"host": JSONValue(address),
					"port": JSONValue(port),
				]);
		}
		return JSONValue(["devices": JSONValue(out_)]);
	}

	/// Show photo `id` on the device at host:port (starting a session if needed).
	void castPhoto(string host, ushort port, long id)
	{
		auto p = photos.get(id);
		if (!p.path.exists)
			throw new Exception("the photo's file is missing");
		// A TV-sized JPEG: fast to fetch, correctly rotated, and every Cast device reads it.
		auto jpeg = smallJpegOfBytes(cast(ubyte[]) read(p.path), 1920, 85);
		immutable key = (counter++).to!string;
		blobs[key] = jpeg;
		ensureMediaServer();

		immutable url = "http://" ~ localIpToward(host) ~ ":" ~ mediaPort.to!string ~ "/cast/" ~ key;
		if (session is null)
		{
			session = new CastSession(host, port);
			session.start();
		}
		session.show(url);
		logInfo("cast: showing photo %s on %s:%s", id, host, port);
	}

	void stop() nothrow
	{
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
