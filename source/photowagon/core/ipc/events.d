/// Fan-out of unsolicited events to every connected client.
///
/// Services call `emit`; they never see a socket. The IPC server attaches one
/// sink per connection and detaches it when the connection ends.
module photowagon.core.ipc.events;

import std.json;

import vibe.core.log : logDebug;

alias EventSink = void delegate(string line) nothrow;

final class Events
{
	private EventSink[] sinks;
	private int holding;          // hold() depth
	private string[] heldNames;   // change notices (no data) seen while held, in order, once each

	void attach(EventSink s)
	{
		sinks ~= s;
	}

	void detach(EventSink s)
	{
		import std.algorithm : remove, SwapStrategy;

		sinks = sinks.remove!(x => x == s, SwapStrategy.stable);
	}

	/// Coalesce: until the matching release(), a data-less change notice ("library.changed",
	/// "people.changed" …) is sent once at the release instead of once per change — a batch of
	/// a thousand small edits was a thousand listing reloads. Events with data pass through.
	/// Nests; must be released (scope(exit)).
	void hold() nothrow
	{
		holding++;
	}

	/// See hold(). The outermost release sends each held notice once.
	void release() nothrow
	{
		if (holding == 0 || --holding > 0)
			return;
		auto names = heldNames;
		heldNames = null;
		foreach (n; names)
			emit(n, JSONValue.emptyObject);
	}

	void emit(string name, JSONValue data) nothrow
	{
		bool empty;
		try
			empty = data.type == JSONType.object && data.object.length == 0;
		catch (Exception)
		{
		}
		if (holding > 0 && empty)
		{
			foreach (n; heldNames)
				if (n == name)
					return;
			heldNames ~= name;
			return;
		}
		string line;
		try
		{
			JSONValue msg = ["event": JSONValue(name), "data": data];
			line = msg.toString() ~ "\n";
		}
		catch (Exception e)
		{
			return; // a JSON value that cannot be serialised is a programming error upstream
		}
		try
			logDebug("event %s", name);
		catch (Exception)
		{
		}
		// copy: a sink may detach itself while we iterate
		foreach (s; sinks.dup)
			s(line);
	}

	/// Convenience for `{"level", "message"}` log events the UI shows in its status bar.
	void log(string level, string message) nothrow
	{
		try
			emit("log", JSONValue(["level": JSONValue(level), "message": JSONValue(message)]));
		catch (Exception)
		{
		}
	}
}

unittest
{
	auto ev = new Events;
	string[] got;
	EventSink s = (string l) nothrow { got ~= l; };
	ev.attach(s);
	ev.emit("x", JSONValue(1));
	ev.detach(s);
	ev.emit("y", JSONValue(2));
	assert(got.length == 1);
	assert(got[0] == `{"data":1,"event":"x"}` ~ "\n");
}

unittest
{
	auto ev = new Events;
	string[] got;
	ev.attach((string line) nothrow { got ~= line; });
	ev.hold();
	foreach (i; 0 .. 5)
	{
		ev.emit("library.changed", JSONValue.emptyObject);
		ev.emit("people.changed", JSONValue.emptyObject);
	}
	ev.emit("index.progress", JSONValue(["done": JSONValue(1)]));   // data: passes at once
	assert(got.length == 1);
	ev.hold();
	ev.release();                                                    // nested: still held
	assert(got.length == 1);
	ev.release();
	assert(got.length == 3);
	ev.emit("library.changed", JSONValue.emptyObject);
	assert(got.length == 4);
}
