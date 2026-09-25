import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// "Add to album": the computer's albums, or a new one, for a set of photos (a selection
// on the grid, or the one in the viewer). Albums live on the computer, so offline the
// dialog says so and offers the connection instead of an empty list.
Dialog {
    id: dialog
    required property QtObject theme
    property var albums: []
    property bool connected: false
    property var photoIds: []

    signal pickAlbum(int albumId, var ids)
    signal newAlbum(string name, var ids)
    signal connectComputer()

    function openFor(ids) { photoIds = ids; nameField.text = ""; creating = false; open() }
    property bool creating: false

    parent: Overlay.overlay
    anchors.centerIn: parent
    width: Math.min(380, (parent ? parent.width : 380) - 32)
    modal: true
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.62) }
    Material.background: theme.panel
    padding: 16
    title: dialog.photoIds.length === 1 ? "Add to album" : "Add " + dialog.photoIds.length + " photos to album"

    contentItem: ColumnLayout {
        spacing: 8

        Label {
            visible: !dialog.connected
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: theme.muted; font.pixelSize: 13
            text: "Albums live on your computer. Connect it to add photos to one."
        }
        Button {
            visible: !dialog.connected
            text: "Connect your computer"
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            Material.background: theme.accent
            Material.foreground: "#ffffff"
            onClicked: { dialog.close(); dialog.connectComputer() }
        }

        ListView {
            id: list
            visible: dialog.connected && !dialog.creating
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, 320)
            clip: true
            model: dialog.albums
            ScrollBar.vertical: ScrollBar { }
            delegate: ItemDelegate {
                required property var modelData
                width: list.width
                implicitHeight: 52
                contentItem: RowLayout {
                    spacing: 10
                    Label {
                        Layout.fillWidth: true
                        text: modelData.name
                        elide: Text.ElideRight
                        color: theme.text; font.pixelSize: 15
                    }
                    Label {
                        text: modelData.count !== undefined ? String(modelData.count) : ""
                        color: theme.muted; font.pixelSize: 13
                    }
                }
                onClicked: { dialog.close(); dialog.pickAlbum(modelData.id, dialog.photoIds) }
            }
        }
        ItemDelegate {
            visible: dialog.connected && !dialog.creating
            Layout.fillWidth: true
            implicitHeight: 52
            contentItem: Label {
                text: "+  New album…"
                color: theme.accent; font.pixelSize: 15; font.weight: Font.DemiBold
            }
            onClicked: { dialog.creating = true; nameField.forceActiveFocus() }
        }

        TextField {
            id: nameField
            visible: dialog.connected && dialog.creating
            Layout.fillWidth: true
            placeholderText: "Album name"
            color: theme.text
            onAccepted: create.clicked()
        }
        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button {
                text: "Cancel"
                flat: true
                Material.foreground: theme.accent
                onClicked: dialog.creating ? dialog.creating = false : dialog.close()
            }
            Button {
                id: create
                visible: dialog.connected && dialog.creating
                enabled: nameField.text.trim().length > 0
                text: "Create"
                Material.background: theme.accent
                Material.foreground: "#ffffff"
                onClicked: {
                    Qt.inputMethod.hide()
                    dialog.close()
                    dialog.newAlbum(nameField.text.trim(), dialog.photoIds)
                }
            }
        }
    }
}
