/// Library roots: the folders the user asked us to index.
module photowagon.core.library.roots;

import std.json;

import photowagon.core.db.sqlite : Database;
import photowagon.core.ipc.protocol : ApiError;

struct Root
{
	long id;
	string path;
	long photos;
}

final class RootRepo
{
	private Database db;

	this(Database db)
	{
		this.db = db;
	}

	/// Idempotent: adding a known path returns its id.
	long add(string path)
	{
		import std.datetime : Clock;

		{
			auto s = db.prepare("SELECT id FROM roots WHERE path = ?");
			s.bind(1, path);
			if (s.step())
				return s.getLong(0);
		}
		auto i = db.prepare("INSERT INTO roots (path, added_at) VALUES (?, ?)");
		i.bind(1, path).bind(2, Clock.currTime.toUnixTime);
		i.run();
		return db.lastInsertId();
	}

	Root get(long id)
	{
		auto s = db.prepare("SELECT r.id, r.path, (SELECT count(*) FROM photos WHERE root_id = r.id) FROM roots r WHERE r.id = ?");
		s.bind(1, id);
		if (!s.step())
			throw new ApiError("not_found", "no such root");
		return Root(s.getLong(0), s.getString(1), s.getLong(2));
	}

	Root[] list()
	{
		auto s = db.prepare("SELECT r.id, r.path, (SELECT count(*) FROM photos WHERE root_id = r.id) FROM roots r ORDER BY r.id");
		Root[] out_;
		while (s.step())
			out_ ~= Root(s.getLong(0), s.getString(1), s.getLong(2));
		return out_;
	}

	/// Photos under the root go with it (ON DELETE CASCADE).
	void remove(long id)
	{
		auto s = db.prepare("DELETE FROM roots WHERE id = ?");
		s.bind(1, id);
		s.run();
		if (db.changes() == 0)
			throw new ApiError("not_found", "no such root");
	}

	static JSONValue toJson(Root r)
	{
		return JSONValue(["id": JSONValue(r.id), "path": JSONValue(r.path), "photos": JSONValue(r.photos)]);
	}
}

unittest
{
	import photowagon.core.db.schema : migrate;

	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	migrate(db);
	auto roots = new RootRepo(db);
	immutable a = roots.add("/x");
	assert(roots.add("/x") == a);
	assert(roots.list().length == 1);
	roots.remove(a);
	assert(roots.list().length == 0);
}
