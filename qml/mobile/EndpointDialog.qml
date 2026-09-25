import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Connecting the phone to the computer — by its pairing code only. The QR on the computer
// carries a token (pw://<token>); the phone finds the computer on the LAN by mDNS, or
// through the DHT/relays when away, so no address or port is ever typed. The steps follow
// the real state: waiting for the scan, looking for the computer, approving on it (the
// four-digit code), connected.
Dialog {
    id: dialog
    required property QtObject theme
    property string current: ""          // kept for callers; the flow no longer shows it
    property bool paired: false
    property bool connected: false
    property bool approving: false       // the computer is being asked to allow this phone

    signal chosen(string host, int port)

    title: dialog.changing ? "Change computer" : dialog.connected ? "Connected" : dialog.paired ? "Your computer" : "Connect your computer"
    modal: true
    // a dark scrim, not the style's pale wash
    Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.62) }
    Material.background: theme.panel
    padding: 20

    property bool waitingScan: false     // the scanner was opened; its code arrives on its own
    property string codeError: ""
    property bool changing: false        // connected, and the user wants another computer
    property string scanNote: ""

    onAboutToShow: { codeField.text = ""; codeError = ""; waitingScan = false; changing = false; scanNote = "" }
    onPairedChanged: if (paired) { waitingScan = false; scanNote = "" }

    // Back from the scanner with no code (cancelled, failed): say so instead of spinning
    Connections {
        target: Qt.application
        function onStateChanged() {
            if (Qt.application.state === Qt.ApplicationActive && dialog.waitingScan) {
                scanBack.interval = 4000
                scanBack.restart()
            }
        }
    }
    Timer {
        id: scanBack
        interval: 4000
        onTriggered: {
            if (!dialog.waitingScan)
                return
            dialog.waitingScan = false
            if (!dialog.paired)
                dialog.scanNote = "No code came back from the scanner. Scan again, or paste the code."
            else if (dialog.changing)
                // still paired to the old one: a new code switches over by itself, but we can't
                // tell yet whether one came
                dialog.scanNote = "If the scan worked, the phone switches to the new computer in a moment. If not, scan again or paste the code."
        }
    }
    readonly property bool showEntry: !dialog.connected || dialog.changing

    function submitCode() {
        const c = codeField.text.trim()
        if (!c.startsWith("pw://") || c.length < 12) {
            codeError = "That doesn't look like a pairing code — it starts with pw://"
            return
        }
        codeError = ""
        chosen(c, 0)
    }

    // where we are, in words
    readonly property string stateText: dialog.connected && !dialog.changing
        ? "This phone is connected to your computer. New photos can go there now."
        : dialog.changing
          ? "Scan the code of the other computer (in its Photo Wagon, choose Phone), or paste it."
        : dialog.approving
          ? "Almost there: type the code shown on this phone into Photo Wagon on the computer."
          : dialog.paired
            ? "Looking for your computer… It connects by itself when it's on and reachable."
            : dialog.waitingScan
              ? "Waiting for the scan…"
              : "On the computer, open Photo Wagon and choose Phone. Then scan the code it shows."

    contentItem: ColumnLayout {
        spacing: 14
        implicitWidth: 300

        RowLayout {
            Layout.fillWidth: true
            spacing: 10
            BusyIndicator {
                visible: !dialog.connected && (dialog.paired || dialog.waitingScan || dialog.approving)
                running: visible
                implicitWidth: 24; implicitHeight: 24
                Material.accent: theme.accent
            }
            Rectangle {
                visible: dialog.connected
                implicitWidth: 12; implicitHeight: 12; radius: 6; color: theme.ok
            }
            Label {
                text: dialog.stateText
                color: theme.text; font.pixelSize: 14
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }

        Label {
            visible: dialog.scanNote.length > 0
            text: dialog.scanNote
            color: theme.warn; font.pixelSize: 12
            wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        Button {
            visible: dialog.showEntry
            text: dialog.paired ? "Scan a new code" : "Scan QR code"
            Layout.fillWidth: true
            Layout.preferredHeight: 48
            Material.background: dialog.paired ? theme.panelAlt : theme.accent
            Material.foreground: dialog.paired ? theme.text : "#ffffff"
            // MainActivity: pwscan:// → the ML Kit scanner → settings/scanned, which the core
            // picks up by itself. The dialog stays open and follows the state.
            onClicked: {
                dialog.scanNote = ""; dialog.waitingScan = true
                // no scanner on the device (no Google services) never takes the app away:
                // give up waiting after a while either way
                scanBack.interval = 8000; scanBack.restart()
                Qt.openUrlExternally("pwscan://start")
            }
        }

        // the manual way: the same code, pasted (sent by mail/chat from the computer)
        Label {
            visible: dialog.showEntry
            text: "No camera handy? Paste the pairing code instead:"
            color: theme.muted; font.pixelSize: 12
            wrapMode: Text.WordWrap; Layout.fillWidth: true
        }
        RowLayout {
            visible: dialog.showEntry
            Layout.fillWidth: true
            spacing: 8
            TextField {
                id: codeField
                Layout.fillWidth: true
                placeholderText: "pw://…"
                inputMethodHints: Qt.ImhUrlCharactersOnly | Qt.ImhNoAutoUppercase | Qt.ImhNoPredictiveText
                color: theme.text
                onAccepted: dialog.submitCode()
            }
            Button {
                text: "Use"
                enabled: codeField.text.trim().length > 0
                flat: true
                Material.foreground: theme.accent
                onClicked: dialog.submitCode()
            }
        }
        Label {
            visible: dialog.codeError.length > 0
            text: dialog.codeError
            color: theme.warn; font.pixelSize: 12
            wrapMode: Text.WordWrap; Layout.fillWidth: true
        }

        RowLayout {
            Layout.fillWidth: true
            Button {
                // connected: switching to another computer stays one tap away
                visible: dialog.connected && !dialog.changing
                text: "Change computer"
                flat: true
                Material.foreground: theme.accent
                onClicked: dialog.changing = true
            }
            Item { Layout.fillWidth: true }
            Button {
                text: dialog.connected && !dialog.changing ? "Done" : "Later"
                flat: !(dialog.connected && !dialog.changing)
                Material.background: dialog.connected && !dialog.changing ? theme.accent : "transparent"
                Material.foreground: dialog.connected && !dialog.changing ? "#ffffff" : theme.accent
                onClicked: dialog.close()
            }
        }
    }
}
