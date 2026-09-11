// Photo Wagon UI: one QGuiApplication, one QQmlApplicationEngine, one context
// property (`library`). Everything the QML sees goes through backend.Library;
// the core (on its own thread) is reached through bridge.CoreBridge.
module photowagon.ui.app;

import qt.quick.qguiapplication;
import qt.quick.qcoreapplication;
import qt.quick.qqmlapplicationengine;
import qt.quick.qqmlcontext;
import qt.quick.qurl;
import qt.quick.qicon;
import qt.quick.qresource;          // QResource, used by the qrcRegister mixin
import cppq = qt.quick.qobject;     // the C++ QObject; `@QObject` below is qtmoc's UDA

import qtmoc, cxxrt, qrc;

import std.stdio : writeln, stdout, stderr;
import std.process : environment;

import photowagon.ui.backend : Library;
import photowagon.ui.bridge : CoreBridge;
import photowagon.core.config : Config;
import photowagon.core.ipc.link : InProcessLink;

enum APP_ID      = "photo-wagon";
enum APP_NAME    = "Photo Wagon";
enum APP_VERSION = "0.3.0";

mixin(qtdApplication!"QGuiApplication");
// The resource tree is assembled in CTFE from qml/ui.qrc (-J=qml). No rcc step.
mixin(qrcRegister(import("ui.qrc"), "qt.quick"));

/// Runs the Qt event loop on the calling (main) thread until the window closes.
int runUi(Config cfg, InProcessLink link)
{
    // Fusion honours the palette we set in Main.qml; Basic mostly ignores it.
    if ("QT_QUICK_CONTROLS_STYLE" !in environment)
        environment["QT_QUICK_CONTROLS_STYLE"] = "Fusion";

    cast(void) createApp(APP_ID);
    QCoreApplication.setOrganizationName("PhotoWagon");
    QCoreApplication.setApplicationName(APP_ID);
    QCoreApplication.setApplicationVersion(APP_VERSION);
    QGuiApplication.setApplicationDisplayName(APP_NAME);
    // The window icon: X11 takes it from here; Wayland compositors look the app_id
    // ("photo-wagon") up in share/photo-wagon.desktop (share/install-desktop.sh).
    QGuiApplication.setDesktopFileName(APP_ID);
    auto icon = QIcon(":/icon.png");
    QGuiApplication.setWindowIcon(icon);

    // newQObject registers the meta-object; only after that may signals be emitted,
    // which is why the bridge is started in a second step.
    auto lib = newQObject!Library();
    lib.start(new CoreBridge(link));

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
