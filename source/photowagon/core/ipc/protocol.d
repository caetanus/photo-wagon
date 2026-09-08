/// The vocabulary of docs/ipc.md: methods, errors, and JSON parameter access.
module photowagon.core.ipc.protocol;

import std.json;

/// A method is a function of params → result. It may block on fibers.
alias Method = JSONValue delegate(JSONValue params);

/// Thrown by a method to answer `{"error": {"code", "message"}}`.
class ApiError : Exception
{
	string code;

	this(string code, string message, string file = __FILE__, size_t line = __LINE__)
	{
		super(message, file, line);
		this.code = code;
	}
}

/// Name → method table. Services register into it at startup.
final class Registry
{
	private Method[string] methods;

	void add(string name, Method m)
	{
		assert(name !in methods, "duplicate method " ~ name);
		methods[name] = m;
	}

	Method find(string name)
	{
		if (auto m = name in methods)
			return *m;
		throw new ApiError("unknown_method", "no such method: " ~ name);
	}

	string[] names() const
	{
		return methods.keys;
	}
}

// ---- parameter access ------------------------------------------------------

private JSONValue* field(ref JSONValue params, string key)
{
	if (params.type != JSONType.object)
		return null;
	return key in params.object;
}

string getString(JSONValue params, string key, string def = null)
{
	auto f = field(params, key);
	if (f is null || f.type == JSONType.null_)
		return def;
	if (f.type != JSONType.string)
		throw new ApiError("bad_params", key ~ " must be a string");
	return f.str;
}

string requireString(JSONValue params, string key)
{
	auto v = getString(params, key);
	if (v is null)
		throw new ApiError("bad_params", "missing " ~ key);
	return v;
}

long getLong(JSONValue params, string key, long def = 0)
{
	auto f = field(params, key);
	if (f is null || f.type == JSONType.null_)
		return def;
	switch (f.type)
	{
	case JSONType.integer:
		return f.integer;
	case JSONType.uinteger:
		return cast(long) f.uinteger;
	case JSONType.float_:
		return cast(long) f.floating;
	default:
		throw new ApiError("bad_params", key ~ " must be a number");
	}
}

long requireLong(JSONValue params, string key)
{
	if (field(params, key) is null)
		throw new ApiError("bad_params", "missing " ~ key);
	return getLong(params, key);
}

long[] getLongArray(JSONValue params, string key)
{
	auto f = field(params, key);
	if (f is null || f.type == JSONType.null_)
		return null;
	if (f.type != JSONType.array)
		throw new ApiError("bad_params", key ~ " must be an array");
	long[] out_;
	foreach (ref e; f.array)
	{
		if (e.type == JSONType.integer)
			out_ ~= e.integer;
		else if (e.type == JSONType.uinteger)
			out_ ~= cast(long) e.uinteger;
		else
			throw new ApiError("bad_params", key ~ " must hold integers");
	}
	return out_;
}

// ---- result construction ---------------------------------------------------

JSONValue obj()
{
	JSONValue v;
	v.object = null; // empty object, not null
	return v;
}

JSONValue nullable(T)(T value, bool present)
{
	return present ? JSONValue(value) : JSONValue(null);
}

JSONValue emptyArray()
{
	JSONValue v;
	v.array = [];
	return v;
}

unittest
{
	auto p = parseJSON(`{"a": 3, "s": "x", "ids": [1, 2]}`);
	assert(getLong(p, "a") == 3);
	assert(getLong(p, "zzz", 9) == 9);
	assert(getString(p, "s") == "x");
	assert(getLongArray(p, "ids") == [1, 2]);
	bool threw;
	try
		requireString(p, "missing");
	catch (ApiError e)
		threw = e.code == "bad_params";
	assert(threw);
	assert(obj().toString() == "{}");
}
