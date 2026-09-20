import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Search — the first-class "find" surface. Free-text search runs against the
// paired computer's library (CLIP meaning + OCR text) when it's reachable; People
// and Browse-by-date work from what the phone already knows. Places / moods / a
// visual index of the phone's own photos land in a later pass (they need the phone
// bridge to forward those queries).
Item {
    id: view
    required property QtObject theme
    property var people: []
    property bool connected: false

    signal search(string q)
    signal openPerson(int id)
    signal browseDates()

    Flickable {
        anchors.fill: parent
        anchors.leftMargin: 14; anchors.rightMargin: 14
        contentHeight: col.implicitHeight + 20
        clip: true

        ColumnLayout {
            id: col
            width: parent.width
            spacing: 14

            // --- the query box -------------------------------------------------
            Rectangle {
                Layout.fillWidth: true
                Layout.topMargin: 10
                radius: height / 2
                implicitHeight: 46
                color: theme.panelAlt
                border.color: theme.border; border.width: 1
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16; anchors.rightMargin: 10
                    spacing: 8
                    Label { text: "⌕"; font.pixelSize: 18; color: theme.muted }
                    TextField {
                        id: q
                        Layout.fillWidth: true
                        placeholderText: "People, places, words in photos"
                        color: theme.text
                        background: null
                        font.pixelSize: 14
                        onAccepted: if (text.trim().length) view.search(text.trim())
                    }
                    ToolButton {
                        visible: q.text.length > 0
                        text: "✕"; font.pixelSize: 13
                        onClicked: q.clear()
                    }
                }
            }

            // honest scope note
            Rectangle {
                Layout.fillWidth: true
                radius: 10
                color: view.connected ? "transparent" : theme.panelAlt
                border.color: view.connected ? "transparent" : theme.border
                border.width: view.connected ? 0 : 1
                visible: !view.connected
                implicitHeight: note.implicitHeight + 18
                RowLayout {
                    anchors.fill: parent; anchors.margins: 10; spacing: 8
                    Rectangle { implicitWidth: 8; implicitHeight: 8; radius: 4; color: theme.warn }
                    Label {
                        id: note
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        font.pixelSize: 12
                        color: theme.muted
                        text: "Desktop offline — connect your computer to search by meaning and text. People and dates still work here."
                    }
                }
            }

            // --- people --------------------------------------------------------
            Label {
                text: "People"
                font.pixelSize: 13; font.weight: Font.Bold
                color: theme.text
                visible: view.people.length > 0
            }
            Flickable {
                Layout.fillWidth: true
                implicitHeight: 84
                contentWidth: peopleRow.implicitWidth
                flickableDirection: Flickable.HorizontalFlick
                clip: true
                visible: view.people.length > 0
                RowLayout {
                    id: peopleRow
                    height: parent.height
                    spacing: 14
                    Repeater {
                        model: view.people
                        delegate: ColumnLayout {
                            required property var modelData
                            spacing: 5
                            Rectangle {
                                Layout.alignment: Qt.AlignHCenter
                                implicitWidth: 54; implicitHeight: 54; radius: 27
                                color: theme.panelAlt
                                border.color: theme.border; border.width: 1
                                clip: true
                                Image {
                                    anchors.fill: parent
                                    source: modelData.cover || ""
                                    fillMode: Image.PreserveAspectCrop
                                    visible: !!modelData.cover
                                }
                                Label {
                                    anchors.centerIn: parent
                                    visible: !modelData.cover
                                    text: (modelData.name && modelData.name.length) ? modelData.name.charAt(0) : "?"
                                    color: theme.muted; font.pixelSize: 20; font.bold: true
                                }
                            }
                            Label {
                                Layout.alignment: Qt.AlignHCenter
                                Layout.maximumWidth: 62
                                text: (modelData.name && modelData.name.length) ? modelData.name : "Unnamed"
                                elide: Text.ElideRight
                                horizontalAlignment: Text.AlignHCenter
                                font.pixelSize: 11; color: theme.muted
                            }
                            TapHandler { onTapped: view.openPerson(modelData.id) }
                        }
                    }
                }
            }

            // --- browse shortcuts ---------------------------------------------
            Label {
                text: "Browse"
                font.pixelSize: 13; font.weight: Font.Bold; color: theme.text
                Layout.topMargin: 2
            }
            Rectangle {
                Layout.fillWidth: true
                radius: 12
                color: theme.panel
                border.color: theme.border; border.width: 1
                implicitHeight: 52
                RowLayout {
                    anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 12
                    Label { text: "By date"; Layout.fillWidth: true; color: theme.text; font.pixelSize: 14 }
                    Label { text: "›"; color: theme.muted; font.pixelSize: 18 }
                }
                TapHandler { onTapped: view.browseDates() }
            }
        }
    }
}
