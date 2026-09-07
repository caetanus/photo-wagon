#include "daemon_bridge.h"

#include <QCoreApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QNetworkReply>

#include "logging.h"

// ──────────────────────────────────────────────────────────────
// Construction / destruction
// ──────────────────────────────────────────────────────────────

DaemonBridge::DaemonBridge(QObject *parent) : QObject(parent) {
    m_http = new QNetworkAccessManager(this);

    m_socket = new QWebSocket(QString(), QWebSocketProtocol::VersionLatest, this);
    connect(m_socket, &QWebSocket::connected, this, &DaemonBridge::onSocketConnected);
    connect(m_socket, &QWebSocket::disconnected, this, &DaemonBridge::onSocketDisconnected);
    connect(m_socket, &QWebSocket::textMessageReceived, this, &DaemonBridge::onTextMessageReceived);
}

DaemonBridge::~DaemonBridge() {
    if (m_daemon) {
        m_daemon->terminate();
        m_daemon->waitForFinished(3000);
    }
}

// ──────────────────────────────────────────────────────────────
// Daemon lifecycle
// ──────────────────────────────────────────────────────────────

void DaemonBridge::start(const QString &daemonPath) {
    if (m_daemon)
        return;

    m_daemon = new QProcess(this);
    m_daemon->setProcessChannelMode(QProcess::SeparateChannels);
    connect(m_daemon, &QProcess::readyReadStandardOutput, this, &DaemonBridge::onDaemonReadyReadStdout);
    connect(m_daemon, QOverload<int, QProcess::ExitStatus>::of(&QProcess::finished),
            this, &DaemonBridge::onDaemonFinished);

    qCInfo(pwDaemon).noquote() << "Starting daemon:" << daemonPath;
    m_daemon->start(daemonPath, QStringList());
}

void DaemonBridge::onDaemonReadyReadStdout() {
    while (m_daemon->canReadLine()) {
        const QByteArray line = m_daemon->readLine().trimmed();
        if (line.startsWith("READY:")) {
            m_daemonPort = line.mid(6).toInt();
            const QUrl wsUrl(QStringLiteral("ws://127.0.0.1:%1/ws").arg(m_daemonPort));
            qCInfo(pwDaemon).noquote() << "Daemon ready on port" << m_daemonPort
                              << "— connecting WebSocket for events";
            m_socket->open(wsUrl);
        }
    }
}

void DaemonBridge::onDaemonFinished(int exitCode, QProcess::ExitStatus exitStatus) {
    qCWarning(pwDaemon).noquote() << "Daemon exited, code" << exitCode
                         << (exitStatus == QProcess::CrashExit ? "(crashed)" : "");
}

// ──────────────────────────────────────────────────────────────
// WebSocket — events only
// ──────────────────────────────────────────────────────────────

void DaemonBridge::onSocketConnected() {
    m_connected = true;
    emit connectedChanged();
    qCInfo(pwDaemon).noquote() << "Event WebSocket connected";
}

void DaemonBridge::onSocketDisconnected() {
    m_connected = false;
    emit connectedChanged();
    qCWarning(pwDaemon).noquote() << "Event WebSocket disconnected";
}

void DaemonBridge::onTextMessageReceived(const QString &message) {
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(message.toUtf8(), &err);
    if (!doc.isObject()) {
        qCWarning(pwDaemon) << "Daemon event: bad JSON:" << err.errorString();
        return;
    }

    const QJsonObject obj = doc.object();
    const QString event = obj.value(QStringLiteral("event")).toString();

    if (event == QStringLiteral("face_update")) {
        const int newCount = obj.value(QStringLiteral("unknownPeopleCount")).toInt();
        const bool inProgress = obj.value(QStringLiteral("scanInProgress")).toBool();
        const int scanned = obj.value(QStringLiteral("scannedImages")).toInt();

        if (newCount != m_unknownPeopleCount) {
            m_unknownPeopleCount = newCount;
            emit unknownPeopleCountChanged();
            emit unknownPeopleDiscovered(m_unknownPeopleCount);
        }
        if (scanned != m_scannedImages) {
            m_scannedImages = scanned;
            emit scannedImagesChanged();
        }
        if (inProgress != m_scanInProgress) {
            m_scanInProgress = inProgress;
            emit scanInProgressChanged();

            // When scan completes, auto-refresh the people list
            if (!inProgress) {
                requestPeopleList();
            }
        }
    }
}

// ──────────────────────────────────────────────────────────────
// REST helpers
// ──────────────────────────────────────────────────────────────

QUrl DaemonBridge::apiUrl(const QString &path) const {
    return QUrl(QStringLiteral("http://127.0.0.1:%1%2").arg(m_daemonPort).arg(path));
}

void DaemonBridge::getJson(const QString &path,
                           std::function<void(const QJsonObject &)> handler) {
    if (m_daemonPort == 0) {
        qCWarning(pwDaemon) << "REST GET" << path << "— daemon not ready";
        return;
    }
    QNetworkReply *reply = m_http->get(QNetworkRequest(apiUrl(path)));
    connect(reply, &QNetworkReply::finished, this, [reply, handler]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            qCWarning(pwDaemon) << "REST error:" << reply->errorString();
            return;
        }
        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (doc.isObject())
            handler(doc.object());
    });
}

void DaemonBridge::postJson(const QString &path, const QJsonObject &body,
                            std::function<void(const QJsonObject &)> handler) {
    if (m_daemonPort == 0) {
        qCWarning(pwDaemon) << "REST POST" << path << "— daemon not ready";
        return;
    }
    QNetworkRequest req(apiUrl(path));
    req.setHeader(QNetworkRequest::ContentTypeHeader, QStringLiteral("application/json"));
    QNetworkReply *reply = m_http->post(req, QJsonDocument(body).toJson(QJsonDocument::Compact));
    connect(reply, &QNetworkReply::finished, this, [reply, handler]() {
        reply->deleteLater();
        if (reply->error() != QNetworkReply::NoError) {
            qCWarning(pwDaemon) << "REST error:" << reply->errorString();
            return;
        }
        const QJsonDocument doc = QJsonDocument::fromJson(reply->readAll());
        if (doc.isObject())
            handler(doc.object());
    });
}

// ──────────────────────────────────────────────────────────────
// Public request methods — all via REST
// ──────────────────────────────────────────────────────────────

void DaemonBridge::requestIndex(const QString &rootPath) {
    const QString path = QStringLiteral("/api/index?rootPath=%1")
                             .arg(QString::fromUtf8(QUrl::toPercentEncoding(rootPath)));
    getJson(path, [this](const QJsonObject &obj) {
        const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
        const QVariantList sections = data.value(QStringLiteral("sections")).toArray().toVariantList();
        const QVariantList flat = data.value(QStringLiteral("flat")).toArray().toVariantList();
        const QVariantList dateTree = data.value(QStringLiteral("dateTree")).toArray().toVariantList();
        const int count = data.value(QStringLiteral("count")).toInt();
        emit indexReady(sections, flat, dateTree, count);
    });
}

void DaemonBridge::requestIndexPage(const QString &rootPath, int offset, int limit) {
    const QString path = QStringLiteral("/api/index_page?rootPath=%1&offset=%2&limit=%3")
                             .arg(QString::fromUtf8(QUrl::toPercentEncoding(rootPath)))
                             .arg(offset)
                             .arg(limit);
    getJson(path, [this](const QJsonObject &obj) {
        const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
        const QVariantList sections = data.value(QStringLiteral("sections")).toArray().toVariantList();
        const QVariantList flat = data.value(QStringLiteral("flat")).toArray().toVariantList();
        const int offset = data.value(QStringLiteral("offset")).toInt();
        const int total = data.value(QStringLiteral("total")).toInt();
        emit indexPageReady(sections, flat, offset, total);
    });
}

void DaemonBridge::requestDates(const QString &rootPath) {
    const QString path = QStringLiteral("/api/dates?rootPath=%1")
                             .arg(QString::fromUtf8(QUrl::toPercentEncoding(rootPath)));
    getJson(path, [this](const QJsonObject &obj) {
        const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
        const QVariantList dateTree = data.value(QStringLiteral("dateTree")).toArray().toVariantList();
        const int count = data.value(QStringLiteral("count")).toInt();
        emit datesReady(dateTree, count);
    });
}

void DaemonBridge::requestBackgroundFaceScan(const QString &rootPath) {
    QJsonObject body;
    body.insert(QStringLiteral("rootPath"), rootPath);
    postJson(QStringLiteral("/api/face_scan"), body, [](const QJsonObject &) {
        // fire-and-forget — progress arrives via WebSocket events
    });
}

void DaemonBridge::requestFaceList() {
    getJson(QStringLiteral("/api/face_list"), [this](const QJsonObject &obj) {
        const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
        emit faceListReady(data.value(QStringLiteral("faces")).toArray().toVariantList());
    });
}

void DaemonBridge::requestPeopleList() {
    getJson(QStringLiteral("/api/people_list"), [this](const QJsonObject &obj) {
        const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
        m_cachedFingerprints = data.value(QStringLiteral("fingerprints")).toArray().toVariantList();
        emit peopleListReady(m_cachedFingerprints);
    });
}

void DaemonBridge::setFaceName(qlonglong faceId, const QString &name) {
    QJsonObject body;
    body.insert(QStringLiteral("faceId"), static_cast<qint64>(faceId));
    body.insert(QStringLiteral("name"), name);
    postJson(QStringLiteral("/api/face_set_name"), body, [](const QJsonObject &) {});
}

bool DaemonBridge::setFingerprintName(qlonglong fingerprintId, const QString &name) {
    QJsonObject body;
    body.insert(QStringLiteral("fingerprintId"), static_cast<qint64>(fingerprintId));
    body.insert(QStringLiteral("name"), name);
    postJson(QStringLiteral("/api/fingerprint_set_name"), body, [](const QJsonObject &) {});
    return true; // optimistic
}

void DaemonBridge::requestFaceDbStatus() {
    getJson(QStringLiteral("/api/face_db_status"), [this](const QJsonObject &obj) {
        const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
        emit faceDbStatusReady(data.toVariantMap());
    });
}

void DaemonBridge::requestFaceState() {
    getJson(QStringLiteral("/api/face_state"), [this](const QJsonObject &obj) {
        const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
        emit faceStateReady(data.toVariantMap());
    });
}

void DaemonBridge::requestFacesForPhoto(const QString &sourceUrl) {
    // Convert file:// URL to local path for the daemon query.
    QUrl url(sourceUrl);
    const QString localPath = url.isLocalFile() ? url.toLocalFile() : sourceUrl;
    const QString path = QStringLiteral("/api/faces_for_photo?path=%1")
                             .arg(QString::fromUtf8(QUrl::toPercentEncoding(localPath)));
    getJson(path, [this, sourceUrl](const QJsonObject &obj) {
        const QJsonObject data = obj.value(QStringLiteral("data")).toObject();
        const QVariantList faces = data.value(QStringLiteral("faces")).toArray().toVariantList();
        emit facesForPhotoReady(sourceUrl, faces);
    });
}

void DaemonBridge::startUnknownPeopleMonitoring(const QString &rootPath) {
    Q_UNUSED(rootPath);
    // Fetch initial state from the daemon once it's connected.
    if (m_connected) {
        requestFaceState();
    }
}

// ──────────────────────────────────────────────────────────────
// Synchronous convenience wrappers
// ──────────────────────────────────────────────────────────────

QVariantList DaemonBridge::listPeopleFingerprints() {
    requestPeopleList(); // async refresh for next call
    return m_cachedFingerprints;
}

bool DaemonBridge::setFingerprintNameSync(qlonglong fingerprintId, const QString &name) {
    setFingerprintName(fingerprintId, name);
    return true;
}
