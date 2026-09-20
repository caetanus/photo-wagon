import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// The computer: pairing status, the endpoint, and sending photos over. Replaces the
// old cramped toolbar buttons + endpoint dialog with a page you can actually read.
Item {
    id: page
    required property QtObject theme
    required property QtObject icons
    property string endpoint: ""
    property bool connected: false
    property var sync: ({ active: false, done: 0, total: 0, pending: 0, enabled: false })
    signal changeEndpoint()
    signal sendAll()
    signal autoSync(bool on)
    signal rescan()

    Rectangle { anchors.fill: parent; color: theme.bg }

    component Card: Rectangle {
        Layout.fillWidth: true
        radius: 16
        color: theme.panel
        border.color: theme.border
        implicitHeight: 10
    }

    Flickable {
        anchors.fill: parent
        contentHeight: col.height
        clip: true
        ColumnLayout {
            id: col
            width: parent.width
            spacing: 14
            anchors.margins: 16
            anchors.left: parent.left; anchors.right: parent.right
            anchors.leftMargin: 16; anchors.rightMargin: 16
            Item { Layout.preferredHeight: 4 }

            // ---- connection status --------------------------------------------
            Card {
                implicitHeight: statusCol.implicitHeight + 32
                ColumnLayout {
                    id: statusCol
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10
                    RowLayout {
                        spacing: 12
                        Rectangle {
                            width: 12; height: 12; radius: 6
                            color: page.connected ? theme.ok : (page.endpoint.length ? theme.warn : theme.border)
                        }
                        ColumnLayout {
                            spacing: 1
                            Layout.fillWidth: true
                            Label {
                                text: page.connected ? "Connected" : (page.endpoint.length ? "Offline" : "Not paired")
                                color: theme.text; font.pixelSize: 17; font.weight: Font.DemiBold
                            }
                            Label {
                                text: page.endpoint.length ? page.endpoint : "No computer set"
                                color: theme.muted; font.pixelSize: 13
                            }
                        }
                        Button {
                            text: page.endpoint.length ? "Change" : "Pair"
                            flat: true; Material.foreground: theme.accent
                            onClicked: page.changeEndpoint()
                        }
                    }
                }
            }

            // ---- sending ------------------------------------------------------
            Card {
                implicitHeight: sendCol.implicitHeight + 32
                ColumnLayout {
                    id: sendCol
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 12
                    Label { text: "BACKUP TO THE COMPUTER"; color: theme.muted; font.pixelSize: 11; font.letterSpacing: 0.8; font.bold: true }
                    Label {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        color: theme.text; font.pixelSize: 14
                        text: page.sync.active
                            ? "Sending " + (page.sync.done + 1) + " of " + page.sync.total + "…"
                            : page.connected
                                ? (page.sync.pending > 0
                                    ? page.sync.pending + (page.sync.pending === 1 ? " photo to send" : " photos to send")
                                    : "The computer has all your photos.")
                                : "Connect to the computer to send your photos."
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        visible: page.sync.active && page.sync.total > 0
                        from: 0; to: page.sync.total; value: page.sync.done
                        Material.accent: theme.accent
                    }
                    Button {
                        Layout.fillWidth: true
                        text: "Send all now"
                        enabled: page.connected && !page.sync.active && page.sync.pending > 0
                        Material.background: theme.accent
                        Material.foreground: "#ffffff"
                        onClicked: page.sendAll()
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: "Send new photos automatically"; color: theme.text; font.pixelSize: 14; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        Switch {
                            checked: page.sync.enabled === true
                            onToggled: page.autoSync(checked)
                            Material.accent: theme.accent
                        }
                    }
                }
            }

            // ---- library ------------------------------------------------------
            Card {
                implicitHeight: libCol.implicitHeight + 32
                ColumnLayout {
                    id: libCol
                    anchors.fill: parent
                    anchors.margins: 16
                    spacing: 10
                    Label { text: "THIS PHONE"; color: theme.muted; font.pixelSize: 11; font.letterSpacing: 0.8; font.bold: true }
                    Button {
                        Layout.fillWidth: true
                        text: "Rescan my photos"
                        flat: true
                        onClicked: page.rescan()
                    }
                }
            }

            Item { Layout.preferredHeight: 8 }
        }
    }
}
