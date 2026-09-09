import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Connect your phone": turns the network door on and shows the QR code the
// phone scans. `pairing` is the parsed library.pairing payload.
Popup {
    id: panel
    required property QtObject theme
    property var pairing: ({ enabled: false })
    /// The popup body; a plain Item, so headless captures can grab it (the popup item cannot be grabbed).
    property alias body: body

    modal: true
    focus: true
    padding: 24
    background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 8 }

    onOpened: library.setPairing(true)

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
        RowLayout {
            Item { Layout.fillWidth: true }
            Button { text: "Close"; onClicked: panel.close() }
        }
    }
}
