#include <algorithm>
#include <QCoreApplication>
#include <QDateTime>
#include <QDir>
#include <QDirIterator>
#include <QFileInfo>
#include <QGuiApplication>
#include <QLocale>
#include <QMap>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QUrl>
#include <QVariantMap>

#include "clipboard_helper.h"
#include "daemon_bridge.h"
#include "logging.h"

struct IndexPayload {
    QVariantList sections;
    QVariantList flat;
    QVariantList dateTree;
    int count = 0;
};

// Incremental page accumulator — merges paginated sections.
struct PageAccumulator {
    QVariantList sections;
    QVariantList flat;
    int loaded = 0;
    int total = 0;

    void mergePage(const QVariantList &pageSections, const QVariantList &pageFlat) {
        // Merge sections: if last accumulated section has same title as first page
        // section, combine their items.
        for (const QVariant &secVar : pageSections) {
            const QVariantMap sec = secVar.toMap();
            const QString title = sec.value(QStringLiteral("title")).toString();
            const QVariantList items = sec.value(QStringLiteral("items")).toList();

            if (!sections.isEmpty()) {
                QVariantMap lastSec = sections.last().toMap();
                if (lastSec.value(QStringLiteral("title")).toString() == title) {
                    QVariantList lastItems = lastSec.value(QStringLiteral("items")).toList();
                    lastItems.append(items);
                    lastSec.insert(QStringLiteral("items"), lastItems);
                    sections.last() = lastSec;
                    continue;
                }
            }
            sections.append(sec);
        }
        flat.append(pageFlat);
        loaded = flat.size();
    }
};

static IndexPayload buildFastFallbackIndex(const QString &rootPath) {
    IndexPayload payload;
    if (!QFileInfo::exists(rootPath) || !QFileInfo(rootPath).isDir()) {
        return payload;
    }

    auto isImage = [](const QString &path) {
        const QString suffix = QFileInfo(path).suffix().toLower();
        return suffix == QStringLiteral("jpg") ||
               suffix == QStringLiteral("jpeg") ||
               suffix == QStringLiteral("png") ||
               suffix == QStringLiteral("heic") ||
               suffix == QStringLiteral("heif") ||
               suffix == QStringLiteral("webp") ||
               suffix == QStringLiteral("bmp") ||
               suffix == QStringLiteral("tif") ||
               suffix == QStringLiteral("tiff");
    };

    struct FastItem {
        QString sourceUrl;
        QString subtitle;
        QString monthTitle;
        QDateTime dt;
    };

    QList<FastItem> items;
    items.reserve(4096);

    QDirIterator it(rootPath, QDir::Files | QDir::NoDotAndDotDot, QDirIterator::Subdirectories);
    while (it.hasNext()) {
        const QString filePath = it.next();
        if (!isImage(filePath)) {
            continue;
        }

        const QFileInfo info(filePath);
        const QDateTime dt = info.lastModified();
        FastItem item;
        item.sourceUrl = QUrl::fromLocalFile(filePath).toString();
        item.dt = dt;
        item.monthTitle = QLocale(QLocale::English).toString(dt, QStringLiteral("MMMM yyyy"));
        item.subtitle = item.monthTitle;
        items.append(item);

        if (items.size() >= 500)
            break; // Cap fast fallback — daemon will paginate the rest.
    }

    std::sort(items.begin(), items.end(), [](const FastItem &a, const FastItem &b) {
        if (a.dt != b.dt) {
            return a.dt > b.dt;
        }
        return a.sourceUrl < b.sourceUrl;
    });

    QVariantList flat;
    QVariantList sections;
    QMap<int, QMap<int, int>> yearMonthCounts;

    QString currentMonth;
    QVariantList currentItems;

    for (int index = 0; index < items.size(); ++index) {
        const FastItem &item = items[index];

        QVariantMap photo;
        photo.insert(QStringLiteral("thumbUrl"), item.sourceUrl);
        photo.insert(QStringLiteral("screenUrl"), item.sourceUrl);
        photo.insert(QStringLiteral("sourceUrl"), item.sourceUrl);
        photo.insert(QStringLiteral("subtitle"), item.subtitle);
        photo.insert(QStringLiteral("sourceWidth"), 1);
        photo.insert(QStringLiteral("sourceHeight"), 1);
        photo.insert(QStringLiteral("flatIndex"), index);
        flat.append(photo);

        if (currentMonth != item.monthTitle) {
            if (!currentMonth.isEmpty()) {
                QVariantMap sec;
                sec.insert(QStringLiteral("title"), currentMonth);
                sec.insert(QStringLiteral("items"), currentItems);
                sections.append(sec);
            }
            currentMonth = item.monthTitle;
            currentItems.clear();
        }
        currentItems.append(photo);

        const int year = item.dt.date().year();
        const int month = item.dt.date().month();
        yearMonthCounts[year][month] = yearMonthCounts[year].value(month, 0) + 1;
    }

    if (!currentMonth.isEmpty()) {
        QVariantMap sec;
        sec.insert(QStringLiteral("title"), currentMonth);
        sec.insert(QStringLiteral("items"), currentItems);
        sections.append(sec);
    }

    QVariantList dateTree;
    const QList<int> years = yearMonthCounts.keys();
    for (auto yIt = years.crbegin(); yIt != years.crend(); ++yIt) {
        const int year = *yIt;
        QVariantMap yearNode;
        yearNode.insert(QStringLiteral("year"), year);

        QVariantList months;
        const QList<int> monthKeys = yearMonthCounts[year].keys();
        for (auto mIt = monthKeys.crbegin(); mIt != monthKeys.crend(); ++mIt) {
            const int month = *mIt;
            QVariantMap monthNode;
            monthNode.insert(QStringLiteral("month"),
                             QLocale(QLocale::English).standaloneMonthName(month));
            monthNode.insert(QStringLiteral("monthNum"), month);
            monthNode.insert(QStringLiteral("count"),
                             yearMonthCounts[year].value(month));
            months.append(monthNode);
        }
        yearNode.insert(QStringLiteral("months"), months);
        dateTree.append(yearNode);
    }

    payload.sections = sections;
    payload.flat = flat;
    payload.dateTree = dateTree;
    payload.count = flat.size();
    return payload;
}

static QString chooseDefaultLibraryPath() {
    const QString home = QDir::homePath();
    const QStringList candidates = {
        QDir(home).filePath(QStringLiteral("Photos")),
        QDir(home).filePath(QStringLiteral("Pictures")),
        QDir(home).filePath(QStringLiteral("Imagens")),
        QDir(home).filePath(QStringLiteral("DCIM"))
    };

    for (const QString &candidate : candidates) {
        if (QFileInfo::exists(candidate) && QFileInfo(candidate).isDir()) {
            return candidate;
        }
    }
    return QDir(home).filePath(QStringLiteral("Photos"));
}

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    installPhotoWagonLogHandler();
    QQmlApplicationEngine engine;

    ClipboardHelper clipboardHelper;
    DaemonBridge daemonBridge;

    engine.rootContext()->setContextProperty(
        QStringLiteral("clipboardHelper"), &clipboardHelper);
    engine.rootContext()->setContextProperty(
        QStringLiteral("faceRecognitionBridge"), &daemonBridge);

    const QString photosPath = chooseDefaultLibraryPath();
    const QString photosUrl = QUrl::fromLocalFile(photosPath).toString();
    const IndexPayload initialPayload = buildFastFallbackIndex(photosPath);
    qCInfo(pwApp).noquote() << "Startup fast index:" << initialPayload.count << "files";
    qCInfo(pwApp).noquote() << "Photo library path:" << photosPath;

    engine.rootContext()->setContextProperty(QStringLiteral("photosLibraryUrl"), photosUrl);
    engine.rootContext()->setContextProperty(QStringLiteral("photosLibraryPath"), photosPath);
    engine.rootContext()->setContextProperty(QStringLiteral("photosFiles"), initialPayload.sections);
    engine.rootContext()->setContextProperty(QStringLiteral("photosFlat"), initialPayload.flat);
    engine.rootContext()->setContextProperty(QStringLiteral("photosCount"), initialPayload.count);
    engine.rootContext()->setContextProperty(QStringLiteral("photosLoaded"), initialPayload.count);
    engine.rootContext()->setContextProperty(QStringLiteral("dateTree"), initialPayload.dateTree);

    const QUrl mainQml(QStringLiteral("qrc:/ui/qml/Main.qml"));
    QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed,
                     &app, []() { QCoreApplication::exit(-1); },
                     Qt::QueuedConnection);
    engine.load(mainQml);

    // When daemon connects: request dates (fast) + first page of index.
    QObject::connect(&daemonBridge, &DaemonBridge::connectedChanged, &engine,
                     [&daemonBridge, photosPath]() {
        if (daemonBridge.connected()) {
            qCInfo(pwDaemon).noquote() << "Daemon connected — requesting dates + first page";
            daemonBridge.requestDates(photosPath);
            daemonBridge.requestIndexPage(photosPath, 0, 200);
        }
    });

    // When dates arrive: update sidebar immediately.
    QObject::connect(&daemonBridge, &DaemonBridge::datesReady, &engine,
                     [&engine](QVariantList dateTree, int count) {
        engine.rootContext()->setContextProperty(QStringLiteral("dateTree"), dateTree);
        engine.rootContext()->setContextProperty(QStringLiteral("photosCount"), count);
        qCInfo(pwApp).noquote() << "Dates loaded:" << count << "photos";
    });

    // Accumulate pages and update the UI incrementally.
    static const int PAGE_SIZE = 200;
    auto *acc = new PageAccumulator;

    QObject::connect(&daemonBridge, &DaemonBridge::indexPageReady, &engine,
                     [&engine, &daemonBridge, photosPath, acc](
                         QVariantList sections, QVariantList flat,
                         int offset, int total) {
        acc->total = total;
        acc->mergePage(sections, flat);

        // Push to QML on first page (instant feedback) and on completion.
        // Intermediate: every 1000 items to avoid constant model resets.
        const bool isFirst = (offset == 0);
        const bool isDone = (acc->loaded >= total);
        const bool isMilestone = (acc->loaded % 1000 < PAGE_SIZE);

        if (isFirst || isDone || isMilestone) {
            engine.rootContext()->setContextProperty(QStringLiteral("photosFiles"), acc->sections);
            engine.rootContext()->setContextProperty(QStringLiteral("photosFlat"), acc->flat);
            engine.rootContext()->setContextProperty(QStringLiteral("photosCount"), total);
            engine.rootContext()->setContextProperty(QStringLiteral("photosLoaded"), acc->loaded);
        }

        qCInfo(pwApp).noquote() << "Index page loaded:" << acc->loaded << "/" << total;

        if (acc->loaded < total) {
            // Request next page.
            daemonBridge.requestIndexPage(photosPath, acc->loaded, PAGE_SIZE);
        } else {
            // All pages loaded — start face scan.
            qCInfo(pwApp).noquote() << "Full index loaded:" << total << "photos";
            daemonBridge.requestBackgroundFaceScan(photosPath);
        }
    });

    // Keep the old full-index signal wired (backward compat if /api/index is used).
    QObject::connect(&daemonBridge, &DaemonBridge::indexReady, &engine,
                     [&engine, &daemonBridge, photosPath](
                         QVariantList sections, QVariantList flat,
                         QVariantList dateTree, int count) {
        if (count <= 0 || flat.isEmpty()) {
            qCWarning(pwDaemon) << "Daemon index empty — keeping fast index";
        } else {
            engine.rootContext()->setContextProperty(QStringLiteral("photosFiles"), sections);
            engine.rootContext()->setContextProperty(QStringLiteral("photosFlat"), flat);
            engine.rootContext()->setContextProperty(QStringLiteral("photosCount"), count);
            engine.rootContext()->setContextProperty(QStringLiteral("dateTree"), dateTree);
            qCInfo(pwDaemon).noquote() << "Daemon full index applied:" << count << "files";
        }
        daemonBridge.requestBackgroundFaceScan(photosPath);
    });

    // Launch the D daemon.
    // Look for photowagond next to the Qt binary, then in the dub build dir.
    const QString appDir = QCoreApplication::applicationDirPath();
    QStringList searchPaths = {
        QDir(appDir).filePath(QStringLiteral("photowagond")),
        QDir(appDir).filePath(QStringLiteral("../photowagond/photowagond")),
        QDir(QCoreApplication::applicationDirPath()).filePath(
            QStringLiteral("../../photowagond/photowagond")),
    };

    QString daemonPath;
    for (const QString &path : searchPaths) {
        if (QFileInfo::exists(path)) {
            daemonPath = path;
            break;
        }
    }

    if (daemonPath.isEmpty()) {
        qCWarning(pwDaemon).noquote() << "photowagond not found — build it first:  cd photowagond && dub build";
    } else {
        daemonBridge.start(daemonPath);
    }

    return app.exec();
}
