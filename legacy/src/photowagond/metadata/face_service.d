module photowagond.metadata.face_service;

import core.stdc.stdlib : malloc;
import core.stdc.string : memcpy;
import core.atomic : atomicLoad, atomicStore, cas;
import core.thread : Thread;

import indexer.indexer_service : photoWagonFaceListJson,
    photoWagonFaceDbStatusJson,
    photoWagonFaceStateJson,
    photoWagonFaceScanAndListJson,
    photoWagonFaceSetName,
    photoWagonFingerprintSetName,
    photoWagonUnknownPeopleCount,
    photoWagonPeopleListJson,
    photoWagonPeopleScanAndListJson;

import std.concurrency : Tid, receiveOnly, send, spawn, thisTid;
import std.string : fromStringz;

alias FaceEventCallback = extern (C) void function(void* userData, long unknownPeopleCount, bool scanInProgress);

struct FaceServiceRequest
{
    enum Op
    {
        scanFaces,
        listFaces,
        setFaceName,
        scanPeople,
        listPeople,
        setFingerprintName,
        dbStatus,
        state
    }

    Op op;
    Tid replyTo;
    string rootPath;
    long id;
    string name;
}

struct FaceServiceResponse
{
    bool ok;
    string json;
}

__gshared Tid gFaceServiceTid;
__gshared bool gFaceServiceStarted;
shared bool gLibraryScanRunning;
__gshared FaceEventCallback gFaceEventCallback;
__gshared void* gFaceEventUserData;

private void emitFaceEvent(const long unknownPeopleCount, const bool scanInProgress)
{
    if (gFaceEventCallback !is null)
    {
        gFaceEventCallback(gFaceEventUserData, unknownPeopleCount, scanInProgress);
    }
}

private void runLibraryScanInBackground(const string rootPath)
{
    scope (exit)
    {
        atomicStore(gLibraryScanRunning, false);
        emitFaceEvent(photoWagonUnknownPeopleCount(), false);
    }

    if (rootPath.length == 0)
    {
        return;
    }

    emitFaceEvent(photoWagonUnknownPeopleCount(), true);

    const _ = photoWagonPeopleScanAndListJson(rootPath);
    emitFaceEvent(photoWagonUnknownPeopleCount(), false);
}

private void startLibraryScanIfNeeded(const string rootPath)
{
    if (rootPath.length == 0)
    {
        return;
    }
    if (atomicLoad(gLibraryScanRunning))
    {
        return;
    }

    if (!cas(&gLibraryScanRunning, false, true))
    {
        return;
    }

    auto scanThread = new Thread({ runLibraryScanInBackground(rootPath.idup); });
    scanThread.isDaemon = true;
    scanThread.start();
}

private const(char)* allocCString(const string value)
{
    auto ptr = cast(char*) malloc(value.length + 1);
    if (ptr is null)
    {
        return null;
    }
    memcpy(ptr, value.ptr, value.length);
    ptr[value.length] = 0;
    return cast(const(char)*) ptr;
}

private void faceServiceMain()
{
    while (true)
    {
        auto req = receiveOnly!FaceServiceRequest();

        FaceServiceResponse response;
        response.ok = false;

        final switch (req.op)
        {
        case FaceServiceRequest.Op.scanFaces:
            startLibraryScanIfNeeded(req.rootPath);
            response.json = photoWagonFaceListJson();
            response.ok = true;
            break;
        case FaceServiceRequest.Op.listFaces:
            response.json = photoWagonFaceListJson();
            response.ok = true;
            break;
        case FaceServiceRequest.Op.setFaceName:
            response.ok = photoWagonFaceSetName(req.id, req.name);
            break;
        case FaceServiceRequest.Op.scanPeople:
            startLibraryScanIfNeeded(req.rootPath);
            response.json = photoWagonPeopleListJson();
            response.ok = true;
            break;
        case FaceServiceRequest.Op.listPeople:
            response.json = photoWagonPeopleListJson();
            response.ok = true;
            break;
        case FaceServiceRequest.Op.setFingerprintName:
            response.ok = photoWagonFingerprintSetName(req.id, req.name);
            if (response.ok)
            {
                emitFaceEvent(photoWagonUnknownPeopleCount(), atomicLoad(gLibraryScanRunning));
            }
            break;
        case FaceServiceRequest.Op.dbStatus:
            response.json = photoWagonFaceDbStatusJson();
            response.ok = true;
            break;
        case FaceServiceRequest.Op.state:
            response.json = photoWagonFaceStateJson();
            response.ok = true;
            break;
        }

        send(req.replyTo, response);
    }
}

private void ensureFaceServiceStarted()
{
    if (!gFaceServiceStarted)
    {
        gFaceServiceTid = spawn(&faceServiceMain);
        gFaceServiceStarted = true;
    }
}

private FaceServiceResponse requestFaceService(FaceServiceRequest request)
{
    ensureFaceServiceStarted();
    request.replyTo = thisTid;
    send(gFaceServiceTid, request);
    return receiveOnly!FaceServiceResponse();
}

extern (C) const(char)* photo_wagon_face_scan_and_list_json(const char* root_path)
{
    FaceServiceRequest req;
    req.op = FaceServiceRequest.Op.scanFaces;
    req.rootPath = root_path is null ? "" : fromStringz(root_path).idup;

    const res = requestFaceService(req);
    if (!res.ok)
    {
        return null;
    }
    return allocCString(res.json);
}

extern (C) const(char)* photo_wagon_face_list_json()
{
    FaceServiceRequest req;
    req.op = FaceServiceRequest.Op.listFaces;

    const res = requestFaceService(req);
    if (!res.ok)
    {
        return null;
    }
    return allocCString(res.json);
}

extern (C) bool photo_wagon_face_set_name(const long face_id, const char* name)
{
    if (name is null)
    {
        return false;
    }

    FaceServiceRequest req;
    req.op = FaceServiceRequest.Op.setFaceName;
    req.id = face_id;
    req.name = fromStringz(name).idup;

    const res = requestFaceService(req);
    return res.ok;
}

extern (C) const(char)* photo_wagon_people_scan_and_list_json(const char* root_path)
{
    FaceServiceRequest req;
    req.op = FaceServiceRequest.Op.scanPeople;
    req.rootPath = root_path is null ? "" : fromStringz(root_path).idup;

    const res = requestFaceService(req);
    if (!res.ok)
    {
        return null;
    }
    return allocCString(res.json);
}

extern (C) const(char)* photo_wagon_people_list_json()
{
    FaceServiceRequest req;
    req.op = FaceServiceRequest.Op.listPeople;

    const res = requestFaceService(req);
    if (!res.ok)
    {
        return null;
    }
    return allocCString(res.json);
}

extern (C) bool photo_wagon_fingerprint_set_name(const long fingerprint_id, const char* name)
{
    if (name is null)
    {
        return false;
    }

    FaceServiceRequest req;
    req.op = FaceServiceRequest.Op.setFingerprintName;
    req.id = fingerprint_id;
    req.name = fromStringz(name).idup;

    const res = requestFaceService(req);
    return res.ok;
}

extern (C) const(char)* photo_wagon_face_db_status_json()
{
    FaceServiceRequest req;
    req.op = FaceServiceRequest.Op.dbStatus;

    const res = requestFaceService(req);
    if (!res.ok)
    {
        return null;
    }
    return allocCString(res.json);
}

extern (C) void photo_wagon_face_set_event_callback(
    FaceEventCallback callback,
    void* user_data
)
{
    gFaceEventCallback = callback;
    gFaceEventUserData = user_data;
    if (gFaceEventCallback !is null)
    {
        emitFaceEvent(photoWagonUnknownPeopleCount(), atomicLoad(gLibraryScanRunning));
    }
}

extern (C) const(char)* photo_wagon_face_state_json()
{
    FaceServiceRequest req;
    req.op = FaceServiceRequest.Op.state;

    const res = requestFaceService(req);
    if (!res.ok)
    {
        return null;
    }
    return allocCString(res.json);
}
