// Photo Wagon UI entry point: one QGuiApplication, one QQmlApplicationEngine,
// one context property (`library`). Everything the QML sees goes through
// backend.Library; the daemon connection lives in client.DaemonClient.
module app;

import qt.quick.qguiapplication;
import qt.quick.qcoreapplication;
import qt.quick.qqmlapplicationengine;
import qt.quick.qqmlcontext;
import qt.quick.qurl;
import qt.quick.qresource;          // QResource, used by the qrcRegister mixin
import cppq = qt.quick.qobject;     // the C++ QObject; `@QObject` below is qtmoc's UDA

import qtmoc, cxxrt, qrc;

import std.stdio : writeln, stdout, stderr;
import std.process : environment;

import backend : Library;

enum APP_ID      = "photo-wagon";
enum APP_NAME    = "Photo Wagon";
enum APP_VERSION = "0.3.0";

mixin(qtdApplication!"QGuiApplication");
// The resource tree is assembled in CTFE from qml/ui.qrc (-J=qml). No rcc step.
mixin(qrcRegister(import("ui.qrc"), "qt.quick"));

int main()
{
    // Fusion honours the palette we set in Main.qml; Basic mostly ignores it.
    if ("QT_QUICK_CONTROLS_STYLE" !in environment)
        environment["QT_QUICK_CONTROLS_STYLE"] = "Fusion";

    cast(void) createApp(APP_ID);
    QCoreApplication.setOrganizationName("PhotoWagon");
    QCoreApplication.setApplicationName(APP_ID);
    QCoreApplication.setApplicationVersion(APP_VERSION);
    QGuiApplication.setApplicationDisplayName(APP_NAME);

    // newQObject registers the meta-object; only after that may signals be emitted,
    // which is why the daemon connection is started in a second step.
    auto lib = newQObject!Library();
    lib.start();

    auto engine = new QQmlApplicationEngine(cast(cppq.QObject) null);
    engine.rootContext().setContextProperty("library", cppq.QObject.wrap(qobjOf(lib)));

    bool failed;
    engine.connectObjectCreationFailed((const(QUrl)* u) {
        failed = true;
        stderr.writeln("QML: object creation failed (run with QT_FORCE_STDERR_LOGGING=1 for the reason)");
    });

    // ref const(QUrl) refuses an rvalue: keep it in a variable.
    auto url = QUrl("qrc:/Main.qml", QUrl.ParsingMode.TolerantMode);
    engine.load(url);

    auto roots = engine.rootObjects();
    writeln("qml rootObjects = ", roots.length, failed ? " (creation failed)" : "");
    stdout.flush();
    if (roots.length == 0 || failed)
        return 1;

    return QCoreApplication.exec();
}
