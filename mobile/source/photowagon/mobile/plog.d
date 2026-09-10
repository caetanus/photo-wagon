/// One log line: stdout on the desktop, logcat (tag "photowagon") on Android,
/// where stdout of a Qt activity goes nowhere.
module photowagon.mobile.plog;

version (Android)
{
    extern (C) int __android_log_write(int prio, const(char)* tag, const(char)* text) nothrow @nogc;
}

void plog(T...)(T args)
{
    import std.conv : text;
    import std.stdio : writeln, stdout;

    immutable s = text(args);
    writeln(s);
    stdout.flush();
    version (Android)
    {
        import std.string : toStringz;
        __android_log_write(4 /* INFO */, "photowagon", s.toStringz);
    }
}
