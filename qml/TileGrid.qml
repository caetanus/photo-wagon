import QtQuick
import QtQuick.Controls

// Years and Months: one large card per period with its newest photo, the
// period name and the count. Clicking drills in.
Item {
    id: tiles
    required property QtObject theme
    /// [{label, sublabel, cover, year, month}]
    property var model: []
    property int tileWidth: 320
    property int tileHeight: 220

    signal pick(int year, int month)

    Rectangle { anchors.fill: parent; color: theme.content }

    GridView {
        id: view
        anchors.fill: parent
        anchors.margins: 12
        clip: true
        cellWidth: Math.floor(width / Math.max(1, Math.floor(width / (tiles.tileWidth + 12))))
        cellHeight: tiles.tileHeight + 12
        model: tiles.model
        ScrollBar.vertical: ScrollBar { }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse
            onWheel: (ev) => { view.contentY = Math.max(0, Math.min(Math.max(0, view.contentHeight - view.height), view.contentY - ev.angleDelta.y * 3.2)); ev.accepted = true }
        }
        delegate: Item {
            id: card
            required property var modelData
            width: view.cellWidth
            height: view.cellHeight
            Rectangle {
                id: frame
                anchors.fill: parent
                anchors.margins: 6
                radius: 10
                color: theme.tile
                clip: true
                Image {
                    anchors.fill: parent
                    source: card.modelData.cover || ""
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 640
                    sourceSize.height: 640
                    smooth: true
                }
                // gradient for legibility
                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    height: parent.height * 0.55
                    gradient: Gradient {
                        GradientStop { position: 0.0; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, 0.55) }
                    }
                }
                Column {
                    anchors.left: parent.left
                    anchors.bottom: parent.bottom
                    anchors.margins: 14
                    spacing: 2
                    Label { text: card.modelData.label; color: "white"; font.pixelSize: 20; font.bold: true }
                    Label { text: card.modelData.sublabel; color: Qt.rgba(1, 1, 1, 0.85); font.pixelSize: 12 }
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 10
                    color: "transparent"
                    border.color: hover.hovered ? theme.accent : Qt.rgba(0, 0, 0, 0.08)
                    border.width: hover.hovered ? 2 : 1
                }
                HoverHandler { id: hover }
                TapHandler { onTapped: tiles.pick(card.modelData.year, card.modelData.month) }
            }
        }
    }

    Label {
        anchors.centerIn: parent
        visible: tiles.model.length === 0
        text: "No Photos"
        color: theme.muted
        font.pixelSize: 22
        font.bold: true
    }
}
