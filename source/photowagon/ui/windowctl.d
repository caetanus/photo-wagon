// WindowCtl — a tiny @QObject the QML uses to drive client-side window decorations (CSD).
// On GNOME (and wlroots), a native GTK app draws its OWN title bar: the compositor adds no
// frame, so the app's headerbar carries the window controls and must start interactive moves
// and resizes itself. Qt exposes QWindow::startSystemMove()/startSystemResize(), but those are
// plain C++ members — not Q_INVOKABLE — so QML can't call them. This bridges them: app.d binds
// it to the root ApplicationWindow's QWindow after the scene loads, and Main.qml calls the
// slots from the headerbar (drag to move, edge grips to resize, the window buttons).
module photowagon.ui.windowctl;

import qtmoc;
import qt.quick.qwindow : QWindow;
import qt.quick.windowstate : WindowState;

@QObject class WindowCtl
{
    private QWindow win;

    /// Bound once, after the QML root window exists (see app.d).
    void bind(QWindow w) { win = w; }

    /// Hand the current press off to the compositor as an interactive move (frameless drag).
    @Slot void startMove()
    {
        if (win !is null)
            win.startSystemMove();
    }

    /// Interactive resize from a window edge/corner. `edges` is a Qt::Edges bitmask
    /// (Top=1, Left=2, Right=4, Bottom=8; corners are ORed, e.g. bottom-right = 12).
    @Slot void startResize(int edges)
    {
        if (win !is null)
            win.startSystemResize(edges);
    }

    @Slot void minimize()
    {
        if (win !is null)
            win.showMinimized();
    }

    /// Toggle maximize/restore — the headerbar double-click and the maximize button.
    @Slot void toggleMaximize()
    {
        if (win is null)
            return;
        if (win.windowStates() & WindowState.WindowMaximized)
            win.setWindowState(WindowState.WindowNoState);
        else
            win.setWindowState(WindowState.WindowMaximized);
    }

    @Slot void closeWindow()
    {
        if (win !is null)
            win.close();
    }
}
