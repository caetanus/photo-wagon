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
    Icons { id: icons }

    signal search(string q)
    signal openPerson(int id)
    signal browseDates()
    signal openKind(string kind)      // "screenshot" | "video"
    signal openFavorites()

    // one suggestion of the Browse list: an icon, a name, where it leads
    component BrowseRow: Rectangle {
        id: br
        required property string icon_
        required property string label
        property string note: ""
        signal tapped()
        Layout.fillWidth: true
        implicitHeight: 52
        color: brTap.pressed ? theme.panelAlt : "transparent"
        radius: 10
        RowLayout {
            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
            spacing: 14
            Image { source: icons.tint(br.icon_, theme.muted); sourceSize.width: 20; sourceSize.height: 20 }
            Label { text: br.label; Layout.fillWidth: true; color: theme.text; font.pixelSize: 15 }
            Label { text: br.note; visible: text.length > 0; color: theme.muted; font.pixelSize: 12 }
            Label { text: "›"; color: theme.muted; font.pixelSize: 18 }
        }
        TapHandler { id: brTap; onTapped: br.tapped() }
    }

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
                    Image {
                        source: icons.tint(icons.search, theme.muted)
                        sourceSize.width: 18; sourceSize.height: 18
                    }
                    TextField {
                        id: q
                        Layout.fillWidth: true
                        placeholderText: "People, places, words in photos"
                        color: theme.text
                        background: null
                        font.pixelSize: 14
                        onAccepted: if (text.trim().length) {
                            Qt.inputMethod.hide()   // the results take the whole screen
                            focus = false
                            view.search(text.trim())
                        }
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
                        text: "Computer offline — search looks only at this phone's file and folder names. Connect your computer to search by what's in the photos."
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
                                    source: modelData.coverUrl || ""
                                    fillMode: Image.PreserveAspectCrop
                                    visible: !!modelData.coverUrl
                                }
                                Image {
                                    anchors.fill: parent
                                    source: icons.ringMask(theme.bg)
                                    visible: !!modelData.coverUrl
                                }
                                Label {
                                    anchors.centerIn: parent
                                    visible: !modelData.coverUrl
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
                implicitHeight: browseCol.implicitHeight + 8
                ColumnLayout {
                    id: browseCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 4
                    spacing: 0
                    BrowseRow { icon_: icons.screenshot; label: "Screenshots"; onTapped: view.openKind("screenshot") }
                    BrowseRow { icon_: icons.video; label: "Videos"; onTapped: view.openKind("video") }
                    BrowseRow {
                        icon_: icons.heart; label: "Favorites"
                        note: view.connected ? "" : "on the computer"
                        onTapped: view.openFavorites()
                    }
                    BrowseRow { icon_: icons.memories; label: "By date"; onTapped: view.browseDates() }
                }
            }
        }
    }
}
