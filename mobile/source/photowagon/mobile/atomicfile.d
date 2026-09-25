// Files other readers may open at any moment — a thumbnail QML is loading, the index the next
// start reads, a status file the other process (MainActivity / CoreService) parses — are
// published atomically: written under a temporary name in the same directory, then renamed
// over the final one. A reader sees the old file or the new one, never half of one; a crash
// or kill mid-write leaves only a stray temporary (swept on the next start).
// docs/phone-core-service.md, stage 4.
module photowagon.mobile.atomicfile;

import core.atomic : atomicOp;
import std.conv : to;
import std.file : exists, remove, rename, write;

private shared long tmpSeq;

/// A temporary name next to `path` (same directory, so the rename is atomic), unique across
/// processes and calls.
string tempFor(string path)
{
    import core.sys.posix.unistd : getpid;

    return path ~ ".tmp-" ~ getpid().to!string ~ "-" ~ atomicOp!"+="(tmpSeq, 1).to!string;
}

/// Write `data` to `path` atomically. Throws on failure (the old file, if any, stays).
void writeAtomic(string path, const(void)[] data)
{
    immutable tmp = tempFor(path);
    scope (failure)
        dropQuietly(tmp);
    write(tmp, data);
    rename(tmp, path);
}

/// Let `produce` write the file under a temporary name (a QImage save, a JNI encoder), then
/// publish it as `path`. False — and nothing published — when `produce` fails.
bool publishAtomic(string path, scope bool delegate(string tmp) produce)
{
    immutable tmp = tempFor(path);
    bool ok;
    try
        ok = produce(tmp) && tmp.exists;
    catch (Exception)
        ok = false;
    if (!ok)
    {
        dropQuietly(tmp);
        return false;
    }
    try
        rename(tmp, path);
    catch (Exception)
    {
        dropQuietly(tmp);
        return false;
    }
    return true;
}

/// Whether `path` is one of ours: <name>.tmp-<pid>-<seq>, judged on the file name alone (a
/// parent directory may contain ".tmp-" too).
bool isTemporary(string path)
{
    import std.ascii : isDigit;
    import std.path : baseName;
    import std.string : lastIndexOf;

    immutable name = path.baseName;
    immutable at = name.lastIndexOf(".tmp-");
    if (at <= 0)
        return false;
    immutable rest = name[at + 5 .. $];
    immutable dash = rest.lastIndexOf('-');
    if (dash <= 0 || dash + 1 >= rest.length)
        return false;
    foreach (c; rest[0 .. dash])
        if (!c.isDigit)
            return false;
    foreach (c; rest[dash + 1 .. $])
        if (!c.isDigit)
            return false;
    return true;
}

/// Remove the temporaries a killed process left in `dir`.
size_t sweepTemporaries(string dir)
{
    import std.file : dirEntries, SpanMode;
    import std.string : indexOf;

    size_t n;
    try
        foreach (e; dirEntries(dir, SpanMode.shallow))
            if (e.isFile && isTemporary(e.name))
            {
                dropQuietly(e.name);
                n++;
            }
    catch (Exception)
    {
    }
    return n;
}

private void dropQuietly(string p) nothrow
{
    try
        if (p.exists)
            remove(p);
    catch (Exception)
    {
    }
}
