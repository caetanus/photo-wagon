/**
 * Structured logging for photowagond.
 *
 * Usage:
 *   import log;
 *   log.info("listening on port %s", port);
 *   log.warn("something suspicious");
 *   log.dbg("only when PHOTOWAGOND_LOG=debug");
 *
 * Levels (in order): debug < info < warn < error < fatal
 *
 * Environment variable PHOTOWAGOND_LOG sets minimum level:
 *   PHOTOWAGOND_LOG=debug   — show everything
 *   PHOTOWAGOND_LOG=warn    — only warnings and above
 *   (default: info)
 */
module log;

import std.conv : to;
import std.datetime.systime : Clock;
import std.format : format;
import std.process : environment;
import std.stdio : stderr;

// ---------------------------------------------------------------------------
// Log levels
// ---------------------------------------------------------------------------

enum Level
{
    debug_,
    info,
    warn,
    error,
    fatal,
}

// ---------------------------------------------------------------------------
// Module-level minimum threshold (set once at startup via env)
// ---------------------------------------------------------------------------

private Level gMinLevel;

shared static this()
{
    gMinLevel = Level.info; // default
    try
    {
        auto envVal = environment.get("PHOTOWAGOND_LOG", "info");
        switch (envVal)
        {
        case "debug":
            gMinLevel = Level.debug_;
            break;
        case "info":
            gMinLevel = Level.info;
            break;
        case "warn":
            gMinLevel = Level.warn;
            break;
        case "error":
            gMinLevel = Level.error;
            break;
        case "fatal":
            gMinLevel = Level.fatal;
            break;
        default:
            gMinLevel = Level.info;
            break;
        }
    }
    catch (Exception)
    {
        gMinLevel = Level.info;
    }
}

// ---------------------------------------------------------------------------
// Color helpers
// ---------------------------------------------------------------------------

private bool stderrIsTty()
{
    import core.sys.posix.unistd : isatty;
    import core.stdc.stdio : fileno;

    // Cache the result
    __gshared bool cached = false;
    __gshared bool result = false;
    if (!cached)
    {
        result = isatty(fileno(stderr.getFP())) != 0;
        cached = true;
    }
    return result;
}

private string levelLabel(Level lv)
{
    final switch (lv)
    {
    case Level.debug_:
        return "debug";
    case Level.info:
        return "info ";
    case Level.warn:
        return "warn ";
    case Level.error:
        return "ERROR";
    case Level.fatal:
        return "FATAL";
    }
}

private string levelColor(Level lv)
{
    if (!stderrIsTty())
        return "";
    final switch (lv)
    {
    case Level.debug_:
        return "\033[36m"; // cyan
    case Level.info:
        return "\033[32m"; // green
    case Level.warn:
        return "\033[33m"; // yellow
    case Level.error:
        return "\033[31m"; // red
    case Level.fatal:
        return "\033[1;31m"; // bold red
    }
}

private string resetColor()
{
    return stderrIsTty() ? "\033[0m" : "";
}

private string dimColor()
{
    return stderrIsTty() ? "\033[2m" : "";
}

// ---------------------------------------------------------------------------
// Core logging function
// ---------------------------------------------------------------------------

private void emit(Level lv, string mod, lazy string msg) nothrow
{
    if (lv < gMinLevel)
        return;

    try
    {
        auto now = Clock.currTime();
        auto ts = format("%02d:%02d:%02d.%03d",
            now.hour, now.minute, now.second,
            now.fracSecs.total!"msecs" % 1000);

        stderr.writefln("%s%s%s %s[%s | %s]%s %s",
            dimColor(), ts, resetColor(),
            levelColor(lv), levelLabel(lv), mod, resetColor(),
            msg);
    }
    catch (Exception)
    {
        // Logging must never crash the program
    }
}

// ---------------------------------------------------------------------------
// Public API — module name is auto-detected from call site
// ---------------------------------------------------------------------------

/// Debug-level log. Only shown when PHOTOWAGOND_LOG=debug.
void dbg(string mod = __MODULE__, Args...)(string fmt, lazy Args args)
{
    emit(Level.debug_, mod, safeFormat(fmt, args));
}

/// Info-level log. Default threshold.
void info(string mod = __MODULE__, Args...)(string fmt, lazy Args args)
{
    emit(Level.info, mod, safeFormat(fmt, args));
}

/// Warning-level log.
void warn(string mod = __MODULE__, Args...)(string fmt, lazy Args args)
{
    emit(Level.warn, mod, safeFormat(fmt, args));
}

/// Error-level log.
void err(string mod = __MODULE__, Args...)(string fmt, lazy Args args)
{
    emit(Level.error, mod, safeFormat(fmt, args));
}

/// Fatal-level log.
void fatal(string mod = __MODULE__, Args...)(string fmt, lazy Args args)
{
    emit(Level.fatal, mod, safeFormat(fmt, args));
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

private string safeFormat(Args...)(string fmt, lazy Args args)
{
    try
    {
        static if (Args.length == 0)
            return fmt;
        else
            return format(fmt, args);
    }
    catch (Exception e)
    {
        return fmt ~ " [log format error: " ~ e.msg ~ "]";
    }
}
