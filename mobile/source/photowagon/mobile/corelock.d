// One writer per data directory: the phone core takes an exclusive flock on
// <dataDir>/core.lock before it touches the index, thumbnails or settings, and holds it for
// the life of the process (the kernel drops it when the process dies, however it dies). A
// second core — an in-process one next to the service, a relaunch racing a dying process —
// is refused instead of interleaving writes with the first. Only the holder may remove a
// stale core socket (stage 5). docs/phone-core-service.md, stage 4.
module photowagon.mobile.corelock;

import std.path : buildPath;

private extern (C) int flock(int fd, int operation) nothrow @nogc;
private enum LOCK_EX = 2, LOCK_NB = 4, LOCK_UN = 8;

private __gshared int lockFd = -1;
private __gshared string lockDir;

/// Take the data directory's core lock. False when another process holds it (then
/// `coreLockHolder` names it). Idempotent for the holder.
bool acquireCoreLock(string dataDir)
{
    import core.sys.posix.fcntl : open, O_RDWR, O_CREAT, O_CLOEXEC;
    import core.sys.posix.unistd : close, ftruncate, getpid, pwrite;
    import std.conv : to;
    import std.file : mkdirRecurse;
    import std.string : toStringz;

    if (lockFd >= 0)
        return lockDir == dataDir;
    mkdirRecurse(dataDir);
    immutable fd = open(buildPath(dataDir, "core.lock").toStringz, O_RDWR | O_CREAT | O_CLOEXEC, octal600);
    if (fd < 0)
        throw new Exception("cannot open the core lock in " ~ dataDir);
    if (flock(fd, LOCK_EX | LOCK_NB) != 0)
    {
        close(fd);
        return false;
    }
    // the holder's pid, for the refusal message of the next one (diagnostics only)
    immutable pid = getpid().to!string ~ "\n";
    cast(void) ftruncate(fd, 0);
    cast(void) pwrite(fd, pid.ptr, pid.length, 0);
    lockFd = fd;
    lockDir = dataDir;
    return true;
}

/// Give the lock up (the end of an orderly shutdown). Safe to call when not held.
void releaseCoreLock() nothrow @nogc
{
    import core.sys.posix.unistd : close;

    if (lockFd < 0)
        return;
    flock(lockFd, LOCK_UN);
    close(lockFd);
    lockFd = -1;
}

bool holdsCoreLock() nothrow @nogc { return lockFd >= 0; }

/// The pid the current holder wrote, or "" (diagnostics).
string coreLockHolder(string dataDir)
{
    import std.file : readText;
    import std.string : strip;

    try
        return readText(buildPath(dataDir, "core.lock")).strip;
    catch (Exception)
        return "";
}

private enum octal600 = 0x180;   // 0600
