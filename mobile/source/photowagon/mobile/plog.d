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

/// Runs `dg` and logs it when it took longer than `limitMs` on this thread.
void timed(string what, long limitMs, scope void delegate() dg)
{
    import core.time : MonoTime;

    immutable t0 = MonoTime.currTime;
    dg();
    immutable ms = (MonoTime.currTime - t0).total!"msecs";
    if (ms >= limitMs)
        plog("slow: ", what, " ", ms, " ms");
}

// ---- crash reporting ------------------------------------------------------------
// Samsung's shipping builds do not write tombstones for third-party apps, so a
// SIGSEGV in the Qt thread left no trace but "Fatal signal 11". This handler
// logs the signal, the fault address and a backtrace (libunwind, which LDC
// links for exceptions; dladdr names the frames) to logcat, then re-raises.
version (Android)
{
    import core.sys.posix.signal;

    extern (C) nothrow @nogc
    {
        alias _Unwind_Reason_Code = int;
        struct _Unwind_Context;
        alias _Unwind_Trace_Fn = _Unwind_Reason_Code function(_Unwind_Context*, void*);
        _Unwind_Reason_Code _Unwind_Backtrace(_Unwind_Trace_Fn, void*);
        size_t _Unwind_GetIP(_Unwind_Context*);

        struct Dl_info
        {
            const(char)* dli_fname;
            void* dli_fbase;
            const(char)* dli_sname;
            void* dli_saddr;
        }
        int dladdr(const(void)* addr, Dl_info* info);
    }

    private __gshared char[512] crashLine;
    private __gshared int crashDepth;

    private extern (C) _Unwind_Reason_Code crashFrame(_Unwind_Context* ctx, void*) nothrow @nogc
    {
        import core.stdc.stdio : snprintf;

        immutable pc = _Unwind_GetIP(ctx);
        if (pc == 0 || crashDepth > 40)
            return 5; // _URC_END_OF_STACK
        Dl_info info;
        if (dladdr(cast(void*) pc, &info) && info.dli_fname)
        {
            immutable off = pc - cast(size_t) info.dli_fbase;
            if (info.dli_sname)
                snprintf(crashLine.ptr, crashLine.length, "  #%02d pc %016zx %s (%s+%zu)", crashDepth, off, info.dli_fname,
                    info.dli_sname, pc - cast(size_t) info.dli_saddr);
            else
                snprintf(crashLine.ptr, crashLine.length, "  #%02d pc %016zx %s", crashDepth, off, info.dli_fname);
        }
        else
            snprintf(crashLine.ptr, crashLine.length, "  #%02d pc %016zx ?", crashDepth, pc);
        __android_log_write(6, "photowagon", crashLine.ptr);
        crashDepth++;
        return 0; // _URC_NO_REASON
    }

    private extern (C) void onCrash(int sig, siginfo_t* si, void*) nothrow @nogc
    {
        import core.stdc.stdio : snprintf;

        snprintf(crashLine.ptr, crashLine.length, "crash: signal %d code %d fault address %p", sig, si ? si.si_code : 0,
            si ? si.si_addr : null);
        __android_log_write(6, "photowagon", crashLine.ptr);
        crashDepth = 0;
        _Unwind_Backtrace(&crashFrame, null);
        __android_log_write(6, "photowagon", "crash: end of backtrace");
        // back to the default action so the system still sees the crash
        sigaction_t dfl;
        dfl.sa_handler = SIG_DFL;
        sigaction(sig, &dfl, null);
        raise(sig);
    }

    /// Call once at startup.
    void installCrashHandler() nothrow @nogc
    {
        sigaction_t sa;
        sa.sa_sigaction = &onCrash;
        sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
        foreach (sig; [SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGFPE])
            sigaction(sig, &sa, null);
    }
}
else
{
    void installCrashHandler() nothrow @nogc {}
}
