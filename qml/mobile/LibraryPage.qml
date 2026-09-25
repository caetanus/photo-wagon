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
    property bool paired: false

    signal openAlbum(int id)
    signal createAlbum(string name)
    signal renameAlbum(int id, string name)
    signal deleteAlbum(int id)
    signal changeEndpoint()
    signal sendAll()
    signal autoSync(bool on)
    signal rescan()
    signal openKind(string kind)
    signal openFavorites()

    property int seg: 0   // 0 Albums · 1 Computer
    function showComputer() { seg = 1 }

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
                        // alert dot on the Computer segment: something to act on, not "not set up"
                        Rectangle {
                            visible: segBtn.modelData.i === 1 && ((view.sync.failedPhotos || 0) > 0
                                     || (view.paired && !view.connected && (view.sync.pending || 0) > 0))
                            implicitWidth: 7; implicitHeight: 7; radius: 3.5
                            color: theme.warn
                        }
                    }
                    TapHandler { onTapped: view.seg = modelData.i }
                }
            }
        }

        // collections that are always there (the phone's own screenshots and videos work
        // offline too), above the albums
        RowLayout {
            visible: view.seg === 0
            Layout.fillWidth: true
            Layout.leftMargin: 12; Layout.rightMargin: 12; Layout.bottomMargin: 4
            spacing: 8
            Repeater {
                model: [
                    { t: "Favorites", i: "heart", k: "" },
                    { t: "Screenshots", i: "screenshot", k: "screenshot" },
                    { t: "Videos", i: "video", k: "video" }
                ]
                delegate: Rectangle {
                    id: coll
                    required property var modelData
                    Layout.fillWidth: true
                    implicitHeight: 76
                    radius: 14
                    color: collTap.pressed ? theme.panelAlt : theme.panel
                    border.color: theme.border
                    ColumnLayout {
                        anchors.left: parent.left; anchors.bottom: parent.bottom
                        anchors.margins: 12
                        spacing: 6
                        Image {
                            source: view.icons.tint(view.icons[coll.modelData.i], theme.accent)
                            sourceSize.width: 22; sourceSize.height: 22
                        }
                        Label { text: coll.modelData.t; color: theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
                    }
                    TapHandler {
                        id: collTap
                        onTapped: coll.modelData.k.length ? view.openKind(coll.modelData.k) : view.openFavorites()
                    }
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
                paired: view.paired
                onConnectComputer: view.seg = 1
                onOpenAlbum: (id) => view.openAlbum(id)
                onCreateAlbum: (name) => view.createAlbum(name)
                onRenameAlbum: (id, name) => view.renameAlbum(id, name)
                onDeleteAlbum: (id) => view.deleteAlbum(id)
            }
            ComputerPage {
                theme: view.theme
                icons: view.icons
                endpoint: view.endpoint
                connected: view.connected
                paired: view.paired
                sync: view.sync
                onChangeEndpoint: view.changeEndpoint()
                onSendAll: view.sendAll()
                onAutoSync: (on) => view.autoSync(on)
                onRescan: view.rescan()
            }
        }
    }
}
