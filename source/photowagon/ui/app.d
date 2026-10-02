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
import photowagon.ui.windowctl : WindowCtl;
import qt.quick.qwindow : QWindow;

// qml-css-engine shim (csrc/css_shim.cpp): register the qmlcss QML types, create the
// CssTheme + CssLayoutEngine, and load a GTK-mapped stylesheet, so the UI can wear the
// system GTK/Adwaita theme. Absent from the headless/node builds (no Qt).
extern (C)
{
    void pw_css_register();
    void* pw_css_init(void* qmlEngine);
    void pw_css_load(void* theme, const(char)* path);
    void pw_css_load_string(void* theme, const(char)* css);
    void pw_css_viewport(void* theme, double w, double h);
}

// Qt Multimedia warm-up (csrc/media_prewarm.h): the FFmpeg backend's hardware-decoder probe
// runs on a worker thread at start-up instead of freezing the window on the first video.
extern (C)
{
    void pw_media_prewarm();
    void pw_media_prewarm_join();
}
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

    // Stability: the threaded render loop segfaults here in QOpenGLContext::currentContext
    // on the QSGRenderThread (Qt 6.11.2 + Wayland/GL, and worse with GL-heavy content such as
    // the QtLocation map). The basic loop renders on the GUI thread and sidesteps it. Override
    // with QSG_RENDER_LOOP=threaded to A/B test.
    if ("QSG_RENDER_LOOP" !in environment)
        environment["QSG_RENDER_LOOP"] = "basic";

    cast(void) createApp(APP_ID);
    pw_media_prewarm();
    scope (exit)
        pw_media_prewarm_join();
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

    // Client-side window decorations for the GTK theme: the QML headerbar drives moves,
    // resizes and the window buttons through this. Exposed before the scene loads; its
    // target window is bound just after (the root ApplicationWindow only exists then).
    auto winCtl = newQObject!WindowCtl();
    engine.rootContext().setContextProperty("winCtl", cppq.QObject.wrap(qobjOf(winCtl)));

    bool failed;
    engine.connectObjectCreationFailed((const(QUrl)* u) {
        failed = true;
        stderr.writeln("QML: object creation failed (run with QT_FORCE_STDERR_LOGGING=1 for the reason)");
    });

    // Wear the system GTK/Adwaita theme through qml-css-engine: register its QML types and
    // engines (cssTheme / cssLayout context properties) before the QML loads, then load the
    // app's GTK-mapped stylesheet from beside the binary (a no-op if it isn't there).
    pw_css_register();
    // DSide wraps QObjects (class QObject : QtdObject); the real C++ pointer is engine.ptr(),
    // not the D wrapper's address.
    auto cssTheme = pw_css_init(engine.ptr());
    if (cssTheme !is null)
    {
        import std.file : thisExePath, exists, readText;
        import std.path : dirName, buildPath;
        import std.string : toStringz;
        import photowagon.ui.gtktheme : gtkThemeCss;

        // A photowagon.css beside the binary overrides everything (for experimenting with a
        // hand-written theme); otherwise we synthesise the live GTK/Adwaita palette so the
        // app wears the system theme out of the box.
        immutable cssFile = buildPath(thisExePath.dirName, "photowagon.css");
        try
        {
            immutable css = cssFile.exists ? readText(cssFile) : gtkThemeCss();
            pw_css_load_string(cssTheme, css.toStringz);
        }
        catch (Exception)
        {
        }
    }

    // ref const(QUrl) refuses an rvalue: keep it in a variable.
    auto url = QUrl("qrc:/Main.qml", QUrl.ParsingMode.TolerantMode);
    engine.load(url);

    auto roots = engine.rootObjects();
    // The QML root is the ApplicationWindow, itself a QWindow: wrap its C++ pointer so
    // WindowCtl can start system moves/resizes on it.
    if (roots.length > 0)
        winCtl.bind(QWindow.wrap(roots[0].ptr()));
    writeln("qml rootObjects = ", roots.length, failed ? " (creation failed)" : "");
    stdout.flush();
    if (roots.length == 0 || failed)
        return 1;

    immutable rc = QCoreApplication.exec();
    // Tear the QML scene down HERE, while Qt is whole. Left alone, the D runtime's final
    // collection finalizes the engine's wrapper after main returns, the wrapper deleteLater()s
    // it, and that deferred delete is then run by Qt's own static teardown inside exit() — after
    // QThreadStorage is gone — where ~QQuickWindow asks for the current GL context and dies
    // (SIGSEGV in QThreadStorageData::get, core of 2026-10-01 13:24). Deleted now, destroyed()
    // tells the wrapper, and its finalizer has nothing left to do.
    engine.deleteLater();
    QCoreApplication.sendPostedEvents(null, 52);   // 52 = QEvent::DeferredDelete
    return rc;
}
