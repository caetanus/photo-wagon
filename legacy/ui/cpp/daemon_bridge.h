#pragma once

#include <QHash>
#include <QNetworkAccessManager>
#include <QObject>
#include <QProcess>
#include <QVariantList>
#include <QVariantMap>
#include <QWebSocket>

/**
 * DaemonBridge – manages the photowagond child process.
 * REST API for all request/response, WebSocket for push events only.
 */
class DaemonBridge : public QObject {
    Q_OBJECT
    Q_PROPERTY(bool connected READ connected NOTIFY connectedChanged)
    Q_PROPERTY(int unknownPeopleCount READ unknownPeopleCount NOTIFY unknownPeopleCountChanged)
    Q_PROPERTY(bool scanInProgress READ scanInProgress NOTIFY scanInProgressChanged)
    Q_PROPERTY(int scannedImages READ scannedImages NOTIFY scannedImagesChanged)

public:
    explicit DaemonBridge(QObject *parent = nullptr);
    ~DaemonBridge() override;

    void start(const QString &daemonPath);

    // ── REST-backed async requests ─────────────────────────────────

    Q_INVOKABLE void requestIndex(const QString &rootPath);
    Q_INVOKABLE void requestIndexPage(const QString &rootPath, int offset, int limit);
    Q_INVOKABLE void requestDates(const QString &rootPath);
    Q_INVOKABLE void requestBackgroundFaceScan(const QString &rootPath);
    Q_INVOKABLE void requestFaceList();
    Q_INVOKABLE void requestPeopleList();
    Q_INVOKABLE void setFaceName(qlonglong faceId, const QString &name);
    Q_INVOKABLE bool setFingerprintName(qlonglong fingerprintId, const QString &name);
    Q_INVOKABLE void requestFaceDbStatus();
    Q_INVOKABLE void requestFaceState();
    Q_INVOKABLE void requestFacesForPhoto(const QString &sourceUrl);
    Q_INVOKABLE void startUnknownPeopleMonitoring(const QString &rootPath);

    bool connected() const { return m_connected; }
    int unknownPeopleCount() const { return m_unknownPeopleCount; }
    bool scanInProgress() const { return m_scanInProgress; }
    int scannedImages() const { return m_scannedImages; }

    Q_INVOKABLE QVariantList listPeopleFingerprints();
    Q_INVOKABLE bool setFingerprintNameSync(qlonglong fingerprintId, const QString &name);

signals:
    void connectedChanged();
    void unknownPeopleCountChanged();
    void scanInProgressChanged();
    void scannedImagesChanged();
    void unknownPeopleDiscovered(int count);
    void indexReady(QVariantList sections, QVariantList flat,
                    QVariantList dateTree, int count);
    void indexPageReady(QVariantList sections, QVariantList flat,
                        int offset, int total);
    void datesReady(QVariantList dateTree, int count);
    void peopleListReady(QVariantList fingerprints);
    void faceListReady(QVariantList faces);
    void faceDbStatusReady(QVariantMap status);
    void faceStateReady(QVariantMap state);
    void facesForPhotoReady(QString sourceUrl, QVariantList faces);

private slots:
    void onSocketConnected();
    void onSocketDisconnected();
    void onTextMessageReceived(const QString &message);
    void onDaemonReadyReadStdout();
    void onDaemonFinished(int exitCode, QProcess::ExitStatus exitStatus);

private:
    QUrl apiUrl(const QString &path) const;
    void getJson(const QString &path, std::function<void(const QJsonObject &)> handler);
    void postJson(const QString &path, const QJsonObject &body,
                  std::function<void(const QJsonObject &)> handler);

    QProcess *m_daemon = nullptr;
    QWebSocket *m_socket = nullptr;
    QNetworkAccessManager *m_http = nullptr;

    bool m_connected = false;
    int m_daemonPort = 0;
    int m_unknownPeopleCount = 0;
    bool m_scanInProgress = false;
    int m_scannedImages = 0;

    QVariantList m_cachedFingerprints;
};
