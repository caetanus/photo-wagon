import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The editing panel beside the photo: Filters (a strip of the photo under every
// preset), Adjust (sliders), Crop (rotate, flip, aspect). Nothing here touches the
// file: the viewer asks the core for previews and, on Save, for the rendered result.
Rectangle {
    id: panel
    required property QtObject theme
    required property QtObject icons
    /// the working edits object (see core/edit/edits.d for the fields)
    property var edits: ({})
    property string tool: "filters"
    /// [{name, url, edits}] from photo.presetPreviews, for this photo
    property var presetItems: []
    property bool hasSavedEdits: false
    property bool busy: false

    signal changed()
    signal pick(var edits)
    signal rotate(int degrees)
    signal flip(string axis)
    signal aspect(real ratio)
    signal resetCrop()
    signal save()
    signal saveCopy()
    signal revert()
    signal cancel()

    width: 320
    color: theme.panel

    function set(key, value) { const e = Object.assign({}, panel.edits); e[key] = value; e.preset = null; panel.pick(e) }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0
        clip: true

        // tabs
        RowLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 4
            Repeater {
                model: [ { key: "filters", title: "Filters" }, { key: "adjust", title: "Adjust" }, { key: "crop", title: "Crop" } ]
                Rectangle {
                    required property var modelData
                    Layout.fillWidth: true
                    height: 30
                    radius: 6
                    color: panel.tool === modelData.key ? theme.selection : (tabHover.hovered ? theme.hover : "transparent")
                    Label { anchors.centerIn: parent; text: modelData.title; color: theme.text; font.pixelSize: 13; font.bold: panel.tool === modelData.key }
                    HoverHandler { id: tabHover }
                    TapHandler { onTapped: panel.tool = modelData.key }
                }
            }
        }
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.separator }

        // ---- filters ---------------------------------------------------------------
        GridView {
            visible: panel.tool === "filters"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 8
            clip: true
            cellWidth: Math.floor(width / 3)
            cellHeight: cellWidth + 22
            model: panel.presetItems
            ScrollBar.vertical: ScrollBar { }
            delegate: Item {
                required property var modelData
                width: GridView.view.cellWidth
                height: GridView.view.cellHeight
                readonly property bool current: (panel.edits.preset || "Original") === modelData.name
                Rectangle {
                    anchors.fill: parent
                    anchors.margins: 4
                    radius: 8
                    color: current ? theme.selection : (presetHover.hovered ? theme.hover : "transparent")
                    Image {
                        id: presetImage
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.margins: 4
                        height: width
                        source: modelData.url || ""
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        cache: false
                        smooth: true
                        layer.enabled: true
                    }
                    Label {
                        anchors.top: presetImage.bottom
                        anchors.topMargin: 2
                        anchors.horizontalCenter: parent.horizontalCenter
                        text: modelData.name
                        color: theme.text
                        font.pixelSize: 11
                        font.bold: current
                    }
                    HoverHandler { id: presetHover }
                    TapHandler { onTapped: panel.pick(modelData.edits) }
                }
            }
            Label {
                visible: panel.presetItems.length === 0
                anchors.centerIn: parent
                text: panel.busy ? "Rendering the filters…" : "No previews"
                color: theme.muted
                font.pixelSize: 12
            }
        }

        // ---- adjust ----------------------------------------------------------------
        Flickable {
            visible: panel.tool === "adjust"
            Layout.fillWidth: true
            Layout.fillHeight: true
            contentHeight: adjustColumn.implicitHeight + 24
            clip: true
            ScrollBar.vertical: ScrollBar { }
            ColumnLayout {
                id: adjustColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: 16
                anchors.top: parent.top
                anchors.topMargin: 12
                spacing: 6
                component Adjust: ColumnLayout {
                    required property string key
                    required property string title
                    property real from: -1
                    property real to: 1
                    Layout.fillWidth: true
                    spacing: 0
                    RowLayout {
                        Layout.fillWidth: true
                        Label { text: title; color: theme.text; font.pixelSize: 12; Layout.fillWidth: true }
                        Label {
                            text: Math.round((panel.edits[key] || 0) * 100)
                            color: theme.muted; font.pixelSize: 11
                            font.features: { "tnum": 1 }
                        }
                    }
                    Slider {
                        id: slider
                        Layout.fillWidth: true
                        from: parent.from; to: parent.to
                        value: panel.edits[key] || 0
                        onMoved: panel.set(key, Math.abs(value) < 0.02 ? 0 : value)
                        TapHandler { onDoubleTapped: panel.set(key, 0) }   // double-click resets
                    }
                }
                Adjust { key: "brightness"; title: "Brightness" }
                Adjust { key: "contrast"; title: "Contrast" }
                Adjust { key: "saturation"; title: "Saturation" }
                Adjust { key: "warmth"; title: "Warmth" }
                Adjust { key: "fade"; title: "Fade"; from: 0 }
                Adjust { key: "vignette"; title: "Vignette"; from: 0 }
                Adjust { key: "sharpen"; title: "Sharpen"; from: 0 }
                Adjust { key: "sepia"; title: "Sepia"; from: 0 }
                Label { text: "Double-click a slider to reset it."; color: theme.muted; font.pixelSize: 11; Layout.topMargin: 6 }
            }
        }

        // ---- crop & rotate ----------------------------------------------------------
        ColumnLayout {
            visible: panel.tool === "crop"
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.maximumWidth: panel.width
            Layout.margins: 16
            spacing: 12
            Label { text: "Rotate"; color: theme.muted; font.pixelSize: 11; font.bold: true }
            Flow {
                Layout.fillWidth: true
                spacing: 6
                Button { text: "↺ 90°"; onClicked: panel.rotate(-90) }
                Button { text: "↻ 90°"; onClicked: panel.rotate(90) }
                Button { text: "Flip ↔"; onClicked: panel.flip("h") }
                Button { text: "Flip ↕"; onClicked: panel.flip("v") }
            }
            Label { text: "Crop"; color: theme.muted; font.pixelSize: 11; font.bold: true; Layout.topMargin: 6 }
            Label { text: "Drag the corners or the frame on the photo."; color: theme.muted; font.pixelSize: 12 }
            Flow {
                Layout.fillWidth: true
                Layout.maximumWidth: panel.width - 32
                spacing: 6
                Repeater {
                    model: [ { t: "Free", r: 0 }, { t: "Square", r: 1 }, { t: "4:3", r: 4 / 3 }, { t: "3:2", r: 3 / 2 }, { t: "16:9", r: 16 / 9 }, { t: "3:4", r: 3 / 4 }, { t: "9:16", r: 9 / 16 } ]
                    Button { required property var modelData; text: modelData.t; onClicked: panel.aspect(modelData.r) }
                }
            }
            Button { text: "Reset crop"; flat: true; onClicked: panel.resetCrop() }
            Item { Layout.fillHeight: true }
        }

        // ---- footer ------------------------------------------------------------------
        Rectangle { Layout.fillWidth: true; height: 1; color: theme.separator }
        ColumnLayout {
            Layout.fillWidth: true
            Layout.margins: 12
            spacing: 8
            RowLayout {
                Layout.fillWidth: true
                Layout.maximumWidth: panel.width - 24
                Button { text: "Cancel"; onClicked: panel.cancel() }
                Item { Layout.fillWidth: true }
                Button { text: "Save as Copy"; onClicked: panel.saveCopy() }
                Button { text: "Save"; highlighted: true; onClicked: panel.save() }
            }
            Button {
                visible: panel.hasSavedEdits
                text: "Revert to original"
                flat: true
                Layout.alignment: Qt.AlignLeft
                onClicked: panel.revert()
            }
            Label {
                text: "The original file stays as it is; Save keeps the result in the library, Save as Copy writes a JPEG next to it."
                color: theme.muted
                font.pixelSize: 11
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
        }
    }
}
