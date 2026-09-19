import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Add to Album": an existing album or a new one, for the selected photos.
// When those photos share a calendar day with others, it offers to add the rest
// of that day too — an album is often an event, so the day usually belongs together.
Dialog {
    id: dialog
    required property QtObject theme
    property var albums: []
    property var photoIds: []
    property var dayMates: []             // [{id, thumbUrl, …}] — photos from the same day
    property bool includeDayMates: false

    signal addTo(int albumId, var ids)
    signal createNew(string name, var ids)

    // The ids to actually add: the selection, plus the same-day photos when opted in.
    function effectiveIds() {
        if (!dialog.includeDayMates || !dialog.dayMates.length) return dialog.photoIds
        return dialog.photoIds.concat(dialog.dayMates.map(function (m) { return m.id }))
    }

    title: photoIds.length + (photoIds.length === 1 ? " photo" : " photos")
    modal: true
    standardButtons: Dialog.Cancel
    onOpened: dialog.includeDayMates = false

    ColumnLayout {
        spacing: 10
        width: Math.max(300, dialog.availableWidth)

        // ---- same-day suggestion --------------------------------------------------
        ColumnLayout {
            visible: dialog.dayMates.length > 0
            Layout.fillWidth: true
            spacing: 6
            CheckBox {
                id: dayMateBox
                checked: dialog.includeDayMates
                onToggled: dialog.includeDayMates = checked
                text: "Also add " + dialog.dayMates.length
                      + (dialog.dayMates.length === 1 ? " more photo" : " more photos") + " from the same day"
                contentItem: Label {
                    text: dayMateBox.text
                    color: theme.text
                    font.pixelSize: 13
                    wrapMode: Text.WordWrap
                    leftPadding: dayMateBox.indicator.width + 6
                    verticalAlignment: Text.AlignVCenter
                }
            }
            ListView {
                Layout.fillWidth: true
                Layout.preferredHeight: 56
                orientation: ListView.Horizontal
                clip: true
                spacing: 4
                model: dialog.dayMates
                delegate: Rectangle {
                    required property var modelData
                    width: 54; height: 54; radius: 4
                    color: theme.tile
                    border.color: dialog.includeDayMates ? theme.accent : theme.separator
                    border.width: dialog.includeDayMates ? 2 : 1
                    Image {
                        anchors.fill: parent
                        anchors.margins: 2
                        source: modelData.thumbUrl || ""
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 108
                        sourceSize.height: 108
                        asynchronous: true
                        opacity: dialog.includeDayMates ? 1 : 0.5
                    }
                }
            }
            Rectangle { Layout.fillWidth: true; Layout.preferredHeight: 1; color: theme.separator }
        }

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
                onClicked: { dialog.addTo(modelData.id, dialog.effectiveIds()); dialog.close() }
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
        dialog.createNew(nameField.text.trim(), dialog.effectiveIds())
        nameField.text = ""
        dialog.close()
    }
}
