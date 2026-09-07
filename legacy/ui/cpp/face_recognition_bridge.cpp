#include "face_recognition_bridge.h"

#include <QByteArray>
#include <QtConcurrent/QtConcurrentRun>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QJsonParseError>
#include <QFutureWatcher>
#include <QMetaObject>

#include "indexer_bridge.h"

FaceRecognitionBridge::FaceRecognitionBridge(QObject *parent)
    : QObject(parent) {
    photo_wagon_face_set_event_callback(&FaceRecognitionBridge::faceEventCallback, this);
}

FaceRecognitionBridge::~FaceRecognitionBridge() {
    photo_wagon_face_set_event_callback(nullptr, nullptr);
}

void FaceRecognitionBridge::faceEventCallback(void *userData, long unknownPeopleCount, bool scanInProgress) {
    auto *bridge = static_cast<FaceRecognitionBridge *>(userData);
    if (bridge == nullptr) {
        return;
    }

    QMetaObject::invokeMethod(bridge, [bridge, unknownPeopleCount, scanInProgress]() {
        bridge->applyFaceEvent(unknownPeopleCount, scanInProgress);
    }, Qt::QueuedConnection);
}

void FaceRecognitionBridge::applyFaceEvent(long unknownPeopleCount, bool scanInProgress) {
    const int newCount = static_cast<int>(unknownPeopleCount);
    if (newCount != m_unknownPeopleCount) {
        m_unknownPeopleCount = newCount;
        emit unknownPeopleCountChanged();
        emit unknownPeopleDiscovered(m_unknownPeopleCount);
    }

    if (scanInProgress != m_scanInProgress) {
        m_scanInProgress = scanInProgress;
        emit scanInProgressChanged();
    }
}

QVariantList FaceRecognitionBridge::listUnnamedFaces() const {
    const char *jsonPtr = photo_wagon_face_list_json();
    if (jsonPtr == nullptr) {
        return {};
    }

    const QByteArray jsonData(jsonPtr);
    photo_wagon_index_free(jsonPtr);
    return parseJsonArray(jsonData, QStringLiteral("faces"));
}

bool FaceRecognitionBridge::setFaceName(qlonglong faceId, const QString &name) const {
    const QByteArray nameUtf8 = name.toUtf8();
    return photo_wagon_face_set_name(static_cast<long>(faceId), nameUtf8.constData());
}

QVariantList FaceRecognitionBridge::listPeopleFingerprints() const {
    const char *jsonPtr = photo_wagon_people_list_json();
    if (jsonPtr == nullptr) {
        return {};
    }

    const QByteArray jsonData(jsonPtr);
    photo_wagon_index_free(jsonPtr);
    return parseJsonArray(jsonData, QStringLiteral("fingerprints"));
}

bool FaceRecognitionBridge::setFingerprintName(qlonglong fingerprintId, const QString &name) const {
    const QByteArray nameUtf8 = name.toUtf8();
    return photo_wagon_fingerprint_set_name(static_cast<long>(fingerprintId), nameUtf8.constData());
}

QVariantMap FaceRecognitionBridge::dbStatus() const {
    const char *jsonPtr = photo_wagon_face_db_status_json();
    if (jsonPtr == nullptr) {
        return {};
    }

    const QByteArray jsonData(jsonPtr);
    photo_wagon_index_free(jsonPtr);
    return parseJsonObject(jsonData);
}

QVariantMap FaceRecognitionBridge::fullState() const {
    const char *jsonPtr = photo_wagon_face_state_json();
    if (jsonPtr == nullptr) {
        return {};
    }

    const QByteArray jsonData(jsonPtr);
    photo_wagon_index_free(jsonPtr);
    return parseJsonObject(jsonData);
}

void FaceRecognitionBridge::startUnknownPeopleMonitoring(const QString &rootPath) {
    if (!rootPath.isEmpty()) {
        m_scanRootPath = rootPath;
    }
}

void FaceRecognitionBridge::requestBackgroundFaceScan(const QString &rootPath) {
    if (!rootPath.isEmpty()) {
        m_scanRootPath = rootPath;
    }
    if (m_scanRootPath.isEmpty() || m_fullScanRequestRunning) {
        return;
    }

    m_fullScanRequestRunning = true;
    auto *watcher = new QFutureWatcher<void>(this);
    connect(watcher, &QFutureWatcher<void>::finished, this, [this, watcher]() {
        m_fullScanRequestRunning = false;
        watcher->deleteLater();
    });

    watcher->setFuture(QtConcurrent::run([rootPath = m_scanRootPath]() {
        const QByteArray rootUtf8 = rootPath.toUtf8();
        const char *scanJsonPtr = photo_wagon_people_scan_and_list_json(rootUtf8.constData());
        if (scanJsonPtr != nullptr) {
            photo_wagon_index_free(scanJsonPtr);
        }
    }));
}

int FaceRecognitionBridge::unknownPeopleCount() const {
    return m_unknownPeopleCount;
}

bool FaceRecognitionBridge::scanInProgress() const {
    return m_scanInProgress;
}

QVariantList FaceRecognitionBridge::parseJsonArray(const QByteArray &jsonData, const QString &key) const {
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(jsonData, &parseError);
    if (!document.isObject()) {
        return {};
    }

    const QJsonObject root = document.object();
    return root.value(key).toArray().toVariantList();
}

QVariantMap FaceRecognitionBridge::parseJsonObject(const QByteArray &jsonData) const {
    QJsonParseError parseError;
    const QJsonDocument document = QJsonDocument::fromJson(jsonData, &parseError);
    if (!document.isObject()) {
        return {};
    }
    return document.object().toVariantMap();
}
