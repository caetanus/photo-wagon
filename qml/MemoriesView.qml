import QtQuick
import QtQuick.Controls

// Memories: a strip of collections the app curates for you — "On This Day", the
// places and people you photograph most, recurring moods, a throwback to this
// month a few years back. Clicking one opens its photos.
Item {
    id: view
    required property QtObject theme
    required property QtObject icons
    /// [{key, kind, title, subtitle, cover, count}]
    property var memories: []

    signal open(string key)

    Rectangle { anchors.fill: parent; color: theme.content }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: 12
        clip: true
        cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 272)))
        cellHeight: 236
        model: view.memories
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
                Rectangle {   // a soft ground behind the cover, for cards without one
                    id: coverBg
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: parent.height - 64
                    color: theme.panelAlt
                    Image {
                        id: cover
                        anchors.fill: parent
                        source: card.modelData.cover || ""
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 540; sourceSize.height: 380
                        asynchronous: true
                        smooth: true
                    }
                    Label {   // fallback glyph when there is no cover yet
                        visible: !card.modelData.cover
                        anchors.centerIn: parent
                        text: ({ onthisday: "🗓", throwback: "⏳", place: "📍", person: "👤", scene: "🏷", holiday: "🎉" }[card.modelData.kind]) || "★"
                        font.pixelSize: 34
                        opacity: 0.5
                    }
                    // a small kind tag in the corner
                    Rectangle {
                        anchors.left: parent.left; anchors.top: parent.top; anchors.margins: 8
                        visible: !!card.modelData.kind
                        radius: 4
                        color: Qt.rgba(0, 0, 0, 0.5)
                        width: kindLabel.implicitWidth + 12; height: kindLabel.implicitHeight + 6
                        Label {
                            id: kindLabel
                            anchors.centerIn: parent
                            text: ({ onthisday: "On this day", throwback: "Throwback", place: "Place", person: "Person", scene: "Moment", holiday: "Holiday" }[card.modelData.kind]) || ""
                            color: "white"; font.pixelSize: 10; font.bold: true
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
                    font.pixelSize: 15
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

    // Nothing curated yet: say where memories come from.
    Column {
        visible: view.memories.length === 0
        anchors.centerIn: parent
        spacing: 8
        width: Math.min(420, parent.width - 40)
        Label {
            anchors.horizontalCenter: parent.horizontalCenter
            text: "✨"
            font.pixelSize: 44
            opacity: 0.6
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "No memories yet"
            color: theme.text
            font.pixelSize: 16
            font.bold: true
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "As your library grows, Photo Wagon gathers photos from the same day in past years, the places and people you photograph most, and recurring moments — they show up here."
            color: theme.muted
            font.pixelSize: 13
        }
    }
}
