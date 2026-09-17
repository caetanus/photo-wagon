// A minimal Google Cast (CASTV2) sender: enough to throw a photo — and then the
// next, and the next — onto a Chromecast or a Cast-enabled TV.
//
// The wire protocol is length-prefixed protobuf `CastMessage` frames over TLS on
// port 8009. Each frame carries a namespace and a JSON payload. We hand-encode
// the six fields we need (no protobuf library) and speak just four namespaces:
// connection (CONNECT), heartbeat (PING/PONG), receiver (LAUNCH + status) and
// media (LOAD). The Chromecast fetches the image itself over HTTP from us, so a
// tiny media server (cast/mediaserver.d) hands it the bytes.
module photowagon.core.casting.chromecast;

import std.json;
import std.conv : to;

import core.time : seconds, msecs;

import vibe.core.core : runTask, sleep;
import vibe.core.net : connectTCP, TCPConnection;
import vibe.core.log : logInfo, logDiagnostic;
import vibe.stream.tls;

private enum ns_connection = "urn:x-cast:com.google.cast.tp.connection";
private enum ns_heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat";
private enum ns_receiver = "urn:x-cast:com.google.cast.receiver";
private enum ns_media = "urn:x-cast:com.google.cast.media";
private enum defaultMediaReceiver = "CC1AD845";   // Google's Default Media Receiver app

// --- CastMessage framing --------------------------------------------------------------

private void putVarint(ref ubyte[] b, ulong v)
{
	while (v >= 0x80)
	{
		b ~= cast(ubyte)(v | 0x80);
		v >>= 7;
	}
	b ~= cast(ubyte) v;
}

private void putStr(ref ubyte[] b, int field, string s)
{
	b ~= cast(ubyte)((field << 3) | 2);   // wire type 2 = length-delimited
	putVarint(b, s.length);
	b ~= cast(const(ubyte)[]) s;
}

/// A CastMessage with protocol_version=0, payload_type=0 (string), framed with a
/// 4-byte big-endian length.
private ubyte[] frame(string source, string dest, string namespace, string payload)
{
	ubyte[] m;
	m ~= cast(ubyte)((1 << 3) | 0);
	putVarint(m, 0);                       // protocol_version = CASTV2_1_0
	putStr(m, 2, source);
	putStr(m, 3, dest);
	putStr(m, 4, namespace);
	m ~= cast(ubyte)((5 << 3) | 0);
	putVarint(m, 0);                       // payload_type = STRING
	putStr(m, 6, payload);
	ubyte[] out_;
	out_ ~= cast(ubyte)(m.length >> 24);
	out_ ~= cast(ubyte)(m.length >> 16);
	out_ ~= cast(ubyte)(m.length >> 8);
	out_ ~= cast(ubyte)(m.length);
	out_ ~= m;
	return out_;
}

private ulong getVarint(const(ubyte)[] b, ref size_t i)
{
	ulong v;
	int shift;
	while (i < b.length)
	{
		immutable c = b[i++];
		v |= cast(ulong)(c & 0x7f) << shift;
		if (!(c & 0x80))
			break;
		shift += 7;
	}
	return v;
}

/// Pull the namespace (field 4) and the JSON payload (field 6) out of a frame body.
private void parse(const(ubyte)[] b, out string namespace, out string payload)
{
	size_t i;
	while (i < b.length)
	{
		immutable tag = getVarint(b, i);
		immutable field = cast(int)(tag >> 3);
		immutable wire = cast(int)(tag & 7);
		if (wire == 0)
		{
			getVarint(b, i);
			continue;
		}
		if (wire == 2)
		{
			immutable len = cast(size_t) getVarint(b, i);
			auto s = cast(string)(b[i .. i + len].idup);
			i += len;
			if (field == 4)
				namespace = s;
			else if (field == 6)
				payload = s;
			continue;
		}
		break;   // a wire type we do not expect
	}
}

// --- the session ----------------------------------------------------------------------

/// One live cast to one device. Construct, `start()`, then `show(url)` as often as
/// you like; `close()` when done.
final class CastSession
{
	private string host;
	private ushort port;
	private TLSStream tls;
	private string appTransport;   // the launched receiver app's transportId
	private string pendingUrl;     // an image asked for before the app was ready
	private int reqId = 1;
	private bool running;
	private bool connected;        // CONNECTed to the app and ready to LOAD

	this(string host, ushort port = 8009)
	{
		this.host = host;
		this.port = port;
	}

	/// Open the TLS channel, launch the media receiver, and start reading.
	void start()
	{
		if (running)
			return;
		running = true;
		runTask(() nothrow {
			try
				connect();
			catch (Exception e)
			{
				try logDiagnostic("cast: %s: %s", host, e.msg); catch (Exception) {}
				running = false;
			}
		});
	}

	/// Put an image on the screen (a URL our media server serves).
	void show(string url)
	{
		pendingUrl = url;
		if (connected)
			load(url);
	}

	void close() nothrow
	{
		running = false;
		try
		{
			if (tls !is null)
			{
				send("sender-0", "receiver-0", ns_connection, `{"type":"CLOSE"}`);
				tls.finalize();
			}
		}
		catch (Exception)
		{
		}
	}

	// --- internals ------------------------------------------------------------------

	private void connect()
	{
		auto raw = connectTCP(host, port);
		auto ctx = createTLSContext(TLSContextKind.client);
		ctx.peerValidationMode = TLSPeerValidationMode.none;   // Chromecast certs chain to Google's own root
		tls = createTLSStream(raw, ctx, TLSStreamState.connecting, host, raw.remoteAddress);
		logInfo("cast: TLS channel up to %s:%s", host, port);

		send("sender-0", "receiver-0", ns_connection, `{"type":"CONNECT"}`);
		send("sender-0", "receiver-0", ns_receiver,
			`{"type":"LAUNCH","appId":"` ~ defaultMediaReceiver ~ `","requestId":` ~ (reqId++).to!string ~ `}`);

		runTask(() nothrow { heartbeat(); });

		auto len = new ubyte[4];
		while (running)
		{
			tls.read(len);
			immutable n = (cast(size_t) len[0] << 24) | (cast(size_t) len[1] << 16)
				| (cast(size_t) len[2] << 8) | cast(size_t) len[3];
			if (n == 0 || n > 8 * 1024 * 1024)
				break;
			auto body_ = new ubyte[n];
			tls.read(body_);
			string namespace, payload;
			parse(body_, namespace, payload);
			handle(namespace, payload);
		}
	}

	private void handle(string namespace, string payload)
	{
		if (namespace != ns_heartbeat)
			logDiagnostic("cast<< [%s] %s", namespace, payload);
		if (namespace == ns_heartbeat)
		{
			if (payload.length && parseJSON(payload)["type"].str == "PING")
				send("sender-0", "receiver-0", ns_heartbeat, `{"type":"PONG"}`);
			return;
		}
		if (namespace == ns_receiver && payload.length)
		{
			auto j = parseJSON(payload);
			if ("status" in j && "applications" in j["status"])
				foreach (app; j["status"]["applications"].array)
					if ("transportId" in app)
					{
						immutable t = app["transportId"].str;
						if (t != appTransport)
						{
							appTransport = t;
							logInfo("cast: media receiver ready (%s)", appTransport);
							// virtual-connect to the app, then load whatever is waiting
							send("sender-0", appTransport, ns_connection, `{"type":"CONNECT"}`);
							connected = true;
							if (pendingUrl.length)
								load(pendingUrl);
						}
					}
		}
	}

	private void load(string url)
	{
		if (appTransport.length == 0)
			return;
		JSONValue media = JSONValue([
			"contentId": JSONValue(url),
			"streamType": JSONValue("NONE"),
			"contentType": JSONValue("image/jpeg"),
		]);
		JSONValue msg = JSONValue([
			"type": JSONValue("LOAD"),
			"requestId": JSONValue(reqId++),
			"autoplay": JSONValue(true),
			"media": media,
		]);
		logInfo("cast: LOAD %s", url);
		send("sender-0", appTransport, ns_media, msg.toString());
	}

	private void heartbeat() nothrow
	{
		while (running)
		{
			try
			{
				send("sender-0", "receiver-0", ns_heartbeat, `{"type":"PING"}`);
				sleep(5.seconds);
			}
			catch (Exception)
				break;
		}
	}

	private void send(string source, string dest, string namespace, string payload)
	{
		if (tls is null)
			return;
		tls.write(frame(source, dest, namespace, payload));
	}
}
