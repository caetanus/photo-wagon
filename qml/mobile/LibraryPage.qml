import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Library — the hub for everything that isn't the timeline or search: Albums and
// the paired Computer (pairing + sync). A segmented control keeps both one tap
// away (no push/pop), so nothing that used to be a bottom tab is lost. People and
// Places join here in a later pass.
Item {
    id: view
    required property QtObject theme
    required property QtObject icons

    // passed straight through to the existing pages
    property var albums: []
    property bool connected: false
    property var sync: ({})
    property string endpoint: ""

    signal openAlbum(int id)
    signal changeEndpoint()
    signal sendAll()
    signal autoSync(bool on)
    signal rescan()

    property int seg: 0   // 0 Albums · 1 Computer

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        // segmented control
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 8
            Repeater {
                model: [ { t: "Albums", i: 0 }, { t: "Computer", i: 1 } ]
                delegate: Rectangle {
                    id: segBtn
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: 38
                    radius: 19
                    readonly property bool on: view.seg === modelData.i
                    color: on ? theme.accent : theme.panelAlt
                    border.color: on ? "transparent" : theme.border
                    border.width: on ? 0 : 1
                    RowLayout {
                        anchors.centerIn: parent
                        spacing: 6
                        Label {
                            text: segBtn.modelData.t
                            color: segBtn.on ? theme.accentText : theme.text
                            font.pixelSize: 13
                            font.weight: segBtn.on ? Font.Bold : Font.Normal
                        }
                        // sync alert dot on the Computer segment
                        Rectangle {
                            visible: segBtn.modelData.i === 1 && (!view.connected || (view.sync.pending || 0) > 0)
                            implicitWidth: 7; implicitHeight: 7; radius: 3.5
                            color: theme.warn
                        }
                    }
                    TapHandler { onTapped: view.seg = modelData.i }
                }
            }
        }

        StackLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            currentIndex: view.seg

            AlbumsPage {
                theme: view.theme
                albums: view.albums
                connected: view.connected
                onOpenAlbum: (id) => view.openAlbum(id)
            }
            ComputerPage {
                theme: view.theme
                icons: view.icons
                endpoint: view.endpoint
                connected: view.connected
                sync: view.sync
                onChangeEndpoint: view.changeEndpoint()
                onSendAll: view.sendAll()
                onAutoSync: (on) => view.autoSync(on)
                onRescan: view.rescan()
            }
        }
    }
}
