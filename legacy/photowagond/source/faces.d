module faces;

import core.atomic : atomicLoad, atomicStore, cas;
import core.thread : Thread;
import std.conv : to;

import log;
import indexer;

// ---------------------------------------------------------------------------
// Shared state
// ---------------------------------------------------------------------------

private shared long gUnknownCount = 0;
private shared bool gScanInProgress = false;
private shared bool gScanRequested = false;
private shared string gScanRoot;

// Event queue: background thread pushes JSON event strings,
// websocket handler drains them.
private __gshared string[] gEventQueue;
private __gshared Object gEventMutex;

shared static this()
{
    gEventMutex = new Object();
}

// ---------------------------------------------------------------------------
// Event queue API
// ---------------------------------------------------------------------------

void pushFaceEvent(string eventJson)
{
    synchronized (gEventMutex)
    {
        gEventQueue ~= eventJson;
    }
}

string[] drainFaceEvents()
{
    synchronized (gEventMutex)
    {
        if (gEventQueue.length == 0)
            return [];
        auto events = gEventQueue.dup;
        gEventQueue.length = 0;
        return events;
    }
}

// ---------------------------------------------------------------------------
// Background scan
// ---------------------------------------------------------------------------

void startFaceScan(string rootPath)
{
    if (atomicLoad(gScanInProgress))
        return; // already running

    atomicStore(gScanRoot, rootPath);
    atomicStore(gScanRequested, true);
    atomicStore(gScanInProgress, true);

    auto t = new Thread(&scanWorker);
    t.isDaemon = true;
    t.start();
}

private void scanWorker()
{
    scope (exit)
        atomicStore(gScanInProgress, false);

    auto root = atomicLoad(gScanRoot);
    log.info("face scan started for %s", root);

    pushStatusEvent();
    indexer.scanLibraryFaces(root, (size_t scanned, long ukCount) nothrow {
        try
        {
            atomicStore(gUnknownCount, ukCount);
            pushFaceEvent(
                `{"event":"face_update","unknownPeopleCount":` ~ to!string(ukCount)
                    ~ `,"scanInProgress":true,"scannedImages":` ~ to!string(scanned) ~ `}`);
        }
        catch (Exception)
        {
        }
    });

    // Update count after scan
    auto count = indexer.unknownPeopleCount();
    atomicStore(gUnknownCount, count);
    pushStatusEvent();

    log.info("face scan finished, unknown=%s", count);
}

private void pushStatusEvent()
{
    auto inProg = atomicLoad(gScanInProgress);
    auto count = atomicLoad(gUnknownCount);
    pushFaceEvent(
        `{"event":"face_update","unknownPeopleCount":` ~ to!string(
            count)
            ~ `,"scanInProgress":` ~ (inProg ? "true" : "false") ~ `}`);
}

// ---------------------------------------------------------------------------
// Queries (called from websocket handler)
// ---------------------------------------------------------------------------

long currentUnknownCount()
{
    auto c = indexer.unknownPeopleCount();
    atomicStore(gUnknownCount, c);
    return c;
}

bool isScanInProgress()
{
    return atomicLoad(gScanInProgress);
}

string fullStateJson()
{
    auto inProg = atomicLoad(gScanInProgress);
    auto count = indexer.unknownPeopleCount();
    atomicStore(gUnknownCount, count);
    return `{"unknownPeopleCount":` ~ to!string(count)
        ~ `,"scanInProgress":` ~ (inProg ? "true" : "false") ~ `}`;
}
