/// SHA-256 by libsodium, in place of std.digest.sha's: the same small API the code uses
/// (`SHA256 h; h.put(...); h.finish()`, `sha256Of(data)`), several times faster. The pure-D
/// one was ~half of the receiving computer's CPU during a sync (every 1 MiB piece and every
/// whole file is hashed), and the UDP reader starved behind it: the socket buffer overflowed
/// and udx took the drops for congestion. libsodium is linked on every build already.
module photowagon.core.util.fastsha;

import libsodium.crypto_hash_sha256 : crypto_hash_sha256_state, crypto_hash_sha256_init,
    crypto_hash_sha256_update, crypto_hash_sha256_final, crypto_hash_sha256;

// libsodium's C functions are pure in effect (the state is the caller's); marked so, the
// wrappers can stand in for std.digest's inside pure code
private auto assumePure(T)(T fn) @trusted
{
    import std.traits : functionAttributes, functionLinkage, SetFunctionAttributes, FunctionAttribute;

    enum attrs = functionAttributes!T | FunctionAttribute.pure_;
    return cast(SetFunctionAttributes!(T, functionLinkage!T, attrs)) fn;
}

/// Incremental SHA-256. Needs no start() (like std.digest's); finish() resets it.
struct SHA256
{
    private crypto_hash_sha256_state st;
    private bool started;

    void start() pure nothrow @nogc @trusted
    {
        assumePure(&crypto_hash_sha256_init)(&st);
        started = true;
    }

    void put(scope const(void)[] data) pure nothrow @nogc @trusted
    {
        if (!started)
            start();
        if (data.length)
            assumePure(&crypto_hash_sha256_update)(&st, cast(const(ubyte)*) data.ptr, data.length);
    }

    ubyte[32] finish() pure nothrow @nogc @trusted
    {
        if (!started)
            start();
        ubyte[32] digest;
        assumePure(&crypto_hash_sha256_final)(&st, digest.ptr);
        started = false;
        return digest;
    }
}

/// SHA-256 of `data` in one go.
ubyte[32] sha256Of(scope const(void)[] data) pure nothrow @nogc @trusted
{
    ubyte[32] digest;
    assumePure(&crypto_hash_sha256)(digest.ptr, cast(const(ubyte)*) data.ptr, data.length);
    return digest;
}

/// The sha256 (lower hex) of a file's bytes, streamed in 1 MiB reads; "" if it cannot be
/// read. Blocking: for a worker thread.
string fileSha256(string path)
{
    import std.stdio : File;
    import std.digest : toHexString, LetterCase;

    try
    {
        SHA256 h;
        auto f = File(path, "rb");
        foreach (chunk; f.byChunk(1 << 20))
            h.put(chunk);
        return toHexString!(LetterCase.lower)(h.finish()).idup;
    }
    catch (Exception)
        return "";
}

unittest
{
    import std.digest.sha : stdSha = sha256Of;

    auto msg = cast(const(ubyte)[]) "the quick brown fox jumps over the lazy dog";
    assert(sha256Of(msg) == stdSha(msg));
    SHA256 h;
    h.put(msg[0 .. 10]);
    h.put(msg[10 .. $]);
    assert(h.finish() == stdSha(msg));
    SHA256 e;
    assert(e.finish() == stdSha(cast(const(ubyte)[]) ""));
}
