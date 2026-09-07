#include "library_indexer.h"

#include <QCryptographicHash>
#include <QDir>
#include <QDirIterator>
#include <QFile>
#include <QImage>
#include <QImageReader>
#include <QImageWriter>
#include <QSqlError>
#include <QSqlQuery>
#include <QUrl>
#include <QtConcurrent/QtConcurrentMap>

LibraryIndexer::LibraryIndexer(const QString &cacheRoot)
    : m_cacheRoot(cacheRoot) {
    QDir().mkpath(m_cacheRoot);
}

QString LibraryIndexer::defaultCacheRoot() {
    const QString cacheRoot = QDir::home().filePath(QStringLiteral(".cache/photo-wagon"));
    QDir().mkpath(cacheRoot);
    return cacheRoot;
}

QString LibraryIndexer::cacheRoot() const {
    return m_cacheRoot;
}

bool LibraryIndexer::isImageFile(const QString &filePath) {
    const QString suffix = QFileInfo(filePath).suffix().toLower();
    return suffix == QStringLiteral("jpg") ||
           suffix == QStringLiteral("jpeg") ||
           suffix == QStringLiteral("png") ||
           suffix == QStringLiteral("heic") ||
           suffix == QStringLiteral("heif") ||
           suffix == QStringLiteral("webp") ||
           suffix == QStringLiteral("bmp") ||
           suffix == QStringLiteral("tif") ||
           suffix == QStringLiteral("tiff");
}

QString LibraryIndexer::thumbnailKey(const QFileInfo &fileInfo) {
    const QByteArray input =
        fileInfo.absoluteFilePath().toUtf8() + '|' +
        QByteArray::number(fileInfo.size()) + '|' +
        QByteArray::number(fileInfo.lastModified().toMSecsSinceEpoch());

    return QString::fromLatin1(QCryptographicHash::hash(input, QCryptographicHash::Sha1).toHex());
}

QString LibraryIndexer::ensureDerivedImage(
    const QFileInfo &fileInfo,
    const QString &cacheRoot,
    const QString &variant,
    int maxEdge,
    int quality
) {
    const QString key = thumbnailKey(fileInfo);
    const QString shard = key.left(2);
    const QString shardDir = QDir(cacheRoot).filePath(shard);
    QDir().mkpath(shardDir);

    const QString outName = key.left(8) + QStringLiteral("-") + variant + QStringLiteral(".jpg");
    const QString outPath = QDir(shardDir).filePath(outName);
    if (QFileInfo::exists(outPath)) {
        return outPath;
    }

    QImageReader reader(fileInfo.absoluteFilePath());
    reader.setAutoTransform(true);

    const QSize sourceSize = reader.size();
    if (sourceSize.isValid()) {
        const QSize bounded = sourceSize.scaled(maxEdge, maxEdge, Qt::KeepAspectRatio);
        reader.setScaledSize(bounded);
    }

    const QImage image = reader.read();
    if (image.isNull()) {
        return QString();
    }

    QImageWriter writer(outPath, "jpg");
    writer.setQuality(quality);
    if (!writer.write(image)) {
        return QString();
    }

    return outPath;
}

bool LibraryIndexer::ensureLibrarySchema() const {
    const QString connectionName = QStringLiteral("library_init_conn");
    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
    db.setDatabaseName(QDir(m_cacheRoot).filePath(QStringLiteral("library.sqlite")));
    if (!db.open()) {
        return false;
    }

    QSqlQuery query(db);
    const bool ok = query.exec(
        QStringLiteral(
            "CREATE TABLE IF NOT EXISTS images ("
            "source_path TEXT PRIMARY KEY,"
            "source_mtime_ms INTEGER NOT NULL,"
            "source_size INTEGER NOT NULL,"
            "sha1 TEXT NOT NULL,"
            "thumb_path TEXT NOT NULL,"
            "screen_path TEXT NOT NULL,"
            "taken_at TEXT,"
            "city TEXT,"
            "width INTEGER NOT NULL,"
            "height INTEGER NOT NULL,"
            "indexed_at_ms INTEGER NOT NULL"
            ")"
        )
    );

    db.close();
    db = QSqlDatabase();
    QSqlDatabase::removeDatabase(connectionName);
    return ok;
}

QList<QFileInfo> LibraryIndexer::collectImageFilesRecursively(const QString &rootPath) const {
    QList<QFileInfo> imageFiles;

    QDirIterator iterator(
        rootPath,
        QDir::Files | QDir::NoDotAndDotDot,
        QDirIterator::Subdirectories
    );

    while (iterator.hasNext()) {
        const QString filePath = iterator.next();
        QFileInfo fileInfo(filePath);
        if (!isImageFile(fileInfo.absoluteFilePath())) {
            continue;
        }
        imageFiles.append(fileInfo);
    }

    return imageFiles;
}

QVector<IndexedArtifact> LibraryIndexer::buildArtifacts(const QList<QFileInfo> &files) const {
    const auto mapper = [cacheRoot = m_cacheRoot](const QFileInfo &fileInfo) {
        IndexedArtifact artifact;
        artifact.fileInfo = fileInfo;
        artifact.sha1 = thumbnailKey(fileInfo);
        artifact.thumbPath = ensureDerivedImage(fileInfo, cacheRoot, QStringLiteral("thumb"), 512, 82);
        artifact.screenPath = ensureDerivedImage(fileInfo, cacheRoot, QStringLiteral("screen"), 1920, 88);

        QImageReader dimensionReader(fileInfo.absoluteFilePath());
        dimensionReader.setAutoTransform(true);
        artifact.originalSize = dimensionReader.size();
        return artifact;
    };

    return QtConcurrent::blockingMapped<QVector<IndexedArtifact>>(files, mapper);
}

bool LibraryIndexer::syncDeletions(const QSet<QString> &existingSourcePaths) const {
    const QString connectionName = QStringLiteral("library_cleanup_conn");
    QSqlDatabase db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
    db.setDatabaseName(QDir(m_cacheRoot).filePath(QStringLiteral("library.sqlite")));
    if (!db.open()) {
        QSqlDatabase::removeDatabase(connectionName);
        return false;
    }

    QSqlQuery readQuery(db);
    if (!readQuery.exec(QStringLiteral("SELECT source_path, thumb_path, screen_path FROM images"))) {
        db.close();
        db = QSqlDatabase();
        QSqlDatabase::removeDatabase(connectionName);
        return false;
    }

    db.transaction();
    QSqlQuery deleteQuery(db);
    deleteQuery.prepare(QStringLiteral("DELETE FROM images WHERE source_path = :source_path"));

    while (readQuery.next()) {
        const QString sourcePath = readQuery.value(0).toString();
        const QString thumbPath = readQuery.value(1).toString();
        const QString screenPath = readQuery.value(2).toString();

        if (existingSourcePaths.contains(sourcePath)) {
            continue;
        }

        if (!thumbPath.isEmpty()) {
            QFile::remove(thumbPath);
        }
        if (!screenPath.isEmpty()) {
            QFile::remove(screenPath);
        }

        deleteQuery.bindValue(QStringLiteral(":source_path"), sourcePath);
        deleteQuery.exec();
    }

    const bool committed = db.commit();
    db.close();
    db = QSqlDatabase();
    QSqlDatabase::removeDatabase(connectionName);
    return committed;
}

bool LibraryIndexer::openWriteConnection(QSqlDatabase &db, const QString &connectionName) const {
    db = QSqlDatabase::addDatabase(QStringLiteral("QSQLITE"), connectionName);
    db.setDatabaseName(QDir(m_cacheRoot).filePath(QStringLiteral("library.sqlite")));
    if (!db.open()) {
        return false;
    }
    db.transaction();
    return true;
}

bool LibraryIndexer::upsertImageRow(
    QSqlDatabase &db,
    const QString &sourcePath,
    const QFileInfo &fileInfo,
    const QString &sha1,
    const QString &thumbPath,
    const QString &screenPath,
    const QDateTime &takenAt,
    const QString &city,
    const QSize &size
) const {
    QSqlQuery query(db);
    query.prepare(
        QStringLiteral(
            "INSERT INTO images ("
            "source_path, source_mtime_ms, source_size, sha1, thumb_path, screen_path, "
            "taken_at, city, width, height, indexed_at_ms"
            ") VALUES ("
            ":source_path, :source_mtime_ms, :source_size, :sha1, :thumb_path, :screen_path, "
            ":taken_at, :city, :width, :height, :indexed_at_ms"
            ") ON CONFLICT(source_path) DO UPDATE SET "
            "source_mtime_ms=excluded.source_mtime_ms,"
            "source_size=excluded.source_size,"
            "sha1=excluded.sha1,"
            "thumb_path=excluded.thumb_path,"
            "screen_path=excluded.screen_path,"
            "taken_at=excluded.taken_at,"
            "city=excluded.city,"
            "width=excluded.width,"
            "height=excluded.height,"
            "indexed_at_ms=excluded.indexed_at_ms"
        )
    );

    query.bindValue(QStringLiteral(":source_path"), sourcePath);
    query.bindValue(QStringLiteral(":source_mtime_ms"), fileInfo.lastModified().toMSecsSinceEpoch());
    query.bindValue(QStringLiteral(":source_size"), static_cast<qlonglong>(fileInfo.size()));
    query.bindValue(QStringLiteral(":sha1"), sha1);
    query.bindValue(QStringLiteral(":thumb_path"), thumbPath);
    query.bindValue(QStringLiteral(":screen_path"), screenPath);
    query.bindValue(QStringLiteral(":taken_at"), takenAt.isValid() ? takenAt.toString(Qt::ISODate) : QString());
    query.bindValue(QStringLiteral(":city"), city);
    query.bindValue(QStringLiteral(":width"), size.isValid() ? size.width() : 1);
    query.bindValue(QStringLiteral(":height"), size.isValid() ? size.height() : 1);
    query.bindValue(QStringLiteral(":indexed_at_ms"), QDateTime::currentMSecsSinceEpoch());

    return query.exec();
}

void LibraryIndexer::closeWriteConnection(QSqlDatabase &db, const QString &connectionName) const {
    if (db.isOpen()) {
        if (!db.commit()) {
            db.rollback();
        }
        db.close();
    }
    db = QSqlDatabase();
    QSqlDatabase::removeDatabase(connectionName);
}
