import QtQuick
import QtQuick.Controls

// One themed menu row: comfortable height, a rounded hover pill inset from the edges, an
// inline checkmark for checkable items, a chevron for submenus, and a right-aligned
// shortcut hint. Colours come from the enclosing AppMenu's palette — no per-item theme.
MenuItem {
    id: item
    implicitHeight: 30
    leftPadding: 12
    rightPadding: 12

    readonly property color _fg: item.enabled
        ? palette.buttonText
        : Qt.rgba(palette.buttonText.r, palette.buttonText.g, palette.buttonText.b, 0.38)

    indicator: Item {}   // the check is drawn inline in the label instead

    contentItem: Item {
        implicitHeight: 20
        Text {
            id: label
            anchors.left: parent.left
            anchors.right: hint.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            text: (item.checkable && item.checked ? "✓   " : "") + item.text
            color: item._fg
            font.pixelSize: 13
            elide: Text.ElideRight
        }
        Text {
            id: hint
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: item.subMenu ? "›"
                : (item.action && typeof item.action.shortcut === "string" ? item.action.shortcut : "")
            color: Qt.rgba(palette.buttonText.r, palette.buttonText.g, palette.buttonText.b, item.subMenu ? 0.6 : 0.42)
            font.pixelSize: item.subMenu ? 16 : 12
        }
    }

    background: Rectangle {
        anchors.fill: parent
        anchors.leftMargin: 5
        anchors.rightMargin: 5
        anchors.topMargin: 1
        anchors.bottomMargin: 1
        radius: 6
        color: item.highlighted ? palette.highlight : "transparent"
    }
}
