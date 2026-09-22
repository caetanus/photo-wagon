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

    /// True when this transport can stream raw file bytes on a side channel, so a photo or
    /// video need not be base64'd into a JSON line. `uploadFile` is only called when true.
    bool canPush() const { return false; }

    /// True when this transport can stream a file FROM the computer on a side channel
    /// (`downloadFile`), resumably. The default cannot.
    bool canPull() const { return false; }

    /// Downloads the original of the computer's photo `id` into the local file `dest`,
    /// continuing from whatever `dest.part` already holds; `cb` gets {path, size} or an
    /// error. Only meaningful when `canPull()`; the default refuses.
    /// Thumbnails for `ids` as raw JPEG bytes: `onThumb` once per id that has one, then
    /// `done`. This default is the legacy JSON `library.thumbs` (base64 on the wire), kept
    /// only for transports with no raw byte pipe (the TCP fallback); P2pBridge overrides it
    /// with the binary THUMB op on the piece stream.
    void fetchThumbs(long[] ids, void delegate(long id, const(ubyte)[] jpeg) onThumb, void delegate() done)
    {
        import std.base64 : Base64;
        import std.conv : to;

        JSONValue params = JSONValue.emptyObject;
        JSONValue[] arr;
        foreach (i; ids)
            arr ~= JSONValue(i);
        params["ids"] = JSONValue(arr);
        request("library.thumbs", params, (r, e) {
            if (e.type == JSONType.null_ && "thumbs" in r)
                foreach (key, b64; r["thumbs"].object)
                    try
                        if (onThumb !is null)
                            onThumb(key.to!long, Base64.decode(b64.str));
                    catch (Exception)
                    {
                    }
            if (done !is null)
                done();
        });
    }

    void downloadFile(long id, string dest, ResultCb cb)
    {
        cb(JSONValue(null), JSONValue([
            "code": JSONValue("unsupported"), "message": JSONValue("no pull on this transport")
        ]));
    }

    /// Streams `path`'s raw bytes to the computer under `ticket`, then sends a
    /// `library.import` with `meta` ({name, takenAt, sha256, ticket}); `cb` gets the import
    /// result. Only meaningful when `canPush()`; the default refuses.
    void uploadFile(long ticket, string path, JSONValue meta, ResultCb cb)
    {
        cb(JSONValue(null), JSONValue([
            "code": JSONValue("unsupported"), "message": JSONValue("no push on this transport")
        ]));
    }

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
