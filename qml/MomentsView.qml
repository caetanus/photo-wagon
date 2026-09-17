import QtQuick
import QtQuick.Controls

// Moments: the timeline as events. One card per burst of photos taken close
// together — a birthday, an outing, an afternoon — newest first. Clicking one
// opens the photos of that moment.
Item {
    id: view
    required property QtObject theme
    required property QtObject icons
    /// [{key, title, subtitle, cover, count}]
    property var moments: []

    signal open(string key)

    Rectangle { anchors.fill: parent; color: theme.content }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: 12
        clip: true
        cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 264)))
        cellHeight: 230
        model: view.moments
        ScrollBar.vertical: ScrollBar { }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: (ev) => { const dy = ev.pixelDelta.y !== 0 ? ev.pixelDelta.y * 3 : ev.angleDelta.y / 120 * grid.cellHeight; grid.contentY = Math.max(0, Math.min(Math.max(0, grid.contentHeight - grid.height), grid.contentY - dy)); ev.accepted = true }
        }
        delegate: Item {
            id: card
            required property var modelData
            width: grid.cellWidth
            height: grid.cellHeight
            Rectangle {
                id: frame
                anchors.fill: parent
                anchors.margins: 6
                radius: 12
                color: theme.panel
                border.color: hover.hovered ? theme.accent : theme.separator
                border.width: hover.hovered ? 2 : 1
                clip: true
                Rectangle {
                    id: coverBg
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: parent.height - 58
                    color: theme.panelAlt
                    Image {
                        anchors.fill: parent
                        source: card.modelData.cover || ""
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 540; sourceSize.height: 380
                        asynchronous: true
                        smooth: true
                    }
                    Image {   // a stack glyph when there is no cover yet
                        visible: !card.modelData.cover
                        anchors.centerIn: parent
                        source: icons.tint(icons.photos, theme.muted)
                        sourceSize.width: 40; sourceSize.height: 40
                    }
                    Rectangle {   // photo count, bottom-right
                        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 8
                        radius: 4
                        color: Qt.rgba(0, 0, 0, 0.5)
                        width: cnt.implicitWidth + 12; height: cnt.implicitHeight + 6
                        Label {
                            id: cnt
                            anchors.centerIn: parent
                            text: card.modelData.count
                            color: "white"; font.pixelSize: 11; font.bold: true
                        }
                    }
                }
                Label {
                    id: title
                    anchors.top: coverBg.bottom
                    anchors.topMargin: 8
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 12; anchors.rightMargin: 12
                    text: card.modelData.title
                    color: theme.text
                    font.pixelSize: 14
                    font.bold: true
                    elide: Text.ElideRight
                }
                Label {
                    anchors.top: title.bottom
                    anchors.topMargin: 2
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 12; anchors.rightMargin: 12
                    text: card.modelData.subtitle || ""
                    color: theme.muted
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
            }
            HoverHandler { id: hover }
            TapHandler { onTapped: view.open(card.modelData.key) }
        }
    }

    Column {
        visible: view.moments.length === 0
        anchors.centerIn: parent
        spacing: 8
        width: Math.min(420, parent.width - 40)
        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: icons.tint(icons.photos, theme.muted)
            sourceSize.width: 48; sourceSize.height: 48
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "No moments yet"
            color: theme.text
            font.pixelSize: 16
            font.bold: true
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Photos taken around the same time are grouped into moments — an outing, a party, an afternoon. They show up here as your library grows."
            color: theme.muted
            font.pixelSize: 13
        }
    }
}
