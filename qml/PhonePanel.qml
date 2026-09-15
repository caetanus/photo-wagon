import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Connect your phone": turns the network door on and shows the QR code the
// phone scans. `pairing` is the parsed library.pairing payload.
Popup {
    id: panel
    required property QtObject theme
    property var pairing: ({ enabled: false })
    readonly property var devicesData: { try { return JSON.parse(library.devices).devices } catch (e) { return [] } }
    /// The popup body; a plain Item, so headless captures can grab it (the popup item cannot be grabbed).
    property alias body: body

    modal: true
    focus: true
    padding: 24
    background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 8 }

    onOpened: { library.setPairing(true); library.loadDevices() }

    ColumnLayout {
        id: body
        anchors.fill: parent
        spacing: 16

        Label {
            text: "Connect your phone"
            font.pixelSize: 20
            font.bold: true
            color: theme.text
        }
        Label {
            text: "Open Photo Wagon on the phone, tap ⚙ then “Scan QR code”, and point it here. Photos the phone sends land in this library."
            color: theme.muted
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        // The QR, rendered as a PNG by the core (1:1, no resampling).
        Rectangle {
            Layout.alignment: Qt.AlignHCenter
            width: 328
            height: 328
            color: "white"
            radius: 6
            Image {
                anchors.centerIn: parent
                source: panel.pairing.enabled ? panel.pairing.qrImage : ""
                smooth: false
                fillMode: Image.Pad
            }
            Label {
                anchors.centerIn: parent
                visible: !panel.pairing.enabled
                text: "starting…"
                color: "black"
            }
        }

        Label {
            visible: panel.pairing.enabled
            text: panel.pairing.enabled
                ? "Listening on port " + panel.pairing.port + " at " + panel.pairing.addrs.join(", ")
                : ""
            color: theme.muted
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        TextField {
            visible: panel.pairing.enabled
            text: panel.pairing.enabled ? panel.pairing.code : ""
            readOnly: true
            selectByMouse: true
            font.pixelSize: 11
            Layout.fillWidth: true
        }
        // Paired phones: rename, pause (turn away until resumed) or revoke (turn away for good).
        Rectangle {
            visible: panel.devicesData.length > 0
            Layout.fillWidth: true
            height: 1
            color: theme.separator
        }
        Label {
            visible: panel.devicesData.length > 0
            text: "Paired devices"
            color: theme.muted
            font.pixelSize: 11
            font.bold: true
        }
        Repeater {
            model: panel.devicesData
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8
                // editable name
                TextField {
                    text: modelData.name
                    Layout.fillWidth: true
                    font.pixelSize: 13
                    background: Rectangle { color: "transparent" }
                    onEditingFinished: if (text.trim().length && text !== modelData.name)
                        library.renameDevice(modelData.peerId, text.trim())
                }
                Label {
                    text: modelData.state
                    color: modelData.state === "active" ? "#3ecf8e"
                         : modelData.state === "paused" ? "#e8a33d" : "#e5534b"
                    font.pixelSize: 11
                }
                Button {
                    text: modelData.state === "paused" ? "Resume" : "Pause"
                    flat: true
                    onClicked: modelData.state === "paused"
                        ? library.resumeDevice(modelData.peerId)
                        : library.pauseDevice(modelData.peerId)
                }
                Button {
                    text: modelData.state === "revoked" ? "Forget" : "Revoke"
                    flat: true
                    onClicked: modelData.state === "revoked"
                        ? library.forgetDevice(modelData.peerId)
                        : library.revokeDevice(modelData.peerId)
                }
            }
        }

        RowLayout {
            Item { Layout.fillWidth: true }
            Button { text: "Close"; onClicked: panel.close() }
        }
    }
}
