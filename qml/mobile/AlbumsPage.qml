import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The computer's albums, as a grid of cards with cover thumbnails. Albums live on the
// paired computer; tapping opens one in Photos, the + creates one, long-press renames or
// deletes. All writes are forwarded to the computer (it owns the library).
Item {
    id: page
    required property QtObject theme
    property var albums: []
    property bool connected: false
    signal openAlbum(int id)
    signal createAlbum(string name)
    signal renameAlbum(int id, string name)
    signal deleteAlbum(int id)

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
                ? "Tap + to make one, or add photos to an album from a photo."
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
                    // cover: the album's first photo (coverUrl), over a tinted fallback tile
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        radius: 10
                        clip: true
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
                        Image {
                            anchors.fill: parent
                            source: card.modelData.coverUrl || ""
                            visible: status === Image.Ready
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.width: 320; sourceSize.height: 260
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
            TapHandler {
                id: tap
                onTapped: page.openAlbum(card.modelData.id)
                onLongPressed: { albumMenu.albumId = card.modelData.id; albumMenu.albumName = card.modelData.name; albumMenu.popup() }
            }
        }
    }

    // long-press menu on a card
    Menu {
        id: albumMenu
        property int albumId: 0
        property string albumName: ""
        Material.background: theme.panel
        MenuItem { text: "Rename"; onTriggered: { renameField.text = albumMenu.albumName; renameDialog.albumId = albumMenu.albumId; renameDialog.open() } }
        MenuItem { text: "Delete"; onTriggered: { deleteDialog.albumId = albumMenu.albumId; deleteDialog.albumName = albumMenu.albumName; deleteDialog.open() } }
    }

    // create — a floating +
    RoundButton {
        visible: page.connected
        text: "+"
        font.pixelSize: 26
        width: 56; height: 56
        anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 20
        Material.background: theme.accent
        Material.foreground: "#ffffff"
        onClicked: { createField.clear(); createDialog.open() }
    }

    component NameDialog: Dialog {
        modal: true
        anchors.centerIn: Overlay.overlay
        width: Math.min(340, page.width - 48)
        standardButtons: Dialog.Ok | Dialog.Cancel
        Material.background: theme.panel
    }

    NameDialog {
        id: createDialog
        title: "New album"
        onAccepted: if (createField.text.trim().length) page.createAlbum(createField.text.trim())
        contentItem: TextField {
            id: createField
            placeholderText: "Album name"
            color: theme.text
            onAccepted: createDialog.accept()
        }
    }

    NameDialog {
        id: renameDialog
        property int albumId: 0
        title: "Rename album"
        onAccepted: if (renameField.text.trim().length) page.renameAlbum(albumId, renameField.text.trim())
        contentItem: TextField {
            id: renameField
            color: theme.text
            onAccepted: renameDialog.accept()
        }
    }

    Dialog {
        id: deleteDialog
        property int albumId: 0
        property string albumName: ""
        modal: true
        anchors.centerIn: Overlay.overlay
        width: Math.min(340, page.width - 48)
        title: "Delete album?"
        standardButtons: Dialog.Yes | Dialog.No
        Material.background: theme.panel
        onAccepted: page.deleteAlbum(albumId)
        contentItem: Label {
            width: Math.min(280, page.width - 90)
            text: "“" + deleteDialog.albumName + "” will be removed. The photos stay in your library."
            color: theme.muted; font.pixelSize: 13; wrapMode: Text.WordWrap
        }
    }
}
