// css_shim.cpp — a C surface over qml-css-engine (~/lab/qml-css-engine), so the D/DSide
// app can register its QML types, create the CssTheme + CssLayoutEngine, expose them as
// the `cssTheme` / `cssLayout` context properties, and load a stylesheet. The engine is a
// C++/Qt library with no D binding; everything crosses through this shim as plain C.
#include "qmlcss/QMLCss.h"
#include "qmlcss/csstheme.h"
#include "qmlcss/csslayout.h"

#include <QQmlEngine>
#include <QQmlContext>
#include <QString>

extern "C" {

// Register the qmlcss C++ types (CssRect, CssText, …) so `import qmlcss` resolves.
// Safe to call once, before the QML is loaded.
void pw_css_register()
{
    QmlCss::registerTypes();
}

// Create the theme + layout engines, bind them as the `cssTheme` / `cssLayout` context
// properties (the exact names the qmlcss components expect), and return the CssTheme* so
// the caller can load/reload CSS later. `enginePtr` is a QQmlEngine* (a
// QQmlApplicationEngine* is one) — the DSide `engine` object's C++ pointer.
void* pw_css_init(void* enginePtr)
{
    QQmlEngine* engine = reinterpret_cast<QQmlEngine*>(enginePtr);
    if (!engine)
        return nullptr;
    CssTheme* theme = new CssTheme(engine);          // parented to the engine
    CssLayoutEngine* layout = new CssLayoutEngine(theme, engine);
    engine->rootContext()->setContextProperty(QStringLiteral("cssTheme"), theme);
    engine->rootContext()->setContextProperty(QStringLiteral("cssLayout"), layout);
    return theme;
}

// Load one or more ':'-separated stylesheet paths as one cascade (later wins). Files are
// watched for hot reload by the engine itself.
void pw_css_load(void* themePtr, const char* path)
{
    CssTheme* theme = reinterpret_cast<CssTheme*>(themePtr);
    if (theme && path)
        theme->load(QString::fromUtf8(path));
}

// Replace the current cascade with a raw CSS string (used for a generated / in-memory
// GTK palette).
void pw_css_load_string(void* themePtr, const char* css)
{
    CssTheme* theme = reinterpret_cast<CssTheme*>(themePtr);
    if (theme && css)
        theme->loadFromString(QString::fromUtf8(css));
}

// Tell the engine the viewport size (for @media / vw / vh). Call on window resize.
void pw_css_viewport(void* themePtr, double w, double h)
{
    CssTheme* theme = reinterpret_cast<CssTheme*>(themePtr);
    if (theme)
        theme->setViewport(w, h);
}

}
