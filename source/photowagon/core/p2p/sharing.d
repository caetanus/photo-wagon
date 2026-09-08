/// Publishing an album as a manifest, and fetching one from a peer.
///
/// A manifest is JSON stored by hash: `{version, name, photos: [{hash, thumb,
/// takenTs, takenAt, width, height, orientation, camera, size}]}`. Publishing
/// stores it and announces the hash on the DHT. Fetching pulls the manifest,
/// creates the album, answers, and keeps pulling thumbnails on its own fiber.
module photowagon.core.p2p.sharing;

import std.json;

import vibe.core.log : logInfo, logWarn;

import libp2p.core.peer_id : PeerId;
import libp2p.util.fibers : FiberGroup;

import photowagon.core.ipc.events : Events;
import photowagon.core.ipc.protocol : ApiError, getLong, getString;
import photowagon.core.library.albums : AlbumRepo;
import photowagon.core.library.photos : Filter, Photo, PhotoRepo;
import photowagon.core.p2p.blob : BlobFetcher, BlobMissing, BlobServer, validHash;
import photowagon.core.p2p.node : Node;
import photowagon.core.store.store : ContentStore;

enum manifestVersion = 1;

final class Sharing
{
	private Node node;
	private ContentStore store;
	private PhotoRepo photos;
	private AlbumRepo albums;
	private Events events;
	private BlobServer server;
	private FiberGroup fetches;

	this(Node node, ContentStore store, PhotoRepo photos, AlbumRepo albums, Events events)
	{
		this.node = node;
		this.store = store;
		this.photos = photos;
		this.albums = albums;
		this.events = events;
		server = new BlobServer(node.host, store);
		fetches = new FiberGroup((Exception e) nothrow {
			try
				logWarn("sharing: fetch failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	/// Stores the manifest, records its hash on the album, announces it. Returns the hash.
	string publish(long albumId)
	{
		auto album = albums.get(albumId);
		auto items = photos.page(Filter(0, albumId), 0, long.max);
		auto manifest = buildManifest(album.name, items);
		immutable hash = store.put(cast(const(ubyte)[]) manifest.toString());
		albums.setManifest(albumId, hash);
		try
			node.kad.startProviding(cast(const(ubyte)[]) hash);
		catch (Exception e)
			logWarn("sharing: DHT announce failed (album still shareable by address): %s", e.msg);
		logInfo("sharing: published album %s as %s", album.name, hash);
		return hash;
	}

	/// Fetches the manifest from `peerId`, creates the album, and starts
	/// fetching thumbnails in the background. Returns the new album id.
	long fetch(string peerId, string manifestHash)
	{
		if (!validHash(manifestHash))
			throw new ApiError("bad_params", "manifest is not a sha256 hex");
		PeerId peer;
		try
			peer = PeerId.fromBase58(peerId);
		catch (Exception e)
			throw new ApiError("bad_params", "bad peer id: " ~ e.msg);

		JSONValue manifest;
		{
			auto f = BlobFetcher(node.host, peer);
			ubyte[] bytes;
			try
				bytes = f.get(manifestHash);
			catch (BlobMissing)
				throw new ApiError("not_found", "peer does not have that manifest");
			manifest = parseJSON(cast(string) bytes);
		}
		if (getLong(manifest, "version") != manifestVersion)
			throw new ApiError("unsupported", "manifest version not understood");

		immutable name = getString(manifest, "name", "Shared album");
		immutable albumId = albums.create(name, null, peerId, manifestHash);
		auto entries = manifest["photos"].array;
		logInfo("sharing: album %s from %s: %s photos", name, peerId, entries.length);

		fetches.spawn(() { fetchThumbs(albumId, peer, peerId, entries); });
		return albumId;
	}

	private void fetchThumbs(long albumId, PeerId peer, string peerId, JSONValue[] entries)
	{
		auto f = BlobFetcher(node.host, peer);
		long done;
		foreach (ref e; entries)
		{
			immutable hash = getString(e, "hash");
			immutable thumb = getString(e, "thumb");
			if (!validHash(hash))
				continue;
			long photoId;
			auto known = photos.byHash(hash);
			if (!known.isNull)
				photoId = known.get.id;
			else
			{
				Photo p;
				p.hash = hash;
				p.takenTs = getLong(e, "takenTs");
				p.takenAt = getString(e, "takenAt", "");
				p.width = cast(int) getLong(e, "width");
				p.height = cast(int) getLong(e, "height");
				p.orientation = cast(int) getLong(e, "orientation", 1);
				p.camera = getString(e, "camera");
				p.size = getLong(e, "size");
				p.originPeer = peerId;
				if (validHash(thumb))
				{
					if (!store.has(thumb))
					{
						try
							store.put(f.get(thumb));
						catch (BlobMissing)
						{
						}
					}
					if (store.has(thumb))
						p.thumbHash = thumb;
				}
				photoId = photos.insert(p);
			}
			albums.addPhotos(albumId, [photoId]);
			done++;
			events.emit("p2p.fetch", JSONValue([
				"albumId": JSONValue(albumId), "done": JSONValue(done), "total": JSONValue(entries.length)
			]));
		}
		events.emit("library.changed", JSONValue.emptyObject);
	}

	void close() nothrow
	{
		fetches.stopAll();
	}
}

JSONValue buildManifest(string name, Photo[] items)
{
	JSONValue[] ps;
	foreach (ref p; items)
	{
		ps ~= JSONValue([
			"hash": JSONValue(p.hash),
			"thumb": p.thumbHash is null ? JSONValue(null) : JSONValue(p.thumbHash),
			"takenTs": JSONValue(p.takenTs),
			"takenAt": JSONValue(p.takenAt),
			"width": JSONValue(p.width),
			"height": JSONValue(p.height),
			"orientation": JSONValue(p.orientation),
			"camera": p.camera is null ? JSONValue(null) : JSONValue(p.camera),
			"size": JSONValue(p.size),
		]);
	}
	return JSONValue(["version": JSONValue(manifestVersion), "name": JSONValue(name), "photos": JSONValue(ps)]);
}

unittest
{
	Photo p = {hash: "h", thumbHash: "t", takenTs: 5, takenAt: "x", width: 1, height: 2};
	auto m = buildManifest("n", [p]);
	assert(m["version"].integer == 1);
	assert(m["photos"][0]["thumb"].str == "t");
}
