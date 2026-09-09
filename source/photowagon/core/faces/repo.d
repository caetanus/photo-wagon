/// The `faces` and `persons` tables.
module photowagon.core.faces.repo;

import std.json;

import photowagon.core.db.sqlite : Database, Statement;
import photowagon.core.ipc.protocol : ApiError;

struct FaceRow
{
	long id;
	long photoId;
	float x, y, w, h;
	float score;
	string thumbHash;
	long personId; // 0 = none
	string personName;
}

struct Person
{
	long id;
	string name; // null = not named yet
	long faces;
	string coverThumb; // thumb hash of the best face, or null
}

final class FaceRepo
{
	private Database db;

	this(Database db)
	{
		this.db = db;
	}

	// ---- scanning state ---------------------------------------------------------------

	/// Local photos not yet scanned, oldest first.
	long[] unscannedPhotos(long limit = 100_000)
	{
		auto s = db.prepare("SELECT id FROM photos WHERE faces_scanned = 0 AND path IS NOT NULL ORDER BY id LIMIT ?");
		s.bind(1, limit);
		long[] out_;
		while (s.step())
			out_ ~= s.getLong(0);
		return out_;
	}

	long[2] scanCounts()
	{
		auto s = db.prepare("SELECT sum(faces_scanned), count(*) FROM photos WHERE path IS NOT NULL");
		s.step();
		return [s.isNull(0) ? 0 : s.getLong(0), s.getLong(1)];
	}

	void markScanned(long photoId)
	{
		auto s = db.prepare("UPDATE photos SET faces_scanned = 1 WHERE id = ?");
		s.bind(1, photoId);
		s.run();
	}

	// ---- faces ----------------------------------------------------------------------------

	long insertFace(long photoId, float x, float y, float w, float h, float score, const(float)[] embedding,
			string thumbHash, long personId)
	{
		auto s = db.prepare(`INSERT INTO faces (photo_id, x, y, w, h, score, embedding, thumb_hash, person_id)
			VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)`);
		s.bind(1, photoId).bind(2, cast(double) x).bind(3, cast(double) y).bind(4, cast(double) w)
			.bind(5, cast(double) h).bind(6, cast(double) score).bind(7, cast(const(ubyte)[]) embedding)
			.bind(8, thumbHash);
		if (personId)
			s.bind(9, personId);
		else
			s.bindNull(9);
		s.run();
		return db.lastInsertId();
	}

	/// Every stored embedding with its person, for rebuilding the cluster index.
	void eachEmbedding(scope void delegate(long faceId, long personId, const(float)[] emb) dg)
	{
		auto s = db.prepare("SELECT id, person_id, embedding FROM faces WHERE person_id IS NOT NULL");
		while (s.step())
		{
			auto blob = s.getBlob(2);
			if (blob.length != 128 * float.sizeof)
				continue;
			dg(s.getLong(0), s.getLong(1), cast(const(float)[]) blob);
		}
	}

	FaceRow[] facesOfPhoto(long photoId)
	{
		auto s = db.prepare(`SELECT f.id, f.photo_id, f.x, f.y, f.w, f.h, f.score, f.thumb_hash, f.person_id, p.name
			FROM faces f LEFT JOIN persons p ON p.id = f.person_id WHERE f.photo_id = ? ORDER BY f.x`);
		s.bind(1, photoId);
		FaceRow[] out_;
		while (s.step())
			out_ ~= readFace(s);
		return out_;
	}

	FaceRow face(long id)
	{
		auto s = db.prepare(`SELECT f.id, f.photo_id, f.x, f.y, f.w, f.h, f.score, f.thumb_hash, f.person_id, p.name
			FROM faces f LEFT JOIN persons p ON p.id = f.person_id WHERE f.id = ?`);
		s.bind(1, id);
		if (!s.step())
			throw new ApiError("not_found", "no such face");
		return readFace(s);
	}

	private static FaceRow readFace(ref Statement s)
	{
		FaceRow f;
		f.id = s.getLong(0);
		f.photoId = s.getLong(1);
		f.x = cast(float) s.getDouble(2);
		f.y = cast(float) s.getDouble(3);
		f.w = cast(float) s.getDouble(4);
		f.h = cast(float) s.getDouble(5);
		f.score = cast(float) s.getDouble(6);
		f.thumbHash = s.getString(7);
		f.personId = s.isNull(8) ? 0 : s.getLong(8);
		f.personName = s.getString(9);
		return f;
	}

	void setFacePerson(long faceId, long personId)
	{
		auto s = db.prepare("UPDATE faces SET person_id = ? WHERE id = ?");
		if (personId)
			s.bind(1, personId);
		else
			s.bindNull(1);
		s.bind(2, faceId);
		s.run();
		if (db.changes() == 0)
			throw new ApiError("not_found", "no such face");
	}

	// ---- persons ----------------------------------------------------------------------------

	long createPerson(string name)
	{
		import std.datetime : Clock;

		auto s = db.prepare("INSERT INTO persons (name, created_at) VALUES (?, ?)");
		s.bind(1, name.length ? name : null).bind(2, Clock.currTime.toUnixTime);
		s.run();
		return db.lastInsertId();
	}

	/// A person by exact name, or 0.
	long personByName(string name)
	{
		auto s = db.prepare("SELECT id FROM persons WHERE name = ? COLLATE NOCASE");
		s.bind(1, name);
		return s.step() ? s.getLong(0) : 0;
	}

	Person person(long id)
	{
		auto s = db.prepare(personSelect ~ " WHERE p.id = ? GROUP BY p.id");
		s.bind(1, id);
		if (!s.step())
			throw new ApiError("not_found", "no such person");
		return readPerson(s);
	}

	/// People with at least one face, most faces first; named ones before unnamed on ties.
	Person[] people()
	{
		auto s = db.prepare(personSelect ~ " GROUP BY p.id HAVING count(f.id) > 0 ORDER BY count(f.id) DESC, p.name IS NULL, p.name");
		Person[] out_;
		while (s.step())
			out_ ~= readPerson(s);
		return out_;
	}

	private enum personSelect = `SELECT p.id, p.name, count(f.id),
		(SELECT thumb_hash FROM faces WHERE person_id = p.id AND thumb_hash IS NOT NULL ORDER BY score DESC LIMIT 1)
		FROM persons p LEFT JOIN faces f ON f.person_id = p.id`;

	private static Person readPerson(ref Statement s)
	{
		return Person(s.getLong(0), s.getString(1), s.getLong(2), s.getString(3));
	}

	void renamePerson(long id, string name)
	{
		auto s = db.prepare("UPDATE persons SET name = ? WHERE id = ?");
		s.bind(1, name.length ? name : null).bind(2, id);
		s.run();
		if (db.changes() == 0)
			throw new ApiError("not_found", "no such person");
	}

	/// Moves every face of `from` into `into` and deletes `from`.
	void mergePersons(long from, long into)
	{
		if (from == into)
			return;
		person(into);
		db.transaction!void({
			auto m = db.prepare("UPDATE faces SET person_id = ? WHERE person_id = ?");
			m.bind(1, into).bind(2, from);
			m.run();
			auto d = db.prepare("DELETE FROM persons WHERE id = ?");
			d.bind(1, from);
			d.run();
		});
	}

	/// Drops persons that lost their last face (after moves).
	void pruneEmptyPersons()
	{
		db.exec("DELETE FROM persons WHERE id NOT IN (SELECT DISTINCT person_id FROM faces WHERE person_id IS NOT NULL)");
	}

	static JSONValue toJson(Person p, string coverUrl)
	{
		return JSONValue([
			"id": JSONValue(p.id),
			"name": p.name is null ? JSONValue(null) : JSONValue(p.name),
			"faces": JSONValue(p.faces),
			"coverUrl": coverUrl is null ? JSONValue(null) : JSONValue(coverUrl),
		]);
	}

	static JSONValue toJson(ref const FaceRow f, string thumbUrl)
	{
		return JSONValue([
			"id": JSONValue(f.id),
			"photoId": JSONValue(f.photoId),
			"x": JSONValue(f.x), "y": JSONValue(f.y), "w": JSONValue(f.w), "h": JSONValue(f.h),
			"score": JSONValue(f.score),
			"thumbUrl": thumbUrl is null ? JSONValue(null) : JSONValue(thumbUrl),
			"personId": f.personId ? JSONValue(f.personId) : JSONValue(null),
			"name": f.personName is null ? JSONValue(null) : JSONValue(f.personName),
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
	db.exec("INSERT INTO photos (id, hash, path, taken_ts, taken_at) VALUES (1, 'a', '/a.jpg', 0, ''), (2, 'b', '/b.jpg', 0, '')");
	auto repo = new FaceRepo(db);
	assert(repo.unscannedPhotos() == [1, 2]);
	float[128] e = 0;
	e[3] = 1;
	immutable ana = repo.createPerson("Ana");
	immutable f1 = repo.insertFace(1, 0.1, 0.1, 0.2, 0.2, 0.9, e[], "t1", ana);
	immutable other = repo.createPerson(null);
	immutable f2 = repo.insertFace(2, 0.1, 0.1, 0.2, 0.2, 0.8, e[], "t2", other);
	repo.markScanned(1);
	assert(repo.unscannedPhotos() == [2]);
	assert(repo.scanCounts() == [1, 2]);
	auto ps = repo.people();
	assert(ps.length == 2 && ps[0].name == "Ana" && ps[0].coverThumb == "t1");
	int seen;
	repo.eachEmbedding((long fid, long pid, const(float)[] emb) { seen++; assert(emb[3] == 1); });
	assert(seen == 2);
	repo.mergePersons(other, ana);
	assert(repo.people().length == 1 && repo.people()[0].faces == 2);
	assert(repo.facesOfPhoto(2)[0].personName == "Ana");
	assert(repo.personByName("ana") == ana);
	repo.setFacePerson(f2, 0);
	repo.pruneEmptyPersons();
	assert(repo.people()[0].faces == 1);
	assert(repo.face(f1).thumbHash == "t1");
}
