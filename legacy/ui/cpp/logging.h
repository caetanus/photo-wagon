#pragma once

#include <QLoggingCategory>

// ── Logging categories ─────────────────────────────────────────
// Usage:  qCInfo(pwApp)    << "message";
//         qCWarning(pwDaemon) << "bad thing happened";
//         qCDebug(pwDaemon)   << "only shown when enabled";

Q_DECLARE_LOGGING_CATEGORY(pwApp)
Q_DECLARE_LOGGING_CATEGORY(pwDaemon)
Q_DECLARE_LOGGING_CATEGORY(pwClipboard)

// ── Install the custom message handler ─────────────────────────
// Call once at the top of main(), before any Qt logging.
// Output format (when stderr is a tty):
//   12:34:56.789 [info  | pw.app] Startup fast index: 42 files
//
// Respects QT_LOGGING_RULES:
//   QT_LOGGING_RULES="pw.daemon.debug=true"  — enable debug for daemon
//   QT_LOGGING_RULES="pw.*.debug=true"       — enable all debug output
void installPhotoWagonLogHandler();
