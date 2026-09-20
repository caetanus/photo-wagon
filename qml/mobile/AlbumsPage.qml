import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The computer's albums, as a grid of cards. Albums live on the paired computer,
// so the list is empty until one is connected. Tapping opens the album in Photos.
Item {
    id: page
    required property QtObject theme
    property var albums: []
    property bool connected: false
    signal openAlbum(int id)

    Rectangle { anchors.fill: parent; color: theme.bg }

    // empty state
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(300, parent.width - 48)
        spacing: 10
        visible: page.albums.length === 0
        Label {
            text: page.connected ? "No albums yet" : "No computer paired"
            color: theme.text; font.pixelSize: 17; font.weight: Font.DemiBold
            Layout.alignment: Qt.AlignHCenter
        }
        Label {
            text: page.connected
                ? "Albums you make on the computer show up here."
                : "Pair with the computer (Computer tab) to see its albums."
            color: theme.muted; font.pixelSize: 13; wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter; Layout.fillWidth: true
        }
    }

    GridView {
        id: view
        anchors.fill: parent
        anchors.margins: 12
        visible: page.albums.length > 0
        clip: true
        cellWidth: Math.floor(width / Math.max(2, Math.floor(width / 210)))
        cellHeight: cellWidth * 0.82
        model: page.albums
        ScrollBar.vertical: ScrollBar { }
        delegate: Item {
            id: card
            required property var modelData
            width: view.cellWidth
            height: view.cellHeight
            Rectangle {
                anchors.fill: parent
                anchors.margins: 6
                radius: 14
                color: card.pressedNow ? theme.panelAlt : theme.panel
                border.color: theme.border
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 14
                    spacing: 0
                    // a soft cover placeholder (albums carry no cover thumbnail here)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 10
                        gradient: Gradient {
                            GradientStop { position: 0.0; color: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.22) }
                            GradientStop { position: 1.0; color: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.08) }
                        }
                        Label {
                            anchors.centerIn: parent
                            text: card.modelData.name.charAt(0).toUpperCase()
                            font.pixelSize: 34; font.weight: Font.DemiBold
                            color: Qt.rgba(theme.accent.r, theme.accent.g, theme.accent.b, 0.8)
                        }
                    }
                    Label {
                        Layout.fillWidth: true
                        Layout.topMargin: 10
                        text: card.modelData.name
                        color: theme.text; font.pixelSize: 14; font.weight: Font.DemiBold
                        elide: Text.ElideRight
                    }
                    Label {
                        text: card.modelData.photos + (card.modelData.photos === 1 ? " photo" : " photos")
                        color: theme.muted; font.pixelSize: 12
                    }
                }
            }
            property bool pressedNow: tap.pressed
            TapHandler { id: tap; onTapped: page.openAlbum(card.modelData.id) }
        }
    }
}
