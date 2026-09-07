#pragma once

#include <QObject>
#include <QString>

class ClipboardHelper : public QObject {
    Q_OBJECT
public:
    explicit ClipboardHelper(QObject *parent = nullptr);

    Q_INVOKABLE bool copyImageToClipboard(const QString &fileUrl);
    Q_INVOKABLE bool copyPathToClipboard(const QString &fileUrl);
};
