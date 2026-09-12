/* clipboard_qt.cpp — see clipboard_qt.h. */
#include "clipboard_qt.h"

#include <QtCore/QByteArray>
#include <QtCore/QString>
#include <QtCore/QMimeData>
#include <QtGui/QClipboard>
#include <QtGui/QGuiApplication>

int pw_clipboard_set_files(const char *uris, const char *gnome, const char *text)
{
    QClipboard *cb = QGuiApplication::clipboard();
    if (!cb)
        return -1;
    QMimeData *md = new QMimeData; /* owned by the clipboard from setMimeData on */
    if (uris && *uris)
        md->setData(QStringLiteral("text/uri-list"), QByteArray(uris));
    if (gnome && *gnome)
        md->setData(QStringLiteral("x-special/gnome-copied-files"), QByteArray(gnome));
    if (text && *text)
        md->setText(QString::fromUtf8(text));
    cb->setMimeData(md, QClipboard::Clipboard);
    return 0;
}
