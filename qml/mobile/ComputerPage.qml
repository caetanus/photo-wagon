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
    property bool paired: false
    property var sync: ({ active: false, done: 0, total: 0, pending: 0, enabled: false })
    readonly property int failures: (page.sync.failedPhotos || 0)
    // "libp2p 12D3KooW…" / "hyperswarm d84434e7…" says nothing to a person: the computer, and
    // a short id for support
    readonly property string computerId: {
        if (page.endpoint.startsWith("hyperswarm ")) return page.endpoint.substring(11, 19)
        const i = page.endpoint.indexOf("12D3Koo")
        return i >= 0 ? "…" + page.endpoint.substring(page.endpoint.length - 6) : page.endpoint
    }
    signal changeEndpoint()
    signal sendAll()
    signal autoSync(bool on)
    signal pauseSync(bool paused)
    signal dataSaver(bool on)
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
                            color: page.connected ? theme.ok : (page.paired ? theme.warn : theme.border)
                        }
                        ColumnLayout {
                            spacing: 1
                            Layout.fillWidth: true
                            Label {
                                text: page.connected ? "Connected to your computer"
                                    : page.paired ? "Your computer is offline" : "No computer connected"
                                color: theme.text; font.pixelSize: 17; font.weight: Font.DemiBold
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }
                            Label {
                                text: page.paired
                                    ? (page.connected ? "Paired" : "Paired — it connects again on its own when it's on")
                                      + (page.computerId.length ? " · " + page.computerId : "")
                                    : "Connect it to back up this phone's photos"
                                color: theme.muted; font.pixelSize: 13
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }
                        }
                        Button {
                            text: page.paired ? "Change" : "Connect"
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
                              + (page.sync.held === "paused" ? " Pausing after this one." : page.sync.held === "metered" ? " Stopping after this one (data saver)." : "")
                            : page.sync.held === "paused"
                              ? "Sending is paused" + (page.sync.pending > 0 ? " — " + page.sync.pending + (page.sync.pending === 1 ? " photo waits." : " photos wait.") : ".")
                            : page.sync.held === "metered"
                              ? "Waiting for Wi-Fi — data saver keeps photos off mobile data" + (page.sync.pending > 0 ? " (" + page.sync.pending + " waiting)." : ".")
                            : page.connected
                                ? (page.sync.pending > 0
                                    ? page.sync.pending + (page.sync.pending === 1 ? " photo" : " photos")
                                      + (page.sync.enabled ? " waiting to go." : " not on the computer yet — Send all now, or turn on automatic sending.")
                                    : "The computer has all your photos.")
                                : page.paired
                                    ? (page.sync.pending > 0
                                        ? page.sync.pending + (page.sync.enabled ? " waiting — they go when the computer is back." : " not sent yet.")
                                        : "Nothing waiting.")
                                    : "Connect your computer to send your photos."
                    }
                    // what went wrong, in words, with the way to try again
                    Label {
                        Layout.fillWidth: true; wrapMode: Text.WordWrap
                        visible: page.failures > 0 || !!page.sync.error
                        color: theme.warn; font.pixelSize: 13
                        text: (page.failures > 0
                                ? page.failures + (page.failures === 1 ? " photo couldn't be sent" : " photos couldn't be sent") : "Sending stopped")
                              + (page.sync.error ? ": " + page.sync.error : ".")
                              + " Send all now tries again."
                    }
                    ProgressBar {
                        Layout.fillWidth: true
                        visible: page.sync.active && page.sync.total > 0
                        from: 0; to: page.sync.total; value: page.sync.done
                        Material.accent: theme.accent
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 8
                        Button {
                            Layout.fillWidth: true
                            text: "Send all now"
                            enabled: page.connected && !page.sync.active && page.sync.held !== "metered"
                                     && (page.sync.pending > 0 || page.failures > 0)
                            Material.background: theme.accent
                            Material.foreground: "#ffffff"
                            onClicked: page.sendAll()
                        }
                        // hold / go on; remembered, and the background service honours it
                        Button {
                            Layout.fillWidth: true
                            text: page.sync.paused ? "Resume" : "Pause"
                            flat: !page.sync.paused
                            Material.background: page.sync.paused ? theme.accent : "transparent"
                            Material.foreground: page.sync.paused ? "#ffffff" : theme.accent
                            onClicked: page.pauseSync(!page.sync.paused)
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 1
                            Label { text: "Send new photos automatically"; color: theme.text; font.pixelSize: 14; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            Label { text: "Keeps working in the background, with a notification"; color: theme.muted; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                        }
                        Switch {
                            checked: page.sync.enabled === true
                            onToggled: page.autoSync(checked)
                            Material.accent: theme.accent
                        }
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            Layout.fillWidth: true; spacing: 1
                            Label { text: "Data saver"; color: theme.text; font.pixelSize: 14; Layout.fillWidth: true; wrapMode: Text.WordWrap }
                            Label {
                                text: "Send only on Wi-Fi — nothing goes over mobile data" + (page.sync.metered ? " (you're on mobile data now)" : "")
                                color: theme.muted; font.pixelSize: 12; Layout.fillWidth: true; wrapMode: Text.WordWrap
                            }
                        }
                        Switch {
                            checked: page.sync.dataSaver === true
                            onToggled: page.dataSaver(checked)
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
