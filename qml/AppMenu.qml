import QtQuick
import QtQuick.Controls
import QtQuick.Effects

// The app's one menu look: a rounded, softly shadowed surface with a themed palette, so
// every context menu / dropdown matches the window instead of the plain Basic style. Items
// are AppMenuItem (rich rows). Pass `theme`; nested menus inherit it.
Menu {
    id: menu
    property QtObject theme      // set by the instantiator; guarded below so a late/absent
    implicitWidth: 236           // assignment falls back to dark defaults instead of crashing
    topPadding: 6
    bottomPadding: 6
    overlap: 0
    margins: 10   // room around the popup so the drop shadow is not clipped

    // null-safe views: the initial binding pass runs before `theme` is assigned by the
    // instantiator, so guard every access with a sane fallback instead of throwing.
    readonly property color _win: theme ? theme.window : "#1c1c1e"
    readonly property color _sep: theme ? theme.separator : "#3a3a3c"
    readonly property color _txt: theme ? theme.text : "#f5f5f7"
    readonly property color _hov: theme ? theme.hover : "#2e2e30"

    palette.text: _txt
    palette.windowText: _txt
    palette.buttonText: _txt
    palette.brightText: _txt
    palette.highlight: _hov
    palette.highlightedText: _txt
    palette.mid: _sep
    palette.midlight: _sep
    palette.light: _hov
    palette.button: _win
    palette.window: _win

    background: Rectangle {
        implicitWidth: 236
        radius: 11
        color: menu._win
        border.color: menu._sep
        border.width: 1
        layer.enabled: true
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.33)
            shadowVerticalOffset: 5
            shadowBlur: 0.7
            shadowOpacity: 0.9
        }
    }
}
