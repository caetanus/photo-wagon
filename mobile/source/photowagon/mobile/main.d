// Photo Wagon mobile: the phone's own photos in the Qt Quick UI, in D, with a
// link to a computer running `photo-wagon --serve` to send them to. On Android
// Qt's activity loads this as a shared library and calls main(); on the
// desktop it is an ordinary executable (for offscreen tests, with
// PW_PHONE_ROOTS=/dir[:/dir] standing in for DCIM/ and Pictures/).
module photowagon.mobile.main;

import qt.quick.qguiapplication;
import qt.quick.qcoreapplication;
import qt.quick.qqmlapplicationengine;
import qt.quick.qqmlcontext;
import qt.quick.qstandardpaths;
import qt.quick.qurl;
import qt.quick.qresource;          // QResource, used by the qrcRegister mixin
import cppq = qt.quick.qobject;

import qtmoc, cxxrt, qrc;

import std.path : buildPath, dirName;
import std.process : environment;
import std.stdio : writeln, stdout, stderr;
import std.string : split;

import photowagon.ui.backend : Library;
import photowagon.mobile.localbridge : LocalBridge;
import photowagon.mobile.phoneindex : PhoneIndex;
import photowagon.mobile.tcpbridge : TcpBridge;

enum APP_ID      = "photo-wagon-mobile";
enum APP_NAME    = "Photo Wagon";
enum APP_VERSION = "0.4.0";

mixin(qtdApplication!"QGuiApplication");
// The resource tree is assembled in CTFE from qml/mobile.qrc (-J=../qml).
mixin(qrcRegister(import("mobile.qrc"), "qt.quick"));

/// DCIM/ and Pictures/ of the device (or PW_PHONE_ROOTS on a desktop test).
string[] photoRoots()
{
    immutable forced = environment.get("PW_PHONE_ROOTS", "");
    if (forced.length)
        return forced.split(":");
    immutable pictures = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.PicturesLocation).toString();
    return [buildPath(pictures.dirName, "DCIM"), pictures];
}

int main()
{
    if ("QT_QUICK_CONTROLS_STYLE" !in environment)
        environment["QT_QUICK_CONTROLS_STYLE"] = "Material";

    cast(void) createApp(APP_ID);
    QCoreApplication.setOrganizationName("PhotoWagon");
    QCoreApplication.setApplicationName(APP_ID);
    QCoreApplication.setApplicationVersion(APP_VERSION);
    QGuiApplication.setApplicationDisplayName(APP_NAME);

    immutable dataDir = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.AppDataLocation).toString();
    immutable cacheDir = QStandardPaths.writableLocation(QStandardPaths.StandardLocation.CacheLocation).toString();
    auto roots = photoRoots();
    writeln("phone: roots ", roots, " data ", dataDir, " cache ", cacheDir); stdout.flush();

    auto lib = newQObject!Library();
    auto computer = new TcpBridge;
    // PW_ENDPOINT=host:port overrides the saved computer (tests, first run).
    immutable forced = environment.get("PW_ENDPOINT", "");
    if (forced.length)
        computer.setEndpoint(forced, 0);
    auto index = new PhoneIndex(roots, dataDir, cacheDir);
    lib.start(new LocalBridge(index, computer));

    auto engine = new QQmlApplicationEngine(cast(cppq.QObject) null);
    engine.rootContext().setContextProperty("library", cppq.QObject.wrap(qobjOf(lib)));

    bool failed;
    engine.connectObjectCreationFailed((const(QUrl)* u) {
        failed = true;
        stderr.writeln("QML: object creation failed");
    });

    auto url = QUrl("qrc:/mobile/Main.qml", QUrl.ParsingMode.TolerantMode);
    engine.load(url);

    auto rootObjects = engine.rootObjects();
    writeln("qml rootObjects = ", rootObjects.length, failed ? " (creation failed)" : "");
    stdout.flush();
    if (rootObjects.length == 0 || failed)
        return 1;

    return QCoreApplication.exec();
}
