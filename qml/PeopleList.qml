import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// People found in the library: a face crop, a name (editable), a count.
// Clicking filters the grid to that person; clicking again clears it.
Rectangle {
    id: panel
    required property QtObject theme
    property var people: []
    property int selectedPerson: 0

    signal picked(int personId)
    signal renamed(int personId, string name)
    signal merged(int personId, int into)

    color: theme.panel
    border.color: theme.border

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 6
        spacing: 4

        Label {
            text: "People"
            font.bold: true
            color: theme.muted
            font.pixelSize: 12
            Layout.leftMargin: 6
        }

        ListView {
            id: list
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 2
            model: panel.people
            ScrollBar.vertical: ScrollBar { }

            delegate: Rectangle {
                id: row
                required property var modelData
                required property int index
                width: list.width
                height: 48
                radius: 4
                color: modelData.id === panel.selectedPerson ? theme.accent
                     : hover.hovered ? theme.panelAlt : "transparent"
                HoverHandler { id: hover }

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    spacing: 8
                    Rectangle {
                        width: 40; height: 40; radius: 20
                        color: theme.panelAlt
                        clip: true
                        Image {
                            anchors.fill: parent
                            source: row.modelData.coverUrl || ""
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            sourceSize.width: 80
                            sourceSize.height: 80
                            layer.enabled: true
                            layer.effect: null
                        }
                        TapHandler { onTapped: panel.picked(row.modelData.id) }
                    }
                    ColumnLayout {
                        spacing: 0
                        Layout.fillWidth: true
                        Label {
                            visible: !editor.visible
                            text: row.modelData.name || "Unnamed"
                            font.italic: !row.modelData.name
                            color: row.modelData.id === panel.selectedPerson ? "#ffffff" : theme.text
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                            TapHandler {
                                onTapped: panel.picked(row.modelData.id)
                                onDoubleTapped: { editor.text = row.modelData.name || ""; editor.visible = true; editor.forceActiveFocus() }
                            }
                        }
                        TextField {
                            id: editor
                            visible: false
                            placeholderText: "Name"
                            Layout.fillWidth: true
                            onAccepted: { panel.renamed(row.modelData.id, text); visible = false }
                            onActiveFocusChanged: if (!activeFocus) visible = false
                            Keys.onEscapePressed: visible = false
                        }
                        Label {
                            text: row.modelData.faces + (row.modelData.faces === 1 ? " photo" : " photos")
                            color: row.modelData.id === panel.selectedPerson ? "#e0ecff" : theme.muted
                            font.pixelSize: 11
                        }
                    }
                    ToolButton {
                        text: "✎"
                        implicitWidth: 28
                        onClicked: { editor.text = row.modelData.name || ""; editor.visible = true; editor.forceActiveFocus() }
                    }
                }
            }
        }

        Label {
            visible: list.count === 0
            text: "No faces found yet."
            color: theme.muted
            font.pixelSize: 12
            Layout.leftMargin: 6
        }
    }
}
