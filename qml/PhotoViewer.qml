import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// One photo, in the window (the sidebar stays). Arrows on hover, a filmstrip
// of the current page at the bottom, an Info panel on the right, face circles
// while the Info panel is open or the pointer is over the photo.
Item {
    id: viewer
    required property QtObject theme
    required property QtObject icons
    property var photo: null            // parsed library.current
    property var items: []              // the page's items, for the filmstrip
    property var faces: []
    property var people: []
    property bool infoOpen: false
    property bool showStrip: true

    signal closed()
    signal openIndex(int index)
    signal nameFace(int faceId, int personId, string name)
    signal notAFace(int faceId)
    signal favorite(int id)

    readonly property int currentIndex: {
        if (!photo) return -1
        for (let i = 0; i < items.length; i++) if (items[i].id === photo.id) return i
        return -1
    }

    Rectangle { anchors.fill: parent; color: theme.viewerBg }

    focus: visible
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) { viewer.closed(); event.accepted = true }
        else if (event.key === Qt.Key_Left) { viewer.step(-1); event.accepted = true }
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Space) { viewer.step(1); event.accepted = true }
        else if (event.key === Qt.Key_I) { viewer.infoOpen = !viewer.infoOpen; event.accepted = true }
    }

    function step(delta) {
        const i = currentIndex + delta
        if (i >= 0 && i < items.length) openIndex(i)
    }

    // ---- the photo ------------------------------------------------------------------
    Item {
        id: stage
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: info.visible ? info.left : parent.right
        anchors.bottom: strip.visible ? strip.top : parent.bottom

        Image {
            id: image
            anchors.fill: parent
            anchors.margins: 12
            source: viewer.photo ? viewer.photo.fileUrl : ""
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            autoTransform: true
            smooth: true
            mipmap: true
        }
        HoverHandler { id: stageHover }
        BusyIndicator { anchors.centerIn: parent; running: image.status === Image.Loading; visible: running }

        // face circles
        Item {
            id: overlay
            visible: image.status === Image.Ready && (stageHover.hovered || namer.opened)
            readonly property real px: image.x + (image.width - image.paintedWidth) / 2
            readonly property real py: image.y + (image.height - image.paintedHeight) / 2
            Repeater {
                model: viewer.faces
                delegate: Item {
                    id: fbox
                    required property var modelData
                    readonly property real bw: modelData.w * image.paintedWidth
                    readonly property real bh: modelData.h * image.paintedHeight
                    readonly property real d: Math.max(bw, bh) * 1.25
                    x: overlay.px + modelData.x * image.paintedWidth + bw / 2 - d / 2
                    y: overlay.py + modelData.y * image.paintedHeight + bh / 2 - d / 2
                    width: d; height: d
                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: "transparent"
                        border.color: "white"
                        border.width: 2
                        opacity: 0.9
                    }
                    Rectangle {
                        anchors.top: parent.bottom
                        anchors.horizontalCenter: parent.horizontalCenter
                        anchors.topMargin: 4
                        width: tag.implicitWidth + 14
                        height: tag.implicitHeight + 6
                        radius: height / 2
                        color: fbox.modelData.name ? Qt.rgba(1, 1, 1, 0.92) : theme.accent
                        Label {
                            id: tag
                            anchors.centerIn: parent
                            text: fbox.modelData.name || "Name"
                            color: fbox.modelData.name ? "#1d1d1f" : "white"
                            font.pixelSize: 12
                        }
                    }
                    TapHandler { onTapped: { namer.faceId = fbox.modelData.id; namer.currentName = fbox.modelData.name || ""; namer.open() } }
                }
            }
        }

        // arrows
        component Arrow: Rectangle {
            property string icon
            property bool enabledArrow: true
            width: 44; height: 44; radius: 22
            color: Qt.rgba(0, 0, 0, 0.45)
            visible: stageHover.hovered && enabledArrow
            Image { anchors.centerIn: parent; source: icons.tint(icon, "white"); sourceSize.width: 22; sourceSize.height: 22 }
        }
        Arrow {
            icon: icons.chevronLeft
            enabledArrow: viewer.currentIndex > 0
            anchors.left: parent.left; anchors.leftMargin: 16; anchors.verticalCenter: parent.verticalCenter
            TapHandler { onTapped: viewer.step(-1) }
        }
        Arrow {
            icon: icons.chevronRight
            enabledArrow: viewer.currentIndex >= 0 && viewer.currentIndex < viewer.items.length - 1
            anchors.right: parent.right; anchors.rightMargin: 16; anchors.verticalCenter: parent.verticalCenter
            TapHandler { onTapped: viewer.step(1) }
        }
    }

    // ---- filmstrip ------------------------------------------------------------------
    Rectangle {
        id: strip
        visible: viewer.showStrip && viewer.items.length > 1
        anchors.left: parent.left
        anchors.right: info.visible ? info.left : parent.right
        anchors.bottom: parent.bottom
        height: 72
        color: theme.viewerBg
        ListView {
            id: stripView
            anchors.fill: parent
            anchors.margins: 8
            orientation: ListView.Horizontal
            spacing: 4
            clip: true
            model: viewer.items
            currentIndex: viewer.currentIndex
            highlightMoveDuration: 120
            preferredHighlightBegin: width / 2 - 28
            preferredHighlightEnd: width / 2 + 28
            highlightRangeMode: ListView.ApplyRange
            delegate: Item {
                required property var modelData
                required property int index
                width: 56; height: 56
                Rectangle { anchors.fill: parent; color: theme.tile; radius: 3 }
                Image {
                    anchors.fill: parent
                    source: modelData.thumbUrl || ""
                    asynchronous: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 112; sourceSize.height: 112
                    opacity: index === viewer.currentIndex ? 1 : 0.7
                }
                Rectangle {
                    anchors.fill: parent
                    radius: 3
                    color: "transparent"
                    border.color: theme.accent
                    border.width: index === viewer.currentIndex ? 2 : 0
                }
                TapHandler { onTapped: viewer.openIndex(index) }
            }
        }
    }

    // ---- info panel -----------------------------------------------------------------
    Rectangle {
        id: info
        visible: viewer.infoOpen
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: 300
        color: theme.panel
        Rectangle { anchors.left: parent.left; width: 1; height: parent.height; color: theme.separator }

        Flickable {
            anchors.fill: parent
            anchors.margins: 16
            contentHeight: infoColumn.height
            clip: true
            ColumnLayout {
                id: infoColumn
                width: parent.width
                spacing: 10
                RowLayout {
                    Label { text: "Info"; font.pixelSize: 15; font.bold: true; color: theme.text; Layout.fillWidth: true }
                    ToolButton {
                        icon.source: icons.tint(icons.close, theme.muted)
                        icon.width: 14; icon.height: 14
                        flat: true
                        onClicked: viewer.infoOpen = false
                    }
                }
                Label {
                    text: viewer.photo ? viewer.fileName(viewer.photo.path) : ""
                    color: theme.text
                    font.pixelSize: 13
                    font.bold: true
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }
                Label {
                    text: viewer.photo ? viewer.formatDate(viewer.photo.takenAt) : ""
                    color: theme.text
                    font.pixelSize: 13
                }
                Rectangle { Layout.fillWidth: true; height: 1; color: theme.separator }
                component InfoRow: RowLayout {
                    property string label
                    property string value
                    visible: value.length > 0
                    Layout.fillWidth: true
                    Label { text: label; color: theme.muted; font.pixelSize: 12; Layout.preferredWidth: 80 }
                    Label { text: value; color: theme.text; font.pixelSize: 12; elide: Text.ElideMiddle; Layout.fillWidth: true }
                }
                InfoRow { label: "Camera"; value: viewer.photo && viewer.photo.camera ? viewer.photo.camera : "" }
                InfoRow {
                    label: "Size"
                    value: viewer.photo ? viewer.megapixels(viewer.photo) + "  " + viewer.photo.width + " × " + viewer.photo.height : ""
                }
                InfoRow { label: "File"; value: viewer.photo ? viewer.formatSize(viewer.photo.size) : "" }
                InfoRow { label: "Folder"; value: viewer.photo && viewer.photo.path ? viewer.folderOf(viewer.photo.path) : "" }
                InfoRow { label: "Location"; value: viewer.photo && viewer.photo.lat !== null ? viewer.photo.lat.toFixed(4) + ", " + viewer.photo.lon.toFixed(4) : "" }
                Rectangle { Layout.fillWidth: true; height: 1; color: theme.separator }
                Label { text: "People"; color: theme.muted; font.pixelSize: 12; font.bold: true }
                Flow {
                    Layout.fillWidth: true
                    spacing: 10
                    Repeater {
                        model: viewer.faces
                        delegate: Column {
                            id: pf
                            required property var modelData
                            spacing: 4
                            width: 60
                            Item {
                                width: 56; height: 56
                                anchors.horizontalCenter: parent.horizontalCenter
                                Image {
                                    anchors.fill: parent
                                    source: pf.modelData.thumbUrl || ""
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize.width: 112; sourceSize.height: 112
                                    asynchronous: true
                                }
                                Image { // round mask in the panel colour
                                    anchors.fill: parent
                                    source: icons.ringMask(theme.panel)
                                    sourceSize.width: 56
                                    sourceSize.height: 56
                                    smooth: true
                                }
                                Rectangle { anchors.fill: parent; radius: width / 2; color: "transparent"; border.color: theme.separator; border.width: 1 }
                                TapHandler { onTapped: { namer.faceId = pf.modelData.id; namer.currentName = pf.modelData.name || ""; namer.open() } }
                            }
                            Label {
                                anchors.horizontalCenter: parent.horizontalCenter
                                text: pf.modelData.name || "Name"
                                color: pf.modelData.name ? theme.text : theme.accent
                                font.pixelSize: 11
                                elide: Text.ElideRight
                                width: 60
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                    Label { visible: viewer.faces.length === 0; text: "No faces found"; color: theme.muted; font.pixelSize: 12 }
                }
            }
        }
    }

    // ---- "Who is this?" --------------------------------------------------------------
    Popup {
        id: namer
        property int faceId: 0
        property string currentName: ""
        // the known people, narrowed by what is typed (named ones only once typing starts)
        readonly property var matches: {
            const q = nameField.text.trim().toLowerCase()
            const all = viewer.people
            if (!q.length) return all.slice(0, 8)
            return all.filter(p => p.name && p.name.toLowerCase().includes(q)).slice(0, 8)
        }
        modal: true
        anchors.centerIn: parent
        width: 320
        padding: 16
        background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 10 }
        onOpened: { nameField.text = currentName; nameField.forceActiveFocus(); nameField.selectAll() }
        ColumnLayout {
            anchors.fill: parent
            spacing: 10
            Label { text: "Who is this?"; font.bold: true; color: theme.text }
            TextField {
                id: nameField
                placeholderText: "Name"
                Layout.fillWidth: true
                // Return: the one matching person, or a new name
                onAccepted: {
                    const m = namer.matches
                    if (m.length === 1 && m[0].name && m[0].name.toLowerCase() === text.trim().toLowerCase())
                        viewer.nameFace(namer.faceId, m[0].id, "")
                    else
                        viewer.nameFace(namer.faceId, 0, text)
                    namer.close()
                }
            }
            Label {
                visible: namer.matches.length > 0
                text: nameField.text.trim().length ? "Already known:" : "Someone already known:"
                color: theme.muted
                font.pixelSize: 12
            }
            ListView {
                visible: namer.matches.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(200, namer.matches.length * 32)
                clip: true
                model: namer.matches
                delegate: ItemDelegate {
                    required property var modelData
                    width: ListView.view.width
                    height: 32
                    text: (modelData.name || "Unnamed") + "  ·  " + modelData.faces
                    onClicked: { viewer.nameFace(namer.faceId, modelData.id, ""); namer.close() }
                }
            }
            RowLayout {
                Button { text: "Nobody"; flat: true; onClicked: { viewer.nameFace(namer.faceId, 0, ""); namer.close() } }
                Button { text: "Not a face"; flat: true; onClicked: { viewer.notAFace(namer.faceId); namer.close() } }
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; onClicked: namer.close() }
                Button { text: "Save"; enabled: nameField.text.trim().length > 0; onClicked: { viewer.nameFace(namer.faceId, 0, nameField.text); namer.close() } }
            }
        }
    }

    function fileName(p) { return p ? p.substring(p.lastIndexOf("/") + 1) : "" }
    function folderOf(p) { return p ? p.substring(0, p.lastIndexOf("/")) : "" }
    function formatDate(iso) {
        if (!iso) return "Unknown date"
        const d = new Date(iso)
        return isNaN(d.getTime()) ? iso : d.toLocaleString(Qt.locale(), "d MMMM yyyy  HH:mm")
    }
    function formatSize(bytes) {
        if (!bytes) return ""
        if (bytes > 1048576) return (bytes / 1048576).toFixed(1) + " MB"
        if (bytes > 1024) return Math.round(bytes / 1024) + " KB"
        return bytes + " B"
    }
    function megapixels(p) {
        const mp = p.width * p.height / 1e6
        return mp >= 1 ? mp.toFixed(mp >= 10 ? 0 : 1) + " MP" : ""
    }
}
