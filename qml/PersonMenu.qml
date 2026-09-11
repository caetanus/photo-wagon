import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Right-click on a person (sidebar, People page): rename, or remove from People.
Menu {
    id: menu
    required property QtObject theme
    property var person: null   // {id, name, faces}

    signal rename(int personId, string name)
    signal remove(int personId)
    signal open(int personId)

    MenuItem { text: "Show Photos"; onTriggered: if (menu.person) menu.open(menu.person.id) }
    MenuItem { text: "Rename…"; onTriggered: { renamer.open() } }
    MenuSeparator { }
    MenuItem { text: "Remove from People"; onTriggered: { removeAsk.open() } }

    Popup {
        id: renamer
        parent: Overlay.overlay
        modal: true
        anchors.centerIn: parent
        width: 320
        padding: 16
        background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 10 }
        onOpened: { field.text = menu.person ? (menu.person.name || "") : ""; field.forceActiveFocus(); field.selectAll() }
        ColumnLayout {
            anchors.fill: parent
            spacing: 10
            Label { text: menu.person ? "Rename " + (menu.person.name || "this person") : ""; font.bold: true; color: theme.text }
            TextField {
                id: field
                Layout.fillWidth: true
                placeholderText: "Name"
                onAccepted: { if (text.trim().length && menu.person) menu.rename(menu.person.id, text.trim()); renamer.close() }
            }
            Label { text: "A name that already exists merges the two people."; color: theme.muted; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; onClicked: renamer.close() }
                Button { text: "Rename"; highlighted: true; enabled: field.text.trim().length > 0; onClicked: field.accepted() }
            }
        }
    }

    Popup {
        id: removeAsk
        parent: Overlay.overlay
        modal: true
        anchors.centerIn: parent
        width: 360
        padding: 16
        background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 10 }
        ColumnLayout {
            anchors.fill: parent
            spacing: 12
            Label {
                Layout.fillWidth: true
                text: menu.person ? "Remove " + (menu.person.name || "this person") + " from People?" : ""
                font.bold: true; color: theme.text; wrapMode: Text.WordWrap
            }
            Label {
                Layout.fillWidth: true
                text: menu.person ? "The " + menu.person.faces + " faces stay in the photos, unnamed. Naming one again brings the person back." : ""
                color: theme.muted; font.pixelSize: 12; wrapMode: Text.WordWrap
            }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; onClicked: removeAsk.close() }
                Button { text: "Remove"; highlighted: true; onClicked: { if (menu.person) menu.remove(menu.person.id); removeAsk.close() } }
            }
        }
    }
}
