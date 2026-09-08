/// Albums: named, ordered sets of photos; the unit of sharing.
module photowagon.core.library.albums;

import std.json;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.protocol : ApiError;

struct Album
{
	long id;
	string name;
	long photos;
	string manifest; // hash of the published manifest, or null
	string originPeer; // null when ours
}

final class AlbumRepo
{
	private Database db;

	this(Database db)
	{
		this.db = db;
	}

	long create(string name, long[] photoIds = null, string originPeer = null, string manifest = null)
	{
		import std.datetime : Clock;

		if (name.length == 0)
			throw new ApiError("bad_params", "album needs a name");
		return db.transaction!long({
			auto s = db.prepare("INSERT INTO albums (name, created_at, manifest, origin_peer) VALUES (?, ?, ?, ?)");
			s.bind(1, name).bind(2, Clock.currTime.toUnixTime).bind(3, manifest).bind(4, originPeer);
			s.run();
			immutable id = db.lastInsertId();
			addPhotosUnchecked(id, photoIds);
			return id;
		});
	}

	void addPhotos(long albumId, long[] photoIds)
	{
		get(albumId);
		db.transaction!void({ addPhotosUnchecked(albumId, photoIds); });
	}

	private void addPhotosUnchecked(long albumId, long[] photoIds)
	{
		if (photoIds.length == 0)
			return;
		long pos;
		{
			auto m = db.prepare("SELECT coalesce(max(position), -1) FROM album_photos WHERE album_id = ?");
			m.bind(1, albumId);
			m.step();
			pos = m.getLong(0) + 1;
		}
		auto s = db.prepare("INSERT OR IGNORE INTO album_photos (album_id, photo_id, position) VALUES (?, ?, ?)");
		foreach (pid; photoIds)
		{
			s.reset();
			s.bind(1, albumId).bind(2, pid).bind(3, pos++);
			s.run();
		}
	}

	Album get(long id)
	{
		auto s = db.prepare(select ~ " WHERE a.id = ?");
		s.bind(1, id);
		if (!s.step())
			throw new ApiError("not_found", "no such album");
		return read(s);
	}

	Album[] list()
	{
		auto s = db.prepare(select ~ " ORDER BY a.created_at DESC, a.id DESC");
		Album[] out_;
		while (s.step())
			out_ ~= read(s);
		return out_;
	}

	void setManifest(long id, string hash)
	{
		auto s = db.prepare("UPDATE albums SET manifest = ? WHERE id = ?");
		s.bind(1, hash).bind(2, id);
		s.run();
	}

	private enum select = `SELECT a.id, a.name, (SELECT count(*) FROM album_photos WHERE album_id = a.id),
		a.manifest, a.origin_peer FROM albums a`;

	private static Album read(S)(ref S s)
	{
		return Album(s.getLong(0), s.getString(1), s.getLong(2), s.getString(3), s.getString(4));
	}

	static JSONValue toJson(Album a)
	{
		return JSONValue([
			"id": JSONValue(a.id),
			"name": JSONValue(a.name),
			"photos": JSONValue(a.photos),
			"manifest": a.manifest is null ? JSONValue(null) : JSONValue(a.manifest),
			"remote": JSONValue(a.originPeer !is null),
			"originPeer": a.originPeer is null ? JSONValue(null) : JSONValue(a.originPeer),
		]);
	}
}

unittest
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	db.exec("INSERT INTO photos (id, hash, taken_ts, taken_at) VALUES (1, 'a', 0, ''), (2, 'b', 0, '')");
	auto albums = new AlbumRepo(db);
	immutable id = albums.create("trip", [1]);
	albums.addPhotos(id, [2, 1]);
	assert(albums.get(id).photos == 2);
	albums.setManifest(id, "m");
	assert(albums.list()[0].manifest == "m");
	bool threw;
	try
		albums.get(999);
	catch (ApiError e)
		threw = true;
	assert(threw);
}
