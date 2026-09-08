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

	void attach(EventSink s)
	{
		sinks ~= s;
	}

	void detach(EventSink s)
	{
		import std.algorithm : remove, SwapStrategy;

		sinks = sinks.remove!(x => x == s, SwapStrategy.stable);
	}

	void emit(string name, JSONValue data) nothrow
	{
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
