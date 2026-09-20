import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Node identity, connected peers, a multiaddr dial box and the albums with
// their publish buttons. Everything comes parsed from library.hello / peers / albums.
Popup {
    id: panel
    required property QtObject theme
    modal: true
    focus: true
    padding: 16
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside

    readonly property var hello: JSON.parse(library.hello)
    readonly property var peersData: JSON.parse(library.peers)
    readonly property var albumsData: JSON.parse(library.albums)
    // {peerId: nickname} the user has given peers — overlaid onto the live list below.
    readonly property var peerNames: JSON.parse(library.peerNames)

    // A short, readable stand-in for a raw 12D3Koo… peer id.
    function short(id) {
        return (id && id.length > 15) ? id.slice(0, 8) + "…" + id.slice(-4) : (id || "")
    }

    background: Rectangle {
        color: theme.panel
        border.color: theme.separator
        radius: 8
    }

    contentItem: ColumnLayout {
        spacing: 12

        Label {
            text: "This node"
            font.bold: true
            font.pixelSize: 15
            color: theme.text
        }
        TextField {
            Layout.fillWidth: true
            readOnly: true
            text: panel.hello.peerId ? panel.hello.peerId : "(daemon not connected)"
            selectByMouse: true
        }
        Label {
            Layout.fillWidth: true
            text: panel.hello.addrs ? panel.hello.addrs.join("\n") : ""
            color: theme.muted
            font.pixelSize: 12
            wrapMode: Text.WrapAnywhere
        }

        Label {
            text: "Connect to a peer"
            font.bold: true
            color: theme.text
            Layout.topMargin: 6
        }
        RowLayout {
            Layout.fillWidth: true
            TextField {
                id: addrField
                Layout.fillWidth: true
                placeholderText: "/ip4/…/tcp/…/p2p/12D3Koo…"
                onAccepted: dialButton.clicked()
            }
            Button {
                id: dialButton
                text: "Connect"
                enabled: addrField.text.trim().length > 0
                onClicked: { library.connectPeer(addrField.text); addrField.clear() }
            }
        }

        Label {
            text: "Peers (" + (panel.peersData.peers ? panel.peersData.peers.length : 0) + ")"
            font.bold: true
            color: theme.text
            Layout.topMargin: 6
        }
        ListView {
            Layout.fillWidth: true
            Layout.preferredHeight: 150
            clip: true
            spacing: 6
            model: panel.peersData.peers ? panel.peersData.peers : []
            ScrollBar.vertical: ScrollBar { }
            delegate: Column {
                id: peerRow
                required property var modelData
                width: ListView.view.width
                spacing: 2
                property string pid: modelData.peerId
                property string nick: panel.peerNames[pid] || ""
                property bool editing: false

                RowLayout {
                    width: parent.width
                    Label {
                        Layout.fillWidth: true
                        text: peerRow.nick.length ? peerRow.nick : panel.short(peerRow.pid)
                        color: theme.text
                        font.pixelSize: 13
                        font.bold: peerRow.nick.length > 0
                        elide: Text.ElideRight
                    }
                    Button {
                        flat: true
                        text: peerRow.editing ? "Cancel" : (peerRow.nick.length ? "Rename" : "Name")
                        font.pixelSize: 11
                        onClicked: peerRow.editing = !peerRow.editing
                    }
                }
                Label {
                    width: parent.width
                    text: peerRow.pid + (modelData.agent ? "   ·   " + modelData.agent : "")
                    color: theme.muted
                    font.pixelSize: 10
                    elide: Text.ElideRight
                }
                RowLayout {
                    visible: peerRow.editing
                    width: parent.width
                    TextField {
                        id: nickField
                        Layout.fillWidth: true
                        text: peerRow.nick
                        placeholderText: "nickname"
                        onAccepted: { library.setPeerName(peerRow.pid, text); peerRow.editing = false }
                    }
                    Button {
                        text: "Save"
                        onClicked: { library.setPeerName(peerRow.pid, nickField.text); peerRow.editing = false }
                    }
                }
            }
            Label {
                anchors.centerIn: parent
                visible: parent.count === 0
                text: "No peers connected"
                color: theme.muted
            }
        }

        Label {
            text: "Albums"
            font.bold: true
            color: theme.text
            Layout.topMargin: 6
        }
        ListView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.minimumHeight: 100
            clip: true
            model: panel.albumsData.albums ? panel.albumsData.albums : []
            delegate: RowLayout {
                required property var modelData
                width: ListView.view.width
                Label {
                    Layout.fillWidth: true
                    text: modelData.name + "   ·   " + modelData.photos + " photos"
                    color: theme.text
                    elide: Text.ElideRight
                }
                Label {
                    visible: !!modelData.manifest
                    text: modelData.manifest ? String(modelData.manifest).slice(0, 12) + "…" : ""
                    color: theme.muted
                    font.pixelSize: 12
                }
                Button {
                    text: modelData.manifest ? "Republish" : "Publish"
                    onClicked: library.publishAlbum(modelData.id)
                }
            }
            Label {
                anchors.centerIn: parent
                visible: parent.count === 0
                text: "No albums yet"
                color: theme.muted
            }
        }

        RowLayout {
            Layout.fillWidth: true
            Item { Layout.fillWidth: true }
            Button { text: "Close"; onClicked: panel.close() }
        }
    }
}
