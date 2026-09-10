import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Where the library lives: the desktop running `photo-wagon --serve`.
Dialog {
    id: dialog
    required property QtObject theme
    property string current: ""

    signal chosen(string host, int port)

    title: "Computer"
    readonly property var syncData: JSON.parse(library.sync)
    modal: true
    standardButtons: Dialog.Ok | Dialog.Cancel

    onAboutToShow: {
        const i = current.indexOf(":")
        hostField.text = i > 0 ? current.substring(0, i) : current
        portField.text = i > 0 ? current.substring(i + 1) : ""
    }
    onAccepted: {
        const p = parseInt(portField.text)
        if (hostField.text.trim().length && p > 0)
            chosen(hostField.text.trim(), p)
    }

    ColumnLayout {
        spacing: 12
        width: Math.max(280, dialog.availableWidth)
        Label {
            text: "On the computer, click “Phone” in Photo Wagon and scan the code it shows. Photos you send land in its library."
            color: theme.muted
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        Button {
            text: "Scan QR code"
            Layout.fillWidth: true
            // handled by MainActivity (pwscan:// intent → ML Kit scanner → settings/scanned)
            onClicked: { Qt.openUrlExternally("pwscan://start"); dialog.close() }
        }
        Switch {
            text: "Keep the computer up to date"
            checked: dialog.syncData.enabled
            onToggled: library.setAutoSync(checked)
            Layout.fillWidth: true
        }
        Label {
            visible: dialog.syncData.enabled
            text: dialog.syncData.active
                ? "Sending " + (dialog.syncData.done + 1) + " of " + dialog.syncData.total
                : dialog.syncData.pending ? dialog.syncData.pending + " photos waiting for the computer"
                : "Everything is on the computer"
            color: theme.muted
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        Label { text: "or type the address by hand:"; color: theme.muted }
        TextField {
            id: hostField
            placeholderText: "192.168.0.10"
            inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase
            Layout.fillWidth: true
        }
        TextField {
            id: portField
            placeholderText: "port"
            inputMethodHints: Qt.ImhDigitsOnly
            validator: IntValidator { bottom: 1; top: 65535 }
            Layout.fillWidth: true
        }
    }
}
