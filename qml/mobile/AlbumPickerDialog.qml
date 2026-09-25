import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// "Add to album": a sheet from the bottom with the computer's albums (cover, name, count),
// "New album" first, and a search once there are many — for a set of photos (a selection on
// the grid, or the one in the viewer). Albums live on the computer, so offline the sheet
// says so and offers the connection instead of an empty list.
Drawer {
    id: sheet
    required property QtObject theme
    property var albums: []
    property bool connected: false
    property var photoIds: []
    property bool creating: false

    signal pickAlbum(int albumId, var ids)
    signal newAlbum(string name, var ids)
    signal connectComputer()

    function openFor(ids) {
        photoIds = ids
        nameField.text = ""
        filterField.text = ""
        creating = false
        open()
    }

    edge: Qt.BottomEdge
    parent: Overlay.overlay
    width: parent ? parent.width : 400
    height: Math.min((parent ? parent.height : 800) * 0.8, col.implicitHeight + 24)
    interactive: opened   // opens only by openFor(); a drag down closes it
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.55) }
    background: Rectangle { color: sheet.theme.panel; topLeftRadius: 22; topRightRadius: 22 }

    readonly property var shown: {
        const q = filterField.text.trim().toLowerCase()
        return q.length ? albums.filter(a => (a.name || "").toLowerCase().indexOf(q) >= 0) : albums
    }

    ColumnLayout {
        id: col
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.leftMargin: 16; anchors.rightMargin: 16
        spacing: 10

        Rectangle {
            Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 9
            width: 36; height: 4; radius: 2; color: sheet.theme.border
        }
        Label {
            text: sheet.photoIds.length === 1 ? "Add to album" : "Add " + sheet.photoIds.length + " photos to an album"
            color: sheet.theme.text; font.pixelSize: 18; font.weight: Font.DemiBold
            Layout.fillWidth: true; elide: Text.ElideRight
        }

        // ---- offline: albums are the computer's
        Label {
            visible: !sheet.connected
            Layout.fillWidth: true
            wrapMode: Text.WordWrap
            color: sheet.theme.muted; font.pixelSize: 13
            text: "Albums live on your computer. Connect it to add photos to one."
        }
        Button {
            visible: !sheet.connected
            text: "Connect your computer"
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            Layout.bottomMargin: 12
            Material.background: sheet.theme.accent
            Material.foreground: "#ffffff"
            onClicked: { sheet.close(); sheet.connectComputer() }
        }

        // ---- a new album, named here
        RowLayout {
            visible: sheet.connected && sheet.creating
            Layout.fillWidth: true
            Layout.bottomMargin: 12
            spacing: 8
            TextField {
                id: nameField
                Layout.fillWidth: true
                placeholderText: "Album name"
                color: sheet.theme.text
                onAccepted: create.clicked()
            }
            Button {
                text: "Cancel"
                flat: true
                Material.foreground: sheet.theme.accent
                onClicked: sheet.creating = false   // back to the list
            }
            Button {
                id: create
                enabled: nameField.text.trim().length > 0
                text: "Create"
                Material.background: sheet.theme.accent
                Material.foreground: "#ffffff"
                onClicked: {
                    Qt.inputMethod.hide()
                    sheet.close()
                    sheet.newAlbum(nameField.text.trim(), sheet.photoIds)
                }
            }
        }

        // ---- the albums: search (when many), New album first, then each with its cover
        TextField {
            id: filterField
            visible: sheet.connected && !sheet.creating && sheet.albums.length > 6
            Layout.fillWidth: true
            placeholderText: "Search albums"
            color: sheet.theme.text
        }
        ListView {
            id: list
            visible: sheet.connected && !sheet.creating
            Layout.fillWidth: true
            Layout.preferredHeight: Math.min(contentHeight, (sheet.parent ? sheet.parent.height : 800) * 0.8 - 150)
            Layout.bottomMargin: 8
            clip: true
            model: sheet.shown
            ScrollBar.vertical: ScrollBar { }
            header: ItemDelegate {
                width: list.width
                implicitHeight: 64
                visible: filterField.text.trim().length === 0
                height: visible ? implicitHeight : 0
                contentItem: RowLayout {
                    spacing: 14
                    Rectangle {
                        implicitWidth: 48; implicitHeight: 48; radius: 10
                        color: sheet.theme.panelAlt
                        Label { anchors.centerIn: parent; text: "+"; color: sheet.theme.accent; font.pixelSize: 26 }
                    }
                    Label {
                        Layout.fillWidth: true
                        text: "New album"
                        color: sheet.theme.text; font.pixelSize: 15; font.weight: Font.DemiBold
                    }
                }
                onClicked: { sheet.creating = true; nameField.forceActiveFocus() }
            }
            delegate: ItemDelegate {
                required property var modelData
                width: list.width
                implicitHeight: 64
                contentItem: RowLayout {
                    spacing: 14
                    Rectangle {
                        implicitWidth: 48; implicitHeight: 48; radius: 10
                        color: sheet.theme.panelAlt
                        clip: true
                        Image {
                            id: cover
                            anchors.fill: parent
                            source: modelData.coverUrl || ""
                            visible: status === Image.Ready
                            fillMode: Image.PreserveAspectCrop
                            sourceSize.width: 128; sourceSize.height: 128
                            asynchronous: true
                        }
                        Label {
                            anchors.centerIn: parent
                            visible: cover.status !== Image.Ready
                            text: (modelData.name || "?").charAt(0).toUpperCase()
                            color: sheet.theme.muted; font.pixelSize: 20; font.bold: true
                        }
                    }
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 1
                        Label {
                            Layout.fillWidth: true
                            text: modelData.name
                            elide: Text.ElideRight
                            color: sheet.theme.text; font.pixelSize: 15
                        }
                        Label {
                            visible: text.length > 0
                            text: modelData.count !== undefined ? modelData.count + (modelData.count === 1 ? " item" : " items") : ""
                            color: sheet.theme.muted; font.pixelSize: 12
                        }
                    }
                }
                onClicked: { sheet.close(); sheet.pickAlbum(modelData.id, sheet.photoIds) }
            }
            footer: Label {
                width: list.width
                visible: sheet.shown.length === 0 && sheet.albums.length > 0
                height: visible ? 40 : 0
                text: "No album is called that"
                color: sheet.theme.muted; font.pixelSize: 13
                horizontalAlignment: Text.AlignHCenter; verticalAlignment: Text.AlignVCenter
            }
        }
    }
}
