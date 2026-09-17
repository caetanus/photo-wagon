// DLNA / UPnP AVTransport — the other way onto a TV (LG WebOS, Samsung, most
// smart TVs). No Google account, no registration: the TV is a "MediaRenderer" we
// find over SSDP and drive with two SOAP calls (SetAVTransportURI + Play). The TV
// fetches the photo from our media server itself, the same as a Chromecast.
module photowagon.core.casting.dlna;

import std.conv : to;
import std.net.curl : HTTP, get, post;
import std.regex : matchFirst, regex;
import std.socket;
import std.string : indexOf, toLower, strip, startsWith, splitLines;

import core.time : MonoTime, dur, seconds, msecs;

import vibe.core.log : logDiagnostic;

struct DlnaDevice
{
	string name;
	string host;      // for display
	string control;   // full AVTransport control URL
}

/// SSDP-discover the MediaRenderers on the LAN and resolve each one's AVTransport.
DlnaDevice[] discoverDlna()
{
	string[string] locByHost;   // dedupe: one LOCATION per host
	try
	{
		auto s = new UdpSocket();
		scope (exit) s.close();
		s.setOption(SocketOptionLevel.SOCKET, SocketOption.RCVTIMEO, 700.msecs);
		immutable msg =
			"M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\n" ~
			"MAN: \"ssdp:discover\"\r\nMX: 2\r\n" ~
			"ST: urn:schemas-upnp-org:device:MediaRenderer:1\r\n\r\n";
		auto group = new InternetAddress("239.255.255.250", 1900);
		s.sendTo(cast(const(void)[]) msg, group);
		auto buf = new ubyte[4096];
		immutable deadline = MonoTime.currTime + 2500.msecs;
		while (MonoTime.currTime < deadline)
		{
			Address from;
			auto n = s.receiveFrom(buf, from);
			if (n <= 0)
				continue;   // timeout tick
			immutable resp = cast(string) buf[0 .. n].idup;
			immutable loc = headerValue(resp, "location");
			if (loc.length)
				locByHost[hostOf(loc)] = loc;
		}
	}
	catch (Exception e)
		logDiagnostic("dlna: discovery: %s", e.msg);

	DlnaDevice[] out_;
	foreach (host, loc; locByHost)
	{
		try
		{
			auto d = describe(loc);
			if (d.control.length)
				out_ ~= d;
		}
		catch (Exception e)
			logDiagnostic("dlna: describe %s: %s", loc, e.msg);
	}
	return out_;
}

/// Put an image (a URL our media server serves) on the renderer at `control`.
void dlnaShow(string control, string url)
{
	immutable didl =
		`<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" ` ~
		`xmlns:dc="http://purl.org/dc/elements/1.1/" ` ~
		`xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">` ~
		`<item id="0" parentID="-1" restricted="1"><dc:title>Photo</dc:title>` ~
		`<upnp:class>object.item.imageItem.photo</upnp:class>` ~
		`<res protocolInfo="http-get:*:image/jpeg:*">` ~ xmlEscape(url) ~ `</res></item></DIDL-Lite>`;
	immutable setBody = soap("SetAVTransportURI",
		"<InstanceID>0</InstanceID><CurrentURI>" ~ xmlEscape(url) ~ "</CurrentURI>" ~
		"<CurrentURIMetaData>" ~ xmlEscape(didl) ~ "</CurrentURIMetaData>");
	soapPost(control, "SetAVTransportURI", setBody, 8.seconds);
	// Play: best-effort and short — many TVs already display on SetAVTransportURI
	// and never answer Play for a still image.
	try
		soapPost(control, "Play", soap("Play", "<InstanceID>0</InstanceID><Speed>1</Speed>"), 2.seconds);
	catch (Exception)
	{
	}
}

// --- helpers --------------------------------------------------------------------

private DlnaDevice describe(string location)
{
	auto xml = cast(string) get(location);
	DlnaDevice d;
	d.host = bareHost(location);   // just the IP, for building the media URL the TV fetches
	auto nm = xml.matchFirst(regex(`<friendlyName>(.*?)</friendlyName>`, "s"));
	d.name = nm.empty ? "TV" : nm[1].strip;
	// the AVTransport <service> block, then its <controlURL>
	auto svc = xml.matchFirst(regex(`<service>(?:(?!</service>)[\s\S])*?AVTransport:1(?:(?!</service>)[\s\S])*?</service>`));
	if (!svc.empty)
	{
		auto cu = svc[0].matchFirst(regex(`<controlURL>(.*?)</controlURL>`, "s"));
		if (!cu.empty)
			d.control = resolve(location, cu[1].strip);
	}
	return d;
}

private string soap(string action, string inner)
{
	return `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ` ~
		`s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>` ~
		`<u:` ~ action ~ ` xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">` ~ inner ~
		`</u:` ~ action ~ `></s:Body></s:Envelope>`;
}

private void soapPost(string control, string action, string body_, core.time.Duration timeout)
{
	auto http = HTTP();
	http.operationTimeout = timeout;
	http.addRequestHeader("Content-Type", `text/xml; charset="utf-8"`);
	http.addRequestHeader("SOAPACTION", `"urn:schemas-upnp-org:service:AVTransport:1#` ~ action ~ `"`);
	cast(void) post!ubyte(control, body_, http);   // raw bytes: the LG answers with charset "utf-8" (quoted) that curl won't decode
}

/// A header value from a raw HTTP/SSDP response (case-insensitive name).
private string headerValue(string resp, string name)
{
	foreach (line; resp.splitLines)
	{
		immutable c = line.indexOf(':');
		if (c > 0 && line[0 .. c].strip.toLower == name)
			return line[c + 1 .. $].strip;
	}
	return "";
}

/// scheme://host:port of a URL.
private string hostOf(string url)
{
	immutable s = url.indexOf("://");
	if (s < 0)
		return url;
	immutable rest = url[s + 3 .. $];
	immutable slash = rest.indexOf('/');
	return url[0 .. s + 3] ~ (slash < 0 ? rest : rest[0 .. slash]);
}

/// Just the host (IP) of a URL, without scheme or port.
private string bareHost(string url)
{
	immutable s = url.indexOf("://");
	auto rest = s < 0 ? url : url[s + 3 .. $];
	immutable colon = rest.indexOf(':');
	immutable slash = rest.indexOf('/');
	auto end = rest.length;
	if (colon >= 0 && colon < end)
		end = colon;
	if (slash >= 0 && slash < end)
		end = slash;
	return rest[0 .. end];
}

/// Resolve a controlURL (usually absolute-path) against the device-description URL.
private string resolve(string base, string path)
{
	if (path.startsWith("http://") || path.startsWith("https://"))
		return path;
	if (path.startsWith("/"))
		return hostOf(base) ~ path;
	return hostOf(base) ~ "/" ~ path;
}

private string xmlEscape(string s)
{
	string o;
	foreach (char c; s)
		switch (c)
		{
		case '&': o ~= "&amp;"; break;
		case '<': o ~= "&lt;"; break;
		case '>': o ~= "&gt;"; break;
		case '"': o ~= "&quot;"; break;
		default: o ~= c; break;
		}
	return o;
}
