#pragma once

#include <QObject>
#include <QFutureWatcher>
#include <QVariantList>
#include <QVariantMap>
#include <QString>

class FaceRecognitionBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(int unknownPeopleCount READ unknownPeopleCount NOTIFY unknownPeopleCountChanged)
    Q_PROPERTY(bool scanInProgress READ scanInProgress NOTIFY scanInProgressChanged)
public:
    explicit FaceRecognitionBridge(QObject *parent = nullptr);
    ~FaceRecognitionBridge() override;

    Q_INVOKABLE QVariantList listUnnamedFaces() const;
    Q_INVOKABLE bool setFaceName(qlonglong faceId, const QString &name) const;
    Q_INVOKABLE QVariantList listPeopleFingerprints() const;
    Q_INVOKABLE bool setFingerprintName(qlonglong fingerprintId, const QString &name) const;
    Q_INVOKABLE QVariantMap dbStatus() const;
    Q_INVOKABLE QVariantMap fullState() const;
    Q_INVOKABLE void startUnknownPeopleMonitoring(const QString &rootPath);
    Q_INVOKABLE void requestBackgroundFaceScan(const QString &rootPath);

    int unknownPeopleCount() const;
    bool scanInProgress() const;

signals:
    void unknownPeopleCountChanged();
    void scanInProgressChanged();
    void unknownPeopleDiscovered(int count);

private:
    static void faceEventCallback(void *userData, long unknownPeopleCount, bool scanInProgress);
    void applyFaceEvent(long unknownPeopleCount, bool scanInProgress);

    QVariantList parseJsonArray(const QByteArray &jsonData, const QString &key) const;
    QVariantMap parseJsonObject(const QByteArray &jsonData) const;

    QString m_scanRootPath;
    int m_unknownPeopleCount = 0;
    bool m_scanInProgress = false;
    bool m_fullScanRequestRunning = false;
};
