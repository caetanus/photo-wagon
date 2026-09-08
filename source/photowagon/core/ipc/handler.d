/// Turns one request line into one response line, on a fiber of its own.
/// Shared by every transport: the in-process link the UI uses and the TCP
/// server a headless instance exposes.
module photowagon.core.ipc.handler;

import std.json;

import vibe.core.log : logWarn;
import vibe.core.task : InterruptException;

import libp2p.util.fibers : FiberGroup;

import photowagon.core.ipc.protocol;

alias LineSink = void delegate(string line) nothrow;

final class RequestHandler
{
	private Registry registry;
	private LineSink send;
	private FiberGroup handlers;

	this(Registry registry, LineSink send)
	{
		this.registry = registry;
		this.send = send;
		handlers = new FiberGroup((Exception e) nothrow {
			try
				logWarn("ipc: handler failed: %s", e.msg);
			catch (Exception)
			{
			}
		});
	}

	/// Parses `line` and answers it, now (malformed) or later (on a fiber).
	void handle(string line)
	{
		import std.string : strip;

		if (line.strip.length == 0)
			return;
		JSONValue msg;
		try
			msg = parseJSON(line);
		catch (JSONException e)
		{
			send(errorLine(JSONValue(null), "bad_json", e.msg));
			return;
		}
		JSONValue id = JSONValue(null);
		if (msg.type == JSONType.object)
			if (auto p = "id" in msg.object)
				id = *p;
		immutable method = getString(msg, "method");
		if (method is null)
		{
			send(errorLine(id, "bad_request", "missing method"));
			return;
		}
		JSONValue params = JSONValue(null);
		if (msg.type == JSONType.object)
			if (auto p = "params" in msg.object)
				params = *p;

		handlers.spawn(() { answer(id, method, params); });
	}

	private void answer(JSONValue id, string method, JSONValue params)
	{
		JSONValue reply;
		try
		{
			auto m = registry.find(method);
			auto result = m(params);
			reply = JSONValue(["id": id, "result": result]);
		}
		catch (ApiError e)
			reply = parseJSON(errorLine(id, e.code, e.msg));
		catch (InterruptException)
			throw new InterruptException;
		catch (Exception e)
		{
			logWarn("ipc: %s failed: %s", method, e.msg);
			reply = parseJSON(errorLine(id, "internal", e.msg));
		}
		send(reply.toString() ~ "\n");
	}

	static string errorLine(JSONValue id, string code, string message)
	{
		JSONValue err = ["code": JSONValue(code), "message": JSONValue(message)];
		return JSONValue(["id": id, "error": err]).toString() ~ "\n";
	}

	/// Interrupts every request still running.
	void close() nothrow
	{
		handlers.stopAll();
	}
}
