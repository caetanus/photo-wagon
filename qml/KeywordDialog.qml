import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Add Tags": your own words on the selected photos, comma separated; the
// library's existing tags are one click away.
Dialog {
    id: dialog
    required property QtObject theme
    /// parsed library.keywords.keywords: [{keyword, count, cover}]
    property var keywords: []
    property var photoIds: []

    signal add(string text, var ids)

    title: photoIds.length + (photoIds.length === 1 ? " photo" : " photos")
    modal: true
    standardButtons: Dialog.Cancel

    onOpened: { field.text = ""; field.forceActiveFocus() }

    ColumnLayout {
        spacing: 10
        width: Math.max(300, dialog.availableWidth)
        Label { text: "Add Tags"; font.bold: true; color: theme.text }
        RowLayout {
            TextField {
                id: field
                placeholderText: "tag, another tag"
                Layout.fillWidth: true
                onAccepted: dialog.apply()
            }
            Button { text: "Add"; enabled: field.text.trim().length > 0; onClicked: dialog.apply() }
        }
        Label { visible: dialog.keywords.length > 0; text: "or one of yours:"; color: theme.muted; font.pixelSize: 12 }
        Flow {
            visible: dialog.keywords.length > 0
            Layout.fillWidth: true
            spacing: 6
            Repeater {
                model: dialog.keywords.slice(0, 30)
                Rectangle {
                    required property var modelData
                    height: 24
                    width: chipLabel.implicitWidth + 18
                    radius: 12
                    color: chipHover.hovered ? theme.selection : theme.hover
                    Label { id: chipLabel; anchors.centerIn: parent; text: modelData.keyword + "  " + modelData.count; color: theme.text; font.pixelSize: 12 }
                    HoverHandler { id: chipHover }
                    TapHandler { onTapped: { dialog.add(modelData.keyword, dialog.photoIds); dialog.close() } }
                }
            }
        }
    }

    function apply() {
        if (!field.text.trim().length) return
        dialog.add(field.text, dialog.photoIds)
        dialog.close()
    }
}
