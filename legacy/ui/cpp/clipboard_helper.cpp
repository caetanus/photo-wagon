#include "clipboard_helper.h"

#include <QClipboard>
#include <QGuiApplication>
#include <QImage>
#include <QMimeData>
#include <QUrl>

#include "logging.h"

ClipboardHelper::ClipboardHelper(QObject *parent) : QObject(parent) {}

bool ClipboardHelper::copyImageToClipboard(const QString &fileUrl) {
    QUrl url(fileUrl);
    QString filePath = url.isLocalFile() ? url.toLocalFile() : fileUrl;

    QImage image(filePath);
    if (image.isNull()) {
        qCWarning(pwClipboard) << "Failed to load image:" << filePath;
        return false;
    }

    QClipboard *clipboard = QGuiApplication::clipboard();
    QMimeData *mimeData = new QMimeData();
    mimeData->setImageData(image);
    mimeData->setUrls({QUrl::fromLocalFile(filePath)});
    clipboard->setMimeData(mimeData);
    return true;
}

bool ClipboardHelper::copyPathToClipboard(const QString &fileUrl) {
    QUrl url(fileUrl);
    QString filePath = url.isLocalFile() ? url.toLocalFile() : fileUrl;

    QClipboard *clipboard = QGuiApplication::clipboard();
    clipboard->setText(filePath);
    return true;
}
