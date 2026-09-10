import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Is this the same person?" — shown after a naming when someone already known
// looks alike (and was never in a photo together). Merge, or say they differ.
Popup {
    id: card
    required property QtObject theme
    required property QtObject icons
    /// parsed library.suggestion: {person, candidates:[…]}
    property var data: ({})
    property int which: 0
    readonly property var person: data.person || null
    readonly property var candidate: data.candidates && which < data.candidates.length ? data.candidates[which] : null

    signal merge(int from, int into)
    signal different(int a, int b)

    modal: false
    focus: false
    closePolicy: Popup.NoAutoClose
    padding: 16
    width: 420
    background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 12 }

    onDataChanged: which = 0

    component Portrait: Item {
        property var p
        width: 84; height: 108
        Item {
            width: 84; height: 84
            Image { anchors.fill: parent; source: parent.parent.p && parent.parent.p.coverUrl ? parent.parent.p.coverUrl : ""; fillMode: Image.PreserveAspectCrop; sourceSize.width: 168; sourceSize.height: 168; asynchronous: true }
            Image { anchors.fill: parent; source: icons.ringMask(theme.panel); sourceSize.width: 84; sourceSize.height: 84 }
            Rectangle { anchors.fill: parent; radius: 42; color: "transparent"; border.color: theme.separator }
        }
        Label {
            anchors.top: parent.top; anchors.topMargin: 88
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: parent.p ? (parent.p.name || "Unnamed") + "\n" + parent.p.faces + (parent.p.faces === 1 ? " photo" : " photos") : ""
            color: theme.text
            font.pixelSize: 11
            elide: Text.ElideRight
        }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12
        Label {
            text: card.candidate ? "Is " + (card.person ? card.person.name : "this") + " the same person as "
                                  + (card.candidate.name || "this unnamed person") + "?" : ""
            color: theme.text
            font.pixelSize: 14
            font.bold: true
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        RowLayout {
            spacing: 24
            Layout.alignment: Qt.AlignHCenter
            Portrait { p: card.person }
            Label { text: "="; color: theme.muted; font.pixelSize: 24 }
            Portrait { p: card.candidate }
        }
        Label {
            visible: card.data.candidates && card.data.candidates.length > 1
            text: card.data.candidates ? (card.which + 1) + " of " + card.data.candidates.length + " look-alikes" : ""
            color: theme.muted
            font.pixelSize: 11
            Layout.alignment: Qt.AlignHCenter
        }
        RowLayout {
            Button {
                text: "Not the same"
                flat: true
                onClicked: {
                    if (card.person && card.candidate) card.different(card.person.id, card.candidate.id)
                    if (card.data.candidates && card.which + 1 < card.data.candidates.length) card.which++
                    else card.close()
                }
            }
            Item { Layout.fillWidth: true }
            Button {
                text: "Merge"
                highlighted: true
                onClicked: {
                    if (card.person && card.candidate) card.merge(card.candidate.id, card.person.id)
                    card.close()
                }
            }
        }
    }
}
