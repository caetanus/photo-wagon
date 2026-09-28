import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// "Your other computers": this computer's code, a box for another computer's code, and the
// computers this library mirrors (both ways) with where each stands. Everything comes parsed
// from library.computers (computers.list) and library.computersCode.
Popup {
    id: panel
    required property QtObject theme
    readonly property var data_: { try { return JSON.parse(library.computers) } catch (e) { return ({ computers: [], alias: "" }) } }
    readonly property var computers: data_.computers || []
    /// The popup body; a plain Item, so headless captures can grab it.
    property alias body: body

    modal: true
    focus: true
    padding: 24
    background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 8 }

    onOpened: library.loadComputers()

    function stateText(c) {
        switch (c.state) {
        case "waiting": return "Confirm the code " + c.code + " on the other computer"
        case "syncing": return (c.missing > 0 ? c.missing + " photos to bring over" : "Bringing photos over") + (c.pulled > 0 ? " · " + c.pulled + " done" : "")
        case "idle": return "Up to date" + (c.pulled > 0 ? " · " + c.pulled + " brought over" : "")
        case "refused": return "The other computer did not accept this one"
        case "offline": return "Not connected"
        default: return "Connecting…"
        }
    }

    ColumnLayout {
        id: body
        anchors.fill: parent
        spacing: 14

        Label {
            text: "Your other computers"
            font.pixelSize: 20
            font.bold: true
            color: theme.text
        }
        Label {
            text: "Paired computers keep the same photos: what one has, the other brings over — at home or anywhere. Deleting a photo in Photo Wagon stays on this computer for now."
            color: theme.muted
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }

        Label { text: "This computer's code"; color: theme.muted; font.pixelSize: 11; font.bold: true }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            TextField {
                id: ownCode
                text: library.computersCode
                readOnly: true
                selectByMouse: true
                font.pixelSize: 11
                Layout.fillWidth: true
            }
            Button {
                text: "Copy"
                enabled: ownCode.text.length > 0
                onClicked: { ownCode.selectAll(); ownCode.copy(); ownCode.deselect() }
            }
        }

        Label { text: "Pair with another computer"; color: theme.muted; font.pixelSize: 11; font.bold: true }
        Label {
            text: "Paste the code the other computer shows here (on it: Sync with Another Computer…). It will ask you to confirm a 4-digit code."
            color: theme.muted
            font.pixelSize: 12
            wrapMode: Text.WordWrap
            Layout.fillWidth: true
        }
        RowLayout {
            Layout.fillWidth: true
            spacing: 8
            TextField {
                id: otherCode
                placeholderText: "pw://…"
                selectByMouse: true
                font.pixelSize: 11
                Layout.fillWidth: true
                onAccepted: pairBtn.clicked()
            }
            Button {
                id: pairBtn
                text: "Pair"
                enabled: otherCode.text.trim().startsWith("pw://") && otherCode.text.trim() !== ownCode.text
                onClicked: { library.pairComputer(otherCode.text.trim()); otherCode.text = "" }
            }
        }

        Rectangle {
            visible: panel.computers.length > 0
            Layout.fillWidth: true
            height: 1
            color: theme.separator
        }
        Repeater {
            model: panel.computers
            delegate: RowLayout {
                required property var modelData
                Layout.fillWidth: true
                spacing: 8
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: 2
                    Label {
                        text: modelData.alias ? modelData.alias : (modelData.pending ? "New computer" : modelData.key.slice(0, 12) + "…")
                        color: theme.text
                        font.pixelSize: 13
                        font.bold: true
                    }
                    Label {
                        text: panel.stateText(modelData)
                        color: modelData.state === "idle" ? "#3ecf8e"
                             : modelData.state === "refused" ? "#e5534b"
                             : modelData.state === "waiting" ? "#e8a33d" : theme.muted
                        font.pixelSize: 12
                        wrapMode: Text.WordWrap
                        Layout.fillWidth: true
                    }
                }
                Button {
                    text: "Remove"
                    flat: true
                    visible: modelData.key.length > 0
                    onClicked: library.removeComputer(modelData.key)
                }
            }
        }

        // in-app deletions from another computer, too many at once to apply unasked
        Repeater {
            model: panel.computers.filter(c => (c.held || 0) > 0)
            delegate: Rectangle {
                id: heldRow
                required property var modelData
                Layout.fillWidth: true
                implicitHeight: heldCol.implicitHeight + 20
                radius: 6
                color: Qt.rgba(0.91, 0.64, 0.24, 0.12)
                border.color: "#e8a33d"
                ColumnLayout {
                    id: heldCol
                    anchors.fill: parent
                    anchors.margins: 10
                    spacing: 6
                    Label {
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        color: theme.text
                        font.pixelSize: 12
                        text: heldRow.modelData.held + (heldRow.modelData.held === 1 ? " photo was" : " photos were")
                              + " deleted in Photo Wagon on " + (heldRow.modelData.alias || "the other computer")
                              + ". Delete " + (heldRow.modelData.held === 1 ? "it" : "them") + " here too?"
                              + " They go to this computer's Trash."
                    }
                    RowLayout {
                        spacing: 8
                        Item { Layout.fillWidth: true }
                        Button {
                            text: "Keep them here"
                            flat: true
                            onClicked: library.resolveComputerDeletions(heldRow.modelData.key, false)
                        }
                        Button {
                            text: "Delete " + heldRow.modelData.held + " here"
                            onClicked: library.resolveComputerDeletions(heldRow.modelData.key, true)
                        }
                    }
                }
            }
        }

        RowLayout {
            Item { Layout.fillWidth: true }
            Button { text: "Close"; onClicked: panel.close() }
        }
    }
}
