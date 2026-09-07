module app;

import vibe.http.server : HTTPServerSettings, listenHTTP;
import vibe.http.router : URLRouter;
import vibe.http.websockets : handleWebSockets, WebSocket;
import vibe.http.common : HTTPMethod;
import vibe.http.status : HTTPStatus;
import vibe.core.core : runApplication, sleep;

import core.time : msecs;
import std.conv : to;
import std.stdio : stdout;

import log;
import indexer;
import faces;

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

void main(string[] args)
{
    indexer.ensureVipsInit();
    indexer.initFaceModels();

    auto router = new URLRouter;

    // WebSocket — push events only (face_update, scan progress)
    router.get("/ws", handleWebSockets(&onWebSocket));

    // REST API — all request/response operations
    router.get("/api/index", &handleIndex);
    router.get("/api/index_page", &handleIndexPage);
    router.get("/api/dates", &handleDates);
    router.post("/api/face_scan", &handleFaceScan);
    router.get("/api/face_list", &handleFaceList);
    router.get("/api/people_list", &handlePeopleList);
    router.post("/api/face_set_name", &handleFaceSetName);
    router.post("/api/fingerprint_set_name", &handleFingerprintSetName);
    router.get("/api/face_db_status", &handleFaceDbStatus);
    router.get("/api/face_state", &handleFaceState);
    router.get("/api/unknown_count", &handleUnknownCount);
    router.get("/api/faces_for_photo", &handleFacesForPhoto);

    // Try a range of ports so we don't collide with a stale instance.
    ushort boundPort = 0;
    foreach (ushort port; [
        47923, 47924, 47925, 47926, 47927, 47928, 47929, 47930
    ])
    {
        try
        {
            auto settings = new HTTPServerSettings;
            settings.port = port;
            settings.bindAddresses = ["127.0.0.1"];
            listenHTTP(settings, router);
            boundPort = port;
            break;
        }
        catch (Exception)
        {
            log.warn("port %s in use, trying next…", port);
        }
    }

    if (boundPort == 0)
    {
        log.fatal("could not bind any port");
        return;
    }

    log.info("listening on http://127.0.0.1:%s", boundPort);
    stdout.writefln("READY:%s", boundPort);
    stdout.flush();

    runApplication();
}

// ---------------------------------------------------------------------------
// REST handlers
// ---------------------------------------------------------------------------

import vibe.http.server : HTTPServerRequest, HTTPServerResponse;

void handleIndex(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    auto root = req.params.get("rootPath", "");
    if (root.length == 0 && "rootPath" in req.query)
        root = req.query["rootPath"];
    if (root.length == 0)
    {
        res.statusCode = HTTPStatus.badRequest;
        res.writeBody(`{"ok":false,"error":"missing rootPath"}`, "application/json");
        return;
    }
    auto data = indexer.buildIndexJson(root);
    res.writeBody(`{"ok":true,"data":` ~ data ~ `}`, "application/json");
}

void handleIndexPage(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    auto root = req.params.get("rootPath", "");
    if (root.length == 0 && "rootPath" in req.query)
        root = req.query["rootPath"];
    log.dbg("index_page request rootPath='%s'", root);
    if (root.length == 0)
    {
        res.statusCode = HTTPStatus.badRequest;
        res.writeBody(`{"ok":false,"error":"missing rootPath"}`, "application/json");
        return;
    }
    int offset = 0, limit = 200;
    try
    {
        if ("offset" in req.query)
            offset = req.query["offset"].to!int;
    }
    catch (Exception)
    {
    }
    try
    {
        if ("limit" in req.query)
            limit = req.query["limit"].to!int;
    }
    catch (Exception)
    {
    }
    auto data = indexer.buildIndexPageJson(root, offset, limit);
    res.writeBody(`{"ok":true,"data":` ~ data ~ `}`, "application/json");
}

void handleDates(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    auto root = req.params.get("rootPath", "");
    if (root.length == 0 && "rootPath" in req.query)
        root = req.query["rootPath"];
    if (root.length == 0)
    {
        res.statusCode = HTTPStatus.badRequest;
        res.writeBody(`{"ok":false,"error":"missing rootPath"}`, "application/json");
        return;
    }
    auto data = indexer.buildDatesJson(root);
    res.writeBody(`{"ok":true,"data":` ~ data ~ `}`, "application/json");
}

void handleFaceScan(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    string root;
    try
    {
        auto j = req.json;
        root = j["rootPath"].get!string;
    }
    catch (Exception)
    {
        res.statusCode = HTTPStatus.badRequest;
        res.writeBody(`{"ok":false,"error":"missing rootPath"}`, "application/json");
        return;
    }
    faces.startFaceScan(root);
    res.writeBody(`{"ok":true}`, "application/json");
}

void handleFaceList(scope HTTPServerRequest, scope HTTPServerResponse res)
{
    auto data = indexer.unnamedFacesJson();
    res.writeBody(`{"ok":true,"data":` ~ data ~ `}`, "application/json");
}

void handlePeopleList(scope HTTPServerRequest, scope HTTPServerResponse res)
{
    auto data = indexer.peopleFingerprintsJson();
    res.writeBody(`{"ok":true,"data":` ~ data ~ `}`, "application/json");
}

void handleFaceSetName(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    try
    {
        auto j = req.json;
        auto faceId = j["faceId"].get!long;
        auto name = j["name"].get!string;
        auto ok = indexer.setFaceNameInDb(faceId, name);
        res.writeBody(`{"ok":` ~ (ok ? "true" : "false") ~ `}`, "application/json");
    }
    catch (Exception e)
    {
        res.statusCode = HTTPStatus.badRequest;
        res.writeBody(`{"ok":false,"error":"` ~ indexer.jsonEscape(e.msg) ~ `"}`, "application/json");
    }
}

void handleFingerprintSetName(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    try
    {
        auto j = req.json;
        auto fpId = j["fingerprintId"].get!long;
        auto name = j["name"].get!string;
        auto ok = indexer.setFingerprintNameInDb(fpId, name);
        res.writeBody(`{"ok":` ~ (ok ? "true" : "false") ~ `}`, "application/json");
    }
    catch (Exception e)
    {
        res.statusCode = HTTPStatus.badRequest;
        res.writeBody(`{"ok":false,"error":"` ~ indexer.jsonEscape(e.msg) ~ `"}`, "application/json");
    }
}

void handleFaceDbStatus(scope HTTPServerRequest, scope HTTPServerResponse res)
{
    auto data = indexer.faceDbStatusJson();
    res.writeBody(`{"ok":true,"data":` ~ data ~ `}`, "application/json");
}

void handleFaceState(scope HTTPServerRequest, scope HTTPServerResponse res)
{
    auto data = faces.fullStateJson();
    res.writeBody(`{"ok":true,"data":` ~ data ~ `}`, "application/json");
}

void handleUnknownCount(scope HTTPServerRequest, scope HTTPServerResponse res)
{
    auto count = faces.currentUnknownCount();
    res.writeBody(`{"ok":true,"count":` ~ to!string(count) ~ `}`, "application/json");
}

void handleFacesForPhoto(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    import std.uri : decodeComponent;

    auto sourcePath = req.params.get("path", "");
    if (sourcePath.length == 0 && "path" in req.query)
        sourcePath = req.query["path"];
    // URL-decode the path
    try
        sourcePath = decodeComponent(sourcePath);
    catch (Exception)
    {
    }
    if (sourcePath.length == 0)
    {
        res.statusCode = HTTPStatus.badRequest;
        res.writeBody(`{"ok":false,"error":"missing path"}`, "application/json");
        return;
    }
    auto data = indexer.facesForPhotoJson(sourcePath);
    res.writeBody(`{"ok":true,"data":` ~ data ~ `}`, "application/json");
}

// ---------------------------------------------------------------------------
// WebSocket handler — push events only
// ---------------------------------------------------------------------------

void onWebSocket(scope WebSocket ws)
{
    log.info("event client connected");

    while (ws.connected)
    {
        auto events = faces.drainFaceEvents();
        foreach (ev; events)
        {
            if (ws.connected)
                ws.send(ev);
        }
        sleep(50.msecs);
    }

    log.info("event client disconnected");
}
