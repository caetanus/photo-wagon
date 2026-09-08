/// Pairing a phone: a secret token, the addresses a phone can reach us at,
/// and the QR code that carries both. The token lives in the data dir so a
/// paired phone stays paired across restarts.
///
/// Code format: `pw://<token>@<ip>:<port>[,<ip>:<port>…]`
module photowagon.core.pairing;

import std.conv : to;
import std.file : exists, readText, write, setAttributes;
import std.json;
import std.path : buildPath;
import std.string : strip, toStringz, fromStringz, startsWith;

public import photowagon.core.pairingcode : PairingInfo, pairingCode, parsePairingCode;

private extern (C) nothrow @nogc
{
	struct QRcode
	{
		int version_;
		int width;
		ubyte* data; // one byte per module, bit 0 set = dark
	}

	QRcode* QRcode_encodeString(const char* str, int version_, int level, int hint, int casesensitive);
	void QRcode_free(QRcode* code);
}

private enum QR_ECLEVEL_M = 1;
private enum QR_MODE_8 = 2;

private extern (C) nothrow @nogc
{
	import core.sys.posix.sys.socket : sockaddr;

	struct ifaddrs
	{
		ifaddrs* ifa_next;
		char* ifa_name;
		uint ifa_flags;
		sockaddr* ifa_addr;
		sockaddr* ifa_netmask;
		sockaddr* ifa_ifu;
		void* ifa_data;
	}

	int getifaddrs(ifaddrs** ifap);
	void freeifaddrs(ifaddrs* ifa);
}

/// 32 hex chars from /dev/urandom, created on first use.
string loadOrCreateToken(string path)
{
	if (path.exists)
	{
		auto t = readText(path).strip;
		if (t.length >= 16)
			return t;
	}
	import std.stdio : File;
	import std.digest : toHexString, LetterCase;

	ubyte[16] raw;
	File("/dev/urandom", "rb").rawRead(raw[]);
	immutable token = toHexString!(LetterCase.lower)(raw).idup;
	write(path, token ~ "\n");
	import std.conv : octal;

	setAttributes(path, octal!600);
	return token;
}

/// IPv4 addresses of the machine's real interfaces (no loopback, no virtual bridges).
string[] lanAddresses()
{
	import core.sys.posix.sys.socket : sockaddr, AF_INET;
	import core.sys.posix.netinet.in_ : sockaddr_in;
	import core.sys.posix.arpa.inet : inet_ntop;

	string[] out_;
	ifaddrs* list;
	if (getifaddrs(&list) != 0)
		return out_;
	scope (exit)
		freeifaddrs(list);
	for (auto p = list; p !is null; p = p.ifa_next)
	{
		if (p.ifa_addr is null || p.ifa_addr.sa_family != AF_INET)
			continue;
		immutable name = p.ifa_name.fromStringz.idup;
		if (name == "lo" || name.startsWith("docker") || name.startsWith("br-") || name.startsWith("veth")
				|| name.startsWith("virbr") || name.startsWith("tun") || name.startsWith("tailscale"))
			continue;
		char[64] buf;
		auto sin = cast(sockaddr_in*) p.ifa_addr;
		auto s = inet_ntop(AF_INET, &sin.sin_addr, buf.ptr, buf.length);
		if (s is null)
			continue;
		immutable addr = s.fromStringz.idup;
		if (addr.startsWith("127."))
			continue;
		out_ ~= addr;
	}
	return out_;
}

/// The QR modules as rows of "0"/"1" strings, plus the version's width.
JSONValue qrMatrix(string text)
{
	auto qr = QRcode_encodeString(text.toStringz, 0, QR_ECLEVEL_M, QR_MODE_8, 1);
	if (qr is null)
		throw new Exception("qrencode failed");
	scope (exit)
		QRcode_free(qr);
	immutable w = qr.width;
	JSONValue[] rows;
	rows.reserve(w);
	foreach (y; 0 .. w)
	{
		auto row = new char[w];
		foreach (x; 0 .. w)
			row[x] = (qr.data[y * w + x] & 1) ? '1' : '0';
		rows ~= JSONValue(cast(string) row);
	}
	return JSONValue(["width": JSONValue(w), "rows": JSONValue(rows)]);
}

/// The QR as a PNG data: URL, `scale` pixels per module, a 4-module quiet zone,
/// so the UI shows it 1:1 (no resampling to blur the modules).
string qrPngDataUrl(string text, int scale = 8)
{
	import std.base64 : Base64;

	auto qr = QRcode_encodeString(text.toStringz, 0, QR_ECLEVEL_M, QR_MODE_8, 1);
	if (qr is null)
		throw new Exception("qrencode failed");
	scope (exit)
		QRcode_free(qr);
	immutable w = qr.width;
	immutable quiet = 4;
	immutable px = (w + 2 * quiet) * scale;
	auto pixels = new ubyte[px * px];
	pixels[] = 255;
	foreach (y; 0 .. w)
		foreach (x; 0 .. w)
			if (qr.data[y * w + x] & 1)
				foreach (dy; 0 .. scale)
				{
					immutable row = (quiet + y) * scale + dy;
					immutable col = (quiet + x) * scale;
					pixels[row * px + col .. row * px + col + scale] = 0;
				}
	return "data:image/png;base64," ~ cast(string) Base64.encode(encodeGrayPng(pixels, px, px));
}

/// A minimal PNG writer: 8-bit grayscale, filter 0 on every row, one IDAT.
ubyte[] encodeGrayPng(const(ubyte)[] gray, int width, int height)
{
	import std.zlib : compress;
	import std.digest.crc : crc32Of;
	import std.bitmanip : nativeToBigEndian;

	ubyte[] raw;
	raw.reserve((width + 1) * height);
	foreach (y; 0 .. height)
	{
		raw ~= 0; // filter: none
		raw ~= gray[y * width .. (y + 1) * width];
	}
	ubyte[] chunk(string type, const(ubyte)[] data)
	{
		ubyte[] c = nativeToBigEndian(cast(uint) data.length)[] ~ cast(ubyte[]) type ~ data;
		auto crc = crc32Of(c[4 .. $]);
		// crc32Of yields little-endian bytes; PNG wants big-endian
		return c ~ [crc[3], crc[2], crc[1], crc[0]];
	}

	ubyte[] ihdr = nativeToBigEndian(cast(uint) width)[] ~ nativeToBigEndian(cast(uint) height)[]
		~ cast(ubyte[]) [8, 0, 0, 0, 0]; // depth 8, grayscale, deflate, filter 0, no interlace
	return cast(ubyte[]) [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A]
		~ chunk("IHDR", ihdr) ~ chunk("IDAT", compress(raw, 6)) ~ chunk("IEND", []);
}

unittest
{
	auto m = qrMatrix("pw://t@1.2.3.4:5");
	assert(m["width"].integer >= 21);
	assert(m["rows"].array.length == m["width"].integer);
	assert(m["rows"][0].str[0 .. 7] == "1111111"); // finder pattern
}

unittest
{
	auto png = encodeGrayPng([0, 255, 255, 0], 2, 2);
	assert(png[0 .. 8] == [0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A]);
	assert(png[12 .. 16] == cast(ubyte[]) "IHDR");
	auto url = qrPngDataUrl("pw://t@1.2.3.4:5", 2);
	assert(url.length > 100 && url[0 .. 22] == "data:image/png;base64,");
}
