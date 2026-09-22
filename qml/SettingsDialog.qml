import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Preferences — a macOS-style settings window: a section list on the left
// (Appearance / View / Sharing) and its panel on the right. The window owns the
// live state (theme, thumbnail size, startup view, pairing); this dialog reads it
// and reports the user's choices back through the signals below.
Dialog {
    id: dlg
    required property QtObject theme
    required property QtObject icons

    // ---- state mirrored from the main window ------------------------------------
    property string themeMode: "mac"      // "mac" | "system"
    property string startupView: "all"    // "years" | "months" | "days" | "all"
    property int thumbSize: 176           // 72..320

    // ---- choices reported back to the window ------------------------------------
    signal pickTheme(string mode)
    signal pickView(string v)
    signal pickThumbSize(int z)
    signal manageComputers()

    property int section: 0               // 0 Appearance · 1 View · 2 Sharing

    readonly property var pairingData: { try { return JSON.parse(library.pairing) } catch (e) { return { enabled: false } } }
    readonly property var devicesData: { try { return JSON.parse(library.devices).devices } catch (e) { return [] } }

    title: "Settings"
    modal: true
    anchors.centerIn: Overlay.overlay
    padding: 0
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutside
    // Opening straight onto Sharing (or switching to it) turns the network door on.
    onSectionChanged: if (section === 2) { library.setPairing(true); library.loadDevices() }

    background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 10 }
    header: null
    footer: null

    // A tiny helper for section rows.
    component NavRow: Rectangle {
        id: nav
        required property int index
        required property string label
        required property string glyph
        Layout.fillWidth: true
        Layout.preferredHeight: 34
        radius: 7
        color: dlg.section === index ? dlg.theme.accent : (hover.hovered ? dlg.theme.hover : "transparent")
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 10
            spacing: 9
            Image {
                source: dlg.icons.tint(nav.glyph, dlg.section === nav.index ? "#ffffff" : dlg.theme.text)
                sourceSize.width: 16; sourceSize.height: 16
            }
            Label {
                text: nav.label
                color: dlg.section === nav.index ? "#ffffff" : dlg.theme.text
                font.pixelSize: 13
                Layout.fillWidth: true
            }
        }
        HoverHandler { id: hover }
        TapHandler { onTapped: dlg.section = nav.index }
    }

    contentItem: RowLayout {
        spacing: 0
        implicitWidth: 700
        implicitHeight: 500

        // ---- section list -----------------------------------------------------------
        Rectangle {
            Layout.preferredWidth: 196
            Layout.fillHeight: true
            color: theme.sidebar
            // round only the left corners, to sit inside the dialog's radius
            Rectangle { anchors.right: parent.right; width: 12; height: parent.height; color: parent.color }
            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 12
                spacing: 3
                Label {
                    text: "Settings"
                    font.pixelSize: 16; font.bold: true
                    color: theme.text
                    Layout.bottomMargin: 8
                }
                NavRow { index: 0; label: "Appearance"; glyph: dlg.icons.appearance }
                NavRow { index: 1; label: "View";       glyph: dlg.icons.photos }
                NavRow { index: 2; label: "Sharing";     glyph: dlg.icons.network }
                Item { Layout.fillHeight: true }
            }
        }

        // ---- panel ------------------------------------------------------------------
        StackLayout {
            currentIndex: dlg.section
            Layout.fillWidth: true
            Layout.fillHeight: true

            // ===== Appearance =========================================================
            Flickable {
                contentHeight: appCol.height + 48
                clip: true
                ColumnLayout {
                    id: appCol
                    x: 24; y: 24
                    width: parent.width - 48
                    spacing: 14

                    Label { text: "Theme"; font.pixelSize: 15; font.bold: true; color: theme.text }
                    Label {
                        text: "Both themes follow your system's light and dark mode automatically."
                        color: theme.muted; font.pixelSize: 12
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                    RowLayout {
                        spacing: 14
                        Repeater {
                            model: [["mac", "Mac", "#0a7aff"], ["system", "System (desktop)", ""]]
                            delegate: Rectangle {
                                id: card
                                required property var modelData
                                readonly property bool on: dlg.themeMode === modelData[0]
                                readonly property color swatch: modelData[2].length ? modelData[2] : (dlg.theme.accent)
                                width: 150; height: 92; radius: 9
                                color: theme.field
                                border.color: on ? theme.accent : theme.separator
                                border.width: on ? 2 : 1
                                ColumnLayout {
                                    anchors.fill: parent
                                    anchors.margins: 10
                                    spacing: 8
                                    // a little window-preview swatch
                                    Rectangle {
                                        Layout.fillWidth: true; Layout.preferredHeight: 40
                                        radius: 5; color: theme.window; border.color: theme.separator
                                        Rectangle { x: 6; y: 6; width: 28; height: 6; radius: 3; color: card.swatch }
                                        Rectangle { x: 6; y: 18; width: parent.width - 12; height: 4; radius: 2; color: theme.separator }
                                        Rectangle { x: 6; y: 26; width: parent.width - 24; height: 4; radius: 2; color: theme.separator }
                                    }
                                    RowLayout {
                                        spacing: 6
                                        Image {
                                            visible: card.on
                                            source: dlg.icons.tint(dlg.icons.check, theme.accent)
                                            sourceSize.width: 13; sourceSize.height: 13
                                        }
                                        Label { text: modelData[1]; color: theme.text; font.pixelSize: 12; Layout.fillWidth: true }
                                    }
                                }
                                TapHandler { onTapped: dlg.pickTheme(modelData[0]) }
                            }
                        }
                    }
                    RowLayout {
                        spacing: 8
                        Label { text: "Accent"; color: theme.muted; font.pixelSize: 12 }
                        Rectangle { width: 18; height: 18; radius: 9; color: theme.accent; border.color: theme.separator }
                        Label {
                            text: dlg.themeMode === "system" ? "from your desktop" : "Photo Wagon blue"
                            color: theme.muted; font.pixelSize: 12
                        }
                    }
                }
            }

            // ===== View ===============================================================
            Flickable {
                contentHeight: viewCol.height + 48
                clip: true
                ColumnLayout {
                    id: viewCol
                    x: 24; y: 24
                    width: parent.width - 48
                    spacing: 18

                    ColumnLayout {
                        spacing: 8; Layout.fillWidth: true
                        Label { text: "Thumbnail size"; font.pixelSize: 15; font.bold: true; color: theme.text }
                        RowLayout {
                            Layout.fillWidth: true; spacing: 10
                            Image { source: dlg.icons.tint(dlg.icons.zoomOut, theme.muted); sourceSize.width: 15; sourceSize.height: 15 }
                            Slider {
                                Layout.fillWidth: true
                                from: 72; to: 320; value: dlg.thumbSize
                                onMoved: dlg.pickThumbSize(value)
                            }
                            Image { source: dlg.icons.tint(dlg.icons.zoomIn, theme.muted); sourceSize.width: 15; sourceSize.height: 15 }
                        }
                        Label {
                            text: "The grid remembers this size between sessions."
                            color: theme.muted; font.pixelSize: 12
                        }
                    }

                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.separator }

                    ColumnLayout {
                        spacing: 8; Layout.fillWidth: true
                        Label { text: "Open the library in"; font.pixelSize: 15; font.bold: true; color: theme.text }
                        RowLayout {
                            spacing: 8
                            Repeater {
                                model: [["years", "Years"], ["months", "Months"], ["days", "Days"], ["all", "All Photos"]]
                                delegate: Rectangle {
                                    required property var modelData
                                    readonly property bool on: dlg.startupView === modelData[0]
                                    implicitWidth: pill.width + 24; height: 30; radius: 15
                                    color: on ? theme.accent : theme.field
                                    border.color: on ? theme.accent : theme.separator
                                    Label {
                                        id: pill
                                        anchors.centerIn: parent
                                        text: modelData[1]
                                        color: on ? "#ffffff" : theme.text
                                        font.pixelSize: 12
                                    }
                                    TapHandler { onTapped: dlg.pickView(modelData[0]) }
                                }
                            }
                        }
                    }
                }
            }

            // ===== Sharing ============================================================
            Flickable {
                contentHeight: shareCol.height + 48
                clip: true
                ColumnLayout {
                    id: shareCol
                    x: 24; y: 24
                    width: parent.width - 48
                    spacing: 14

                    Label { text: "Connect your phone"; font.pixelSize: 15; font.bold: true; color: theme.text }
                    Label {
                        text: "On the phone, open Photo Wagon, tap ⚙ then “Scan QR code”, and point it here. Photos it sends land in this library."
                        color: theme.muted; font.pixelSize: 12
                        wrapMode: Text.WordWrap; Layout.fillWidth: true
                    }
                    Rectangle {
                        Layout.alignment: Qt.AlignHCenter
                        width: 240; height: 240; radius: 6; color: "white"
                        Image {
                            anchors.centerIn: parent
                            source: dlg.pairingData.enabled ? dlg.pairingData.qrImage : ""
                            smooth: false; fillMode: Image.Pad
                        }
                        Label { anchors.centerIn: parent; visible: !dlg.pairingData.enabled; text: "starting…"; color: "black" }
                    }
                    TextField {
                        visible: dlg.pairingData.enabled
                        text: dlg.pairingData.enabled ? dlg.pairingData.code : ""
                        readOnly: true; selectByMouse: true; font.pixelSize: 11
                        Layout.fillWidth: true
                    }

                    // paired phones
                    Rectangle { visible: dlg.devicesData.length > 0; Layout.fillWidth: true; height: 1; color: theme.separator }
                    Label { visible: dlg.devicesData.length > 0; text: "Paired phones"; color: theme.muted; font.pixelSize: 11; font.bold: true }
                    Repeater {
                        model: dlg.devicesData
                        delegate: RowLayout {
                            required property var modelData
                            Layout.fillWidth: true; spacing: 8
                            TextField {
                                text: modelData.name; Layout.fillWidth: true; font.pixelSize: 13
                                background: Rectangle { color: "transparent" }
                                onEditingFinished: if (text.trim().length && text !== modelData.name) library.renameDevice(modelData.peerId, text.trim())
                            }
                            Label {
                                text: modelData.state
                                color: modelData.state === "active" ? "#3ecf8e" : modelData.state === "paused" ? "#e8a33d" : "#e5534b"
                                font.pixelSize: 11
                            }
                            Button {
                                text: modelData.state === "paused" ? "Resume" : "Pause"; flat: true
                                onClicked: modelData.state === "paused" ? library.resumeDevice(modelData.peerId) : library.pauseDevice(modelData.peerId)
                            }
                            Button {
                                text: modelData.state === "revoked" ? "Forget" : "Revoke"; flat: true
                                onClicked: modelData.state === "revoked" ? library.forgetDevice(modelData.peerId) : library.revokeDevice(modelData.peerId)
                            }
                        }
                    }

                    // other computers
                    Rectangle { Layout.fillWidth: true; height: 1; color: theme.separator }
                    RowLayout {
                        Layout.fillWidth: true
                        ColumnLayout {
                            spacing: 2; Layout.fillWidth: true
                            Label { text: "Other computers"; color: theme.text; font.pixelSize: 13 }
                            Label { text: "Sync this library with your other machines."; color: theme.muted; font.pixelSize: 11 }
                        }
                        Button { text: "Manage…"; onClicked: dlg.manageComputers() }
                    }
                }
            }
        }
    }
}
