import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Add to Album": an existing album or a new one, for the selected photos.
Dialog {
    id: dialog
    required property QtObject theme
    property var albums: []
    property var photoIds: []

    signal addTo(int albumId, var ids)
    signal createNew(string name, var ids)

    title: photoIds.length + (photoIds.length === 1 ? " photo" : " photos")
    modal: true
    standardButtons: Dialog.Cancel

    ColumnLayout {
        spacing: 10
        width: Math.max(300, dialog.availableWidth)
        Label { text: "Add to Album"; font.bold: true; color: theme.text }
        ListView {
            visible: dialog.albums.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(220, dialog.albums.length * 34)
            clip: true
            model: dialog.albums
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width
                height: 34
                text: modelData.name + "  ·  " + modelData.photos
                onClicked: { dialog.addTo(modelData.id, dialog.photoIds); dialog.close() }
            }
        }
        Label { text: dialog.albums.length ? "or a new album:" : "New album:"; color: theme.muted; font.pixelSize: 12 }
        RowLayout {
            TextField {
                id: nameField
                placeholderText: "Album name"
                Layout.fillWidth: true
                onAccepted: create()
            }
            Button { text: "Create"; enabled: nameField.text.trim().length > 0; onClicked: create() }
        }
    }

    function create() {
        if (!nameField.text.trim().length) return
        dialog.createNew(nameField.text.trim(), dialog.photoIds)
        nameField.text = ""
        dialog.close()
    }
}
