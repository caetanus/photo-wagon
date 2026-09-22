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

/// SIGTERM / SIGINT end the process. vibe-core installs handlers for both on the
/// thread that runs its event loop (the libp2p one), which only stop that loop —
/// a `kill` would leave the Qt app running. Ours wins because it is installed later.
void installQuitHandler() nothrow @nogc
{
    version (Posix)
    {
        import core.sys.posix.signal : sigaction, sigaction_t, SIGTERM, SIGINT;
        import core.sys.posix.unistd : _exit;

        extern (C) static void quit(int) nothrow @nogc { _exit(0); }
        sigaction_t sa;
        sa.sa_handler = &quit;
        sigaction(SIGTERM, &sa, null);
        sigaction(SIGINT, &sa, null);
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

    /// An alternate signal stack for the calling thread, so a stack overflow can
    /// still be reported (the handler would die on the exhausted stack otherwise).
    /// Every thread the app creates calls this first.
    void useCrashStack() nothrow @nogc
    {
        import core.stdc.stdlib : malloc;

        enum size = 64 * 1024;
        stack_t st;
        st.ss_sp = malloc(size);
        st.ss_size = size;
        st.ss_flags = 0;
        if (st.ss_sp !is null)
            sigaltstack(&st, null);
    }

    /// Call once at startup.
    void installCrashHandler() nothrow @nogc
    {
        useCrashStack();
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
    void useCrashStack() nothrow @nogc {}
}

// ---- stdout / stderr → logcat -----------------------------------------------------
// Qt's activity gives the process no terminal: D's writeln, vibe-core's log (a
// fiber that aborts explains itself on stderr first) and Qt's own warnings would
// vanish. A pipe replaces both descriptors and a thread relays the lines.
version (Android)
{
    void captureStdioToLogcat()
    {
        import core.sys.posix.unistd : pipe, dup2, read;
        import core.thread : Thread;

        int[2] fds;
        if (pipe(fds) != 0)
            return;
        dup2(fds[1], 1);
        dup2(fds[1], 2);
        auto t = new Thread({
            useCrashStack();
            char[4096] buf;
            string pending;
            for (;;)
            {
                immutable n = read(fds[0], buf.ptr, buf.length);
                if (n <= 0)
                    break;
                pending ~= buf[0 .. n];
                ptrdiff_t nl;
                import std.string : indexOf, toStringz;
                while ((nl = pending.indexOf('\n')) >= 0)
                {
                    auto line = pending[0 .. nl];
                    pending = pending[nl + 1 .. $];
                    if (line.length)
                        __android_log_write(4, "photowagon-io", line.toStringz);
                }
            }
        });
        t.name = "stdio";
        t.isDaemon = true;
        t.start();
    }
}
else
{
    void captureStdioToLogcat() {}
}

// ---- TLS probe: are thread-local variables really per thread here? -------------------
// (eventcore keeps its per-thread driver in a TLS variable; on a runtime whose TLS
// is shared, another thread's exit disposes the libp2p connection.)
private int tlsProbe;
void logTls(string who)
{
    import core.thread : Thread;
    plog("tls: ", who, " thread=", cast(void*) Thread.getThis(), " &tlsProbe=", cast(void*) &tlsProbe);
}

// ---- TLS pin: make the GC see this thread's thread-local variables ----------------------
// On Android (LDC 1.42, bionic) druntime does not scan a thread's ELF TLS block, so a GC
// object referenced only from a thread-local (vibe's per-thread TaskFiber/scheduler, any
// module-level variable in D) gets collected while in use — the "OutOfMemoryError of
// size_t.max" / yieldLock asserts right after the first collection (2026-09-21, Waydroid
// rig). Until druntime is fixed, every D thread we run registers its TLS block as a GC
// range: dl_iterate_phdr gives our .so's PT_TLS size and, on bionic >= API 29, the calling
// thread's block address (dlpi_tls_data). A 4 KB conservative range per thread.
version (Android)
{
    private extern (C)
    {
        struct ElfW_Phdr { uint p_type; uint p_flags; ulong p_offset; ulong p_vaddr; ulong p_paddr; ulong p_filesz; ulong p_memsz; ulong p_align; }
        struct dl_phdr_info
        {
            ulong dlpi_addr;
            const(char)* dlpi_name;
            const(ElfW_Phdr)* dlpi_phdr;
            ushort dlpi_phnum;
            ulong dlpi_adds;
            ulong dlpi_subs;
            size_t dlpi_tls_modid;
            void* dlpi_tls_data;
        }
        int dl_iterate_phdr(int function(dl_phdr_info*, size_t, void*) cb, void* data);
    }
    private enum PT_TLS = 7;

    private struct TlsFound { void* base; size_t size; size_t modid; bool hit; }

    private extern (C) int findOurTls(dl_phdr_info* info, size_t sz, void* data)
    {
        auto f = cast(TlsFound*) data;
        immutable probe = cast(size_t) &tlsProbe;
        foreach (i; 0 .. info.dlpi_phnum)
        {
            auto ph = info.dlpi_phdr[i];
            if (ph.p_type != PT_TLS)
                continue;
            // ours is the module whose thread block contains our own TLS variable
            if (info.dlpi_tls_data !is null)
            {
                immutable b = cast(size_t) info.dlpi_tls_data;
                if (probe >= b && probe < b + ph.p_memsz)
                {
                    f.base = info.dlpi_tls_data;
                    f.size = cast(size_t) ph.p_memsz;
                    f.modid = info.dlpi_tls_modid;
                    f.hit = true;
                    return 1;
                }
            }
        }
        return 0;
    }
}

/// Register the calling thread's TLS block with the GC (Android only; a no-op elsewhere).
/// Call it first thing in every D thread that touches the GC. Returns what it found.
string pinThreadTls(string who)
{
    version (Android)
    {
        import core.memory : GC;
        TlsFound f;
        dl_iterate_phdr(&findOurTls, &f);
        if (!f.hit)
        {
            plog("tls: ", who, " — no PT_TLS block found for &tlsProbe=", cast(void*) &tlsProbe, " (dlpi_tls_data null?) — NOT pinned");
            return "not pinned";
        }
        GC.addRange(f.base, f.size);
        plog("tls: ", who, " pinned TLS block ", f.base, " +", f.size, " (modid ", f.modid, ") &tlsProbe=", cast(void*) &tlsProbe);
        return "pinned";
    }
    else
        return "n/a";
}
