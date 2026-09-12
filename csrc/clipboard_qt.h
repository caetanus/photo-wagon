/* clipboard_qt.h — puts files on the system clipboard from C++.
 *
 * Why this is not done through the D binding: QClipboard::setMimeData takes
 * ownership of the QMimeData and deletes it when the clipboard changes; a
 * QMimeData created on the D side is also deleted by the D wrapper when the
 * garbage collector lets go of it — two owners, one object, and the app
 * segfaulted in QMimeData::hasText on the next clipboard notification (and in
 * setMimeData on the second copy). Here the QMimeData is created in C++ and
 * belongs to Qt alone. */
#ifndef CLIPBOARD_QT_H
#define CLIPBOARD_QT_H

#ifdef __cplusplus
extern "C" {
#endif

/* uris: "\r\n"-separated file URLs (text/uri-list); gnome: the
   x-special/gnome-copied-files payload; text: text/plain. Any may be empty.
   Returns 0, or -1 without a QGuiApplication. */
int pw_clipboard_set_files(const char *uris, const char *gnome, const char *text);

#ifdef __cplusplus
}
#endif
#endif
