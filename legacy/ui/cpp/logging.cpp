#include "logging.h"

#include <QDateTime>
#include <QByteArray>
#include <cstdio>

#ifdef Q_OS_UNIX
#include <unistd.h>
#endif

// ── Category definitions ───────────────────────────────────────

Q_LOGGING_CATEGORY(pwApp, "pw.app")
Q_LOGGING_CATEGORY(pwDaemon, "pw.daemon")
Q_LOGGING_CATEGORY(pwClipboard, "pw.clipboard")

// ── Color helpers ──────────────────────────────────────────────

static bool stderrIsTerminal()
{
#ifdef Q_OS_UNIX
    static const bool isTty = isatty(fileno(stderr));
    return isTty;
#else
    return false;
#endif
}

static const char *levelLabel(QtMsgType type)
{
    switch (type) {
    case QtDebugMsg:    return "debug";
    case QtInfoMsg:     return "info ";
    case QtWarningMsg:  return "warn ";
    case QtCriticalMsg: return "ERROR";
    case QtFatalMsg:    return "FATAL";
    }
    return "?????";
}

static const char *levelColor(QtMsgType type)
{
    if (!stderrIsTerminal())
        return "";
    switch (type) {
    case QtDebugMsg:    return "\033[36m";   // cyan
    case QtInfoMsg:     return "\033[32m";   // green
    case QtWarningMsg:  return "\033[33m";   // yellow
    case QtCriticalMsg: return "\033[31m";   // red
    case QtFatalMsg:    return "\033[1;31m"; // bold red
    }
    return "";
}

static const char *resetColor()
{
    return stderrIsTerminal() ? "\033[0m" : "";
}

static const char *dimColor()
{
    return stderrIsTerminal() ? "\033[2m" : "";
}

// ── Message handler ────────────────────────────────────────────

static void photoWagonMessageHandler(QtMsgType type,
                                     const QMessageLogContext &ctx,
                                     const QString &msg)
{
    const QByteArray timestamp =
        QDateTime::currentDateTime().toString(QStringLiteral("hh:mm:ss.zzz")).toUtf8();
    const char *category = ctx.category ? ctx.category : "default";
    const QByteArray message = msg.toUtf8();

    std::fprintf(stderr, "%s%s%s %s[%s | %s]%s %s\n",
                 dimColor(),
                 timestamp.constData(),
                 resetColor(),
                 levelColor(type),
                 levelLabel(type),
                 category,
                 resetColor(),
                 message.constData());
}

// ── Public API ─────────────────────────────────────────────────

void installPhotoWagonLogHandler()
{
    qInstallMessageHandler(photoWagonMessageHandler);
}
