/// The thinnest SQLite wrapper that keeps ownership honest: a `Database` you
/// close, a `Statement` struct that finalises itself when it goes out of scope.
/// Used from the main fiber thread only.
module photowagon.core.db.sqlite;

import std.exception : enforce;
import std.string : fromStringz, toStringz;

extern (C) nothrow @nogc
{
	struct sqlite3;
	struct sqlite3_stmt;

	int sqlite3_open_v2(const char* filename, sqlite3** db, int flags, const char* vfs);
	int sqlite3_close_v2(sqlite3* db);
	int sqlite3_exec(sqlite3* db, const char* sql, void* cb, void* arg, char** errmsg);
	void sqlite3_free(void* p);
	const(char)* sqlite3_errmsg(sqlite3* db);
	long sqlite3_last_insert_rowid(sqlite3* db);
	int sqlite3_changes(sqlite3* db);

	int sqlite3_prepare_v2(sqlite3* db, const char* sql, int nbytes, sqlite3_stmt** stmt, const(char)** tail);
	int sqlite3_finalize(sqlite3_stmt* stmt);
	int sqlite3_reset(sqlite3_stmt* stmt);
	int sqlite3_step(sqlite3_stmt* stmt);
	int sqlite3_bind_int64(sqlite3_stmt* stmt, int idx, long v);
	int sqlite3_bind_double(sqlite3_stmt* stmt, int idx, double v);
	int sqlite3_bind_text(sqlite3_stmt* stmt, int idx, const char* v, int n, void* destructor);
	int sqlite3_bind_null(sqlite3_stmt* stmt, int idx);
	int sqlite3_bind_blob(sqlite3_stmt* stmt, int idx, const void* v, int n, void* destructor);
	const(void)* sqlite3_column_blob(sqlite3_stmt* stmt, int col);
	int sqlite3_column_type(sqlite3_stmt* stmt, int col);
	long sqlite3_column_int64(sqlite3_stmt* stmt, int col);
	double sqlite3_column_double(sqlite3_stmt* stmt, int col);
	const(ubyte)* sqlite3_column_text(sqlite3_stmt* stmt, int col);
	int sqlite3_column_bytes(sqlite3_stmt* stmt, int col);
	int sqlite3_auto_extension(void* xEntryPoint);
	/// sqlite-vec (csrc/sqlite-vec.c, compiled in): vec0 virtual tables with KNN search
	int sqlite3_vec_init(sqlite3* db, char** pzErrMsg, const(void)* pApi);
}

private shared bool vecRegistered;

/// Registers sqlite-vec for every connection opened afterwards. Idempotent.
private void registerVec() nothrow @nogc
{
	import core.atomic : atomicLoad, atomicStore;

	if (atomicLoad(vecRegistered))
		return;
	sqlite3_auto_extension(cast(void*) &sqlite3_vec_init);
	atomicStore(vecRegistered, true);
}

private enum SQLITE_OK = 0;
private enum SQLITE_ROW = 100;
private enum SQLITE_DONE = 101;
private enum SQLITE_OPEN_READWRITE = 0x2;
private enum SQLITE_OPEN_CREATE = 0x4;
private enum SQLITE_NULL = 5;
private enum void* SQLITE_TRANSIENT = cast(void*)-1;

class SqliteException : Exception
{
	this(string msg, string file = __FILE__, size_t line = __LINE__)
	{
		super(msg, file, line);
	}
}

final class Database
{
	private sqlite3* db;

	this(string path)
	{
		registerVec();
		immutable rc = sqlite3_open_v2(path.toStringz, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, null);
		if (rc != SQLITE_OK)
		{
			immutable msg = db ? sqlite3_errmsg(db).fromStringz.idup : "cannot open";
			sqlite3_close_v2(db);
			db = null;
			throw new SqliteException("sqlite open " ~ path ~ ": " ~ msg);
		}
		exec("PRAGMA journal_mode = WAL");
		exec("PRAGMA synchronous = NORMAL");
		exec("PRAGMA foreign_keys = ON");
	}

	void close() nothrow
	{
		if (db is null)
			return;
		sqlite3_close_v2(db);
		db = null;
	}

	void exec(string sql)
	{
		char* err;
		immutable rc = sqlite3_exec(db, sql.toStringz, null, null, &err);
		if (rc != SQLITE_OK)
		{
			immutable msg = err ? err.fromStringz.idup : "sqlite error";
			sqlite3_free(err);
			throw new SqliteException(msg ~ "\n  in: " ~ sql);
		}
	}

	Statement prepare(string sql)
	{
		sqlite3_stmt* stmt;
		immutable rc = sqlite3_prepare_v2(db, sql.ptr, cast(int) sql.length, &stmt, null);
		if (rc != SQLITE_OK)
			throw new SqliteException(sqlite3_errmsg(db).fromStringz.idup ~ "\n  in: " ~ sql);
		return Statement(stmt, this);
	}

	long lastInsertId()
	{
		return sqlite3_last_insert_rowid(db);
	}

	int changes()
	{
		return sqlite3_changes(db);
	}

	private int txDepth;

	/// Runs `body_` inside a transaction; rolls back on throw. Nested calls
	/// join the outer transaction (SQLite has no nested BEGIN).
	T transaction(T)(scope T delegate() body_)
	{
		if (txDepth > 0)
		{
			txDepth++;
			scope (exit)
				txDepth--;
			return body_();
		}
		exec("BEGIN");
		txDepth = 1;
		scope (exit)
			txDepth = 0;
		try
		{
			static if (is(T == void))
			{
				body_();
				exec("COMMIT");
			}
			else
			{
				auto r = body_();
				exec("COMMIT");
				return r;
			}
		}
		catch (Exception e)
		{
			try
				exec("ROLLBACK");
			catch (Exception)
			{
			}
			throw e;
		}
	}

	private string error()
	{
		return sqlite3_errmsg(db).fromStringz.idup;
	}
}

/// A prepared statement. Bind with `bind(1, x)`, iterate with `while (s.step())`.
struct Statement
{
	private sqlite3_stmt* stmt;
	private Database owner;

	@disable this(this);

	~this()
	{
		if (stmt)
			sqlite3_finalize(stmt);
		stmt = null;
	}

	ref Statement bind(int idx, long v) return
	{
		check(sqlite3_bind_int64(stmt, idx, v));
		return this;
	}

	ref Statement bind(int idx, int v) return
	{
		return bind(idx, cast(long) v);
	}

	ref Statement bind(int idx, double v) return
	{
		check(sqlite3_bind_double(stmt, idx, v));
		return this;
	}

	ref Statement bind(int idx, string v) return
	{
		if (v is null)
			check(sqlite3_bind_null(stmt, idx));
		else
			check(sqlite3_bind_text(stmt, idx, v.ptr, cast(int) v.length, SQLITE_TRANSIENT));
		return this;
	}

	ref Statement bind(int idx, const(ubyte)[] v) return
	{
		check(sqlite3_bind_blob(stmt, idx, v.ptr, cast(int) v.length, SQLITE_TRANSIENT));
		return this;
	}

	ref Statement bindNull(int idx) return
	{
		check(sqlite3_bind_null(stmt, idx));
		return this;
	}

	/// True while there is a row to read.
	bool step()
	{
		immutable rc = sqlite3_step(stmt);
		if (rc == SQLITE_ROW)
			return true;
		if (rc == SQLITE_DONE)
			return false;
		throw new SqliteException(owner.error());
	}

	/// Runs a statement that yields no rows.
	void run()
	{
		while (step())
		{
		}
	}

	void reset()
	{
		sqlite3_reset(stmt);
	}

	bool isNull(int col)
	{
		return sqlite3_column_type(stmt, col) == SQLITE_NULL;
	}

	long getLong(int col)
	{
		return sqlite3_column_int64(stmt, col);
	}

	int getInt(int col)
	{
		return cast(int) sqlite3_column_int64(stmt, col);
	}

	double getDouble(int col)
	{
		return sqlite3_column_double(stmt, col);
	}

	string getString(int col)
	{
		auto p = sqlite3_column_text(stmt, col);
		if (p is null)
			return null;
		immutable n = sqlite3_column_bytes(stmt, col);
		return (cast(const(char)*) p)[0 .. n].idup;
	}

	/// A copy of a BLOB column (empty for NULL).
	ubyte[] getBlob(int col)
	{
		auto p = sqlite3_column_blob(stmt, col);
		immutable n = sqlite3_column_bytes(stmt, col);
		if (p is null || n <= 0)
			return null;
		return (cast(const(ubyte)*) p)[0 .. n].dup;
	}

	private void check(int rc)
	{
		if (rc != SQLITE_OK)
			throw new SqliteException(owner.error());
	}
}

unittest
{
	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	db.exec("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT, x REAL)");
	{
		auto ins = db.prepare("INSERT INTO t (name, x) VALUES (?, ?)");
		ins.bind(1, "a").bind(2, 1.5).run();
		ins.reset();
		ins.bind(1, cast(string) null).bind(2, 2.0).run();
	}
	assert(db.lastInsertId() == 2);
	auto q = db.prepare("SELECT id, name, x FROM t ORDER BY id");
	assert(q.step());
	assert(q.getLong(0) == 1 && q.getString(1) == "a" && q.getDouble(2) == 1.5);
	assert(q.step());
	assert(q.isNull(1));
	assert(!q.step());
	bool rolledBack;
	try
		db.transaction!void({ db.exec("INSERT INTO t (name) VALUES ('b')"); throw new Exception("x"); });
	catch (Exception)
		rolledBack = true;
	assert(rolledBack);
	auto c = db.prepare("SELECT count(*) FROM t");
	c.step();
	assert(c.getLong(0) == 2);
	// nested: the inner one joins the outer, one COMMIT at the end
	db.transaction!void({
		db.exec("INSERT INTO t (name) VALUES ('c')");
		db.transaction!void({ db.exec("INSERT INTO t (name) VALUES ('d')"); });
	});
	auto c2 = db.prepare("SELECT count(*) FROM t");
	c2.step();
	assert(c2.getLong(0) == 4);
}

unittest
{
	// sqlite-vec is in: a vec0 table answers a nearest-neighbour query
	auto db = new Database(":memory:");
	scope (exit)
		db.close();
	auto v = db.prepare("SELECT vec_version()");
	assert(v.step() && v.getString(0).length);
	db.exec("CREATE VIRTUAL TABLE t USING vec0(id INTEGER PRIMARY KEY, e float[4] distance_metric=cosine)");
	float[4] a = [1, 0, 0, 0], b = [0, 1, 0, 0], q = [0.9, 0.1, 0, 0];
	auto ins = db.prepare("INSERT INTO t (id, e) VALUES (?, ?)");
	ins.bind(1, 1L).bind(2, cast(const(ubyte)[]) a[]);
	ins.run();
	ins.reset();
	ins.bind(1, 2L).bind(2, cast(const(ubyte)[]) b[]);
	ins.run();
	auto knn = db.prepare("SELECT id, distance FROM t WHERE e MATCH ? AND k = 2 ORDER BY distance");
	knn.bind(1, cast(const(ubyte)[]) q[]);
	assert(knn.step() && knn.getLong(0) == 1 && knn.getDouble(1) < 0.02);
	assert(knn.step() && knn.getLong(0) == 2);
}
