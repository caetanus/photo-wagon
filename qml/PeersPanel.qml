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
            Layout.preferredHeight: 120
            clip: true
            model: panel.peersData.peers ? panel.peersData.peers : []
            delegate: ItemDelegate {
                required property var modelData
                width: ListView.view.width
                text: modelData.peerId + (modelData.agent ? "   ·   " + modelData.agent : "")
                font.pixelSize: 12
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
