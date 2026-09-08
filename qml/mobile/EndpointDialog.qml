import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Where the library lives: the desktop running `photo-wagon --serve`.
Dialog {
    id: dialog
    required property QtObject theme
    property string current: ""

    signal chosen(string host, int port)

    title: "Connect to a library"
    modal: true
    standardButtons: Dialog.Ok | Dialog.Cancel
    closePolicy: current.length ? Popup.CloseOnEscape | Popup.CloseOnPressOutside : Popup.NoAutoClose

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
            text: "On the computer with your photos, run\nphoto-wagon --serve --ipc-address 0.0.0.0\nand type its address and port here."
            color: theme.muted
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
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
