#pragma once

#include <QDateTime>
#include <QFileInfo>
#include <QSet>
#include <QSize>
#include <QSqlDatabase>
#include <QString>
#include <QVector>

struct IndexedArtifact {
    QFileInfo fileInfo;
    QString sha1;
    QString thumbPath;
    QString screenPath;
    QSize originalSize;
};

class LibraryIndexer {
public:
    explicit LibraryIndexer(const QString &cacheRoot = defaultCacheRoot());

    static QString defaultCacheRoot();

    bool ensureLibrarySchema() const;
    QList<QFileInfo> collectImageFilesRecursively(const QString &rootPath) const;
    QVector<IndexedArtifact> buildArtifacts(const QList<QFileInfo> &files) const;

    bool syncDeletions(const QSet<QString> &existingSourcePaths) const;

    bool openWriteConnection(QSqlDatabase &db, const QString &connectionName) const;
    bool upsertImageRow(
        QSqlDatabase &db,
        const QString &sourcePath,
        const QFileInfo &fileInfo,
        const QString &sha1,
        const QString &thumbPath,
        const QString &screenPath,
        const QDateTime &takenAt,
        const QString &city,
        const QSize &size
    ) const;
    void closeWriteConnection(QSqlDatabase &db, const QString &connectionName) const;

    QString cacheRoot() const;

private:
    static bool isImageFile(const QString &filePath);
    static QString thumbnailKey(const QFileInfo &fileInfo);
    static QString ensureDerivedImage(
        const QFileInfo &fileInfo,
        const QString &cacheRoot,
        const QString &variant,
        int maxEdge,
        int quality
    );

    QString m_cacheRoot;
};
