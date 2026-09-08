// Photo Wagon mobile: the Qt Quick UI in D, with a TcpBridge to a core on the
// network. On Android Qt's activity loads this as a shared library and calls
// main(); on the desktop it is an ordinary executable (for offscreen tests).
module photowagon.mobile.main;

import qt.quick.qguiapplication;
import qt.quick.qcoreapplication;
import qt.quick.qqmlapplicationengine;
import qt.quick.qqmlcontext;
import qt.quick.qurl;
import qt.quick.qresource;          // QResource, used by the qrcRegister mixin
import cppq = qt.quick.qobject;

import qtmoc, cxxrt, qrc;

import std.stdio : writeln, stdout, stderr;
import std.process : environment;

import photowagon.ui.backend : Library;
import photowagon.mobile.tcpbridge : TcpBridge;

enum APP_ID      = "photo-wagon-mobile";
enum APP_NAME    = "Photo Wagon";
enum APP_VERSION = "0.4.0";

mixin(qtdApplication!"QGuiApplication");
// The resource tree is assembled in CTFE from qml/mobile.qrc (-J=../qml).
mixin(qrcRegister(import("mobile.qrc"), "qt.quick"));

int main()
{
    if ("QT_QUICK_CONTROLS_STYLE" !in environment)
        environment["QT_QUICK_CONTROLS_STYLE"] = "Material";

    cast(void) createApp(APP_ID);
    QCoreApplication.setOrganizationName("PhotoWagon");
    QCoreApplication.setApplicationName(APP_ID);
    QCoreApplication.setApplicationVersion(APP_VERSION);
    QGuiApplication.setApplicationDisplayName(APP_NAME);

    auto lib = newQObject!Library();
    auto bridge = new TcpBridge;
    // PW_ENDPOINT=host:port overrides the saved endpoint (tests, first run).
    immutable forced = environment.get("PW_ENDPOINT", "");
    if (forced.length)
        bridge.setEndpoint(forced, 0);
    lib.start(bridge);

    auto engine = new QQmlApplicationEngine(cast(cppq.QObject) null);
    engine.rootContext().setContextProperty("library", cppq.QObject.wrap(qobjOf(lib)));

    bool failed;
    engine.connectObjectCreationFailed((const(QUrl)* u) {
        failed = true;
        stderr.writeln("QML: object creation failed");
    });

    auto url = QUrl("qrc:/mobile/Main.qml", QUrl.ParsingMode.TolerantMode);
    engine.load(url);

    auto roots = engine.rootObjects();
    writeln("qml rootObjects = ", roots.length, failed ? " (creation failed)" : "");
    stdout.flush();
    if (roots.length == 0 || failed)
        return 1;

    return QCoreApplication.exec();
}
