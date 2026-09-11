import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Set Place": where the selected photos were taken. Typing suggests the
// library's own places first, then the world's cities; Enter keeps the text as
// typed (a farm, a beach — any name). "Clear" removes the place.
Dialog {
    id: dialog
    required property QtObject theme
    /// parsed library.placeSuggestions.places: [{place, country, own}]
    property var suggestions: []
    property var photoIds: []

    signal typing(string q)
    signal setPlace(string place, string country, var ids)

    title: photoIds.length + (photoIds.length === 1 ? " photo" : " photos")
    modal: true
    standardButtons: Dialog.Cancel

    onOpened: { nameField.text = ""; nameField.forceActiveFocus() }

    ColumnLayout {
        spacing: 10
        width: Math.max(300, dialog.availableWidth)
        Label { text: "Set Place"; font.bold: true; color: theme.text }
        RowLayout {
            TextField {
                id: nameField
                placeholderText: "City or place name"
                Layout.fillWidth: true
                onTextEdited: dialog.typing(text)
                onAccepted: dialog.apply(text.trim(), "")
            }
            Button { text: "Set"; enabled: nameField.text.trim().length > 0; onClicked: dialog.apply(nameField.text.trim(), "") }
        }
        ListView {
            visible: nameField.text.trim().length > 0 && dialog.suggestions.length > 0
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(240, dialog.suggestions.length * 34)
            clip: true
            model: dialog.suggestions
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width
                height: 34
                contentItem: RowLayout {
                    spacing: 8
                    Label { text: modelData.place; color: theme.text; font.pixelSize: 13; font.bold: modelData.own === true }
                    Label { text: modelData.country || ""; color: theme.muted; font.pixelSize: 12; Layout.fillWidth: true; elide: Text.ElideRight }
                    Label { visible: modelData.own === true; text: "in your library"; color: theme.muted; font.pixelSize: 11 }
                }
                onClicked: dialog.apply(modelData.place, modelData.country || "")
            }
        }
        Button {
            text: "Clear place"
            flat: true
            Layout.alignment: Qt.AlignLeft
            onClicked: dialog.apply("", "")
        }
    }

    function apply(place, country) {
        dialog.setPlace(place, country, dialog.photoIds)
        dialog.close()
    }
}
