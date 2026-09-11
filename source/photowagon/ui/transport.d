// Bridge — what `Library` needs from whatever carries the line protocol.
//
// Two implementations: `CoreBridge` (the core thread in this process, desktop)
// and `TcpBridge` (a core on another machine, the mobile app). `Library` never
// knows which one it has. Callbacks always run on the Qt thread.
module photowagon.ui.transport;

import std.json;

alias ResultCb = void delegate(JSONValue result, JSONValue error);
alias EventCb  = void delegate(string event, JSONValue data);

abstract class Bridge
{
    EventCb onEvent;                     /// unsolicited {"event":..,"data":..}
    void delegate(bool up) onConnected;  /// link state changes

    /// Starts connecting. Call after the application object exists.
    abstract void start();
    abstract bool connected() const;
    /// Sends a request; `cb` runs once with either a result or an error object.
    abstract void request(string method, JSONValue params, ResultCb cb);

    /// Convenience for parameterless calls.
    final void request(string method, ResultCb cb)
    {
        request(method, JSONValue(null), cb);
    }

    /// A request whose params were serialised elsewhere (a 15 MB base64 photo built on a
    /// worker thread must not be re-encoded on the Qt thread). Transports that carry
    /// lines send it as is; the in-process bridge parses it back.
    void requestRaw(string method, string paramsJson, ResultCb cb)
    {
        request(method, parseJSON(paramsJson), cb);
    }

    /// Drops the current connection and dials again (a request timed out). No-op by default.
    void reconnect() {}

    /// Where the other end is, for transports that have a choice. No-op by default.
    void setEndpoint(string host, ushort port) {}
    string endpoint() const { return ""; }

    /// True when photos live on another machine and must travel as bytes.
    bool remote() const { return false; }

    // ---- shared plumbing for line-based transports ----------------------------------

    protected ResultCb[long] pending;
    protected long nextId = 1;

    /// Builds the request line and remembers the callback; the subclass sends it.
    protected string enqueue(string method, JSONValue params, ResultCb cb)
    {
        JSONValue msg = JSONValue.emptyObject;
        immutable id = nextId++;
        msg["id"] = id;
        msg["method"] = method;
        if (params.type != JSONType.null_)
            msg["params"] = params;
        pending[id] = cb;
        return msg.toString() ~ "\n";
    }

    /// Same as `enqueue`, with the params already serialised.
    protected string enqueueRaw(string method, string paramsJson, ResultCb cb)
    {
        import std.conv : to;

        immutable id = nextId++;
        pending[id] = cb;
        return `{"id":` ~ id.to!string ~ `,"method":` ~ JSONValue(method).toString() ~ `,"params":`
            ~ (paramsJson.length ? paramsJson : "null") ~ "}\n";
    }

    /// Routes one inbound line to its callback or to `onEvent`.
    protected void deliverLine(string line)
    {
        import std.string : strip;
        import std.stdio : stderr;

        line = line.strip();
        if (line.length == 0)
            return;
        JSONValue obj;
        try
            obj = parseJSON(line);
        catch (JSONException e)
        {
            stderr.writeln("bridge: bad line: ", line.length > 200 ? line[0 .. 200] ~ "…" : line);
            return;
        }
        if (obj.type != JSONType.object)
            return;
        if (auto ev = "event" in obj)
        {
            if (onEvent)
                onEvent(ev.str, "data" in obj ? obj["data"] : JSONValue(null));
            return;
        }
        if (auto idp = "id" in obj)
        {
            if (idp.type != JSONType.integer)
                return;
            immutable id = idp.integer;
            if (auto cb = id in pending)
            {
                auto f = *cb;
                pending.remove(id);
                f("result" in obj ? obj["result"] : JSONValue(null),
                  "error" in obj ? obj["error"] : JSONValue(null));
            }
        }
    }

    /// Answers every outstanding request with an error (link lost).
    protected void failAll(string why)
    {
        auto cbs = pending;
        pending = null;
        JSONValue e = JSONValue.emptyObject;
        e["code"] = "disconnected";
        e["message"] = why;
        foreach (id, cb; cbs)
            cb(JSONValue(null), e);
    }
}
