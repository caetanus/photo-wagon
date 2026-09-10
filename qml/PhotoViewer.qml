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
    /// The naming popup's body (a plain Item: headless captures can grab it).
    property alias namerBody: namerBody

    /// Opens "Who is this?" on the first face with `text` typed (capture hook).
    function openNamer(text) {
        if (!faces.length) return
        namer.faceId = faces[0].id; namer.currentName = faces[0].name || ""; namer.personId = faces[0].personId || 0
        namer.open()
        nameField.text = text
    }

    signal closed()
    signal openIndex(int index)
    signal nameFace(int faceId, int personId, string name)
    signal notAFace(int faceId)
    signal favorite(int id)
    signal setKind(int id, string kind)
    signal setCover(int personId, int faceId)
    signal fullscreenToggle()
    signal contextMenu(int id, string path, bool favorite)
    /// parsed library.candidates, for the naming popup
    property var candidates: ({ faceId: 0, people: [] })
    property bool fullscreen: false

    // ---- zoom: wheel, double-click, +/-/0; drag to pan when zoomed in ----------------
    property real zoom: 1
    property real panX: 0
    property real panY: 0
    function setZoom(z) {
        zoom = Math.max(1, Math.min(8, z))
        if (zoom === 1) { panX = 0; panY = 0 }
    }
    function resetZoom() { zoom = 1; panX = 0; panY = 0 }
    onPhotoChanged: resetZoom()

    readonly property int currentIndex: {
        if (!photo) return -1
        for (let i = 0; i < items.length; i++) if (items[i].id === photo.id) return i
        return -1
    }

    Rectangle { anchors.fill: parent; color: viewer.fullscreen ? "black" : theme.viewerBg }

    focus: visible
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) {
            if (viewer.zoom !== 1) viewer.resetZoom()
            else if (viewer.fullscreen) viewer.fullscreenToggle()
            else viewer.closed()
            event.accepted = true
        }
        else if (event.key === Qt.Key_Left) { viewer.step(-1); event.accepted = true }
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Space) { viewer.step(1); event.accepted = true }
        else if (event.key === Qt.Key_I) { viewer.infoOpen = !viewer.infoOpen; event.accepted = true }
        else if (event.key === Qt.Key_F || event.key === Qt.Key_F11) { viewer.fullscreenToggle(); event.accepted = true }
        else if (event.key === Qt.Key_Plus || event.key === Qt.Key_Equal) { viewer.setZoom(viewer.zoom * 1.25); event.accepted = true }
        else if (event.key === Qt.Key_Minus) { viewer.setZoom(viewer.zoom / 1.25); event.accepted = true }
        else if (event.key === Qt.Key_0) { viewer.resetZoom(); event.accepted = true }
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
        anchors.bottom: caption.top

        Image {
            id: image
            width: stage.width - 24
            height: stage.height - 24
            x: 12 + viewer.panX
            y: 12 + viewer.panY
            scale: viewer.zoom
            transformOrigin: Item.Center
            source: viewer.photo ? viewer.photo.fileUrl : ""
            asynchronous: true
            fillMode: Image.PreserveAspectFit
            autoTransform: true
            smooth: true
            mipmap: true
            // Decode scaled to fit 4096²: a 108 MP phone photo is 434 MB decoded, over
            // Qt's 256 MB image limit, and would not open at all; the JPEG reader scales
            // while decoding, so this is also faster and lighter.
            sourceSize.width: 4096
            sourceSize.height: 4096
        }
        HoverHandler { id: stageHover }
        BusyIndicator { anchors.centerIn: parent; running: image.status === Image.Loading; visible: running }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: (ev) => { viewer.setZoom(viewer.zoom * (ev.angleDelta.y > 0 ? 1.15 : 1 / 1.15)); ev.accepted = true }
        }
        PinchHandler {
            target: null
            onScaleChanged: (delta) => viewer.setZoom(viewer.zoom * delta)
        }
        DragHandler {
            target: null
            enabled: viewer.zoom > 1
            property real startX: 0
            property real startY: 0
            onActiveChanged: if (active) { startX = viewer.panX; startY = viewer.panY }
            onTranslationChanged: { viewer.panX = startX + translation.x; viewer.panY = startY + translation.y }
        }
        TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: viewer.setZoom(viewer.zoom === 1 ? 2.5 : 1)
        }
        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: if (viewer.photo) viewer.contextMenu(viewer.photo.id, viewer.photo.path || "", viewer.photo.favorite === true)
        }

        // face circles
        Item {
            id: overlay
            visible: image.status === Image.Ready && viewer.zoom === 1 && (stageHover.hovered || namer.opened)
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
                    TapHandler { onTapped: { namer.faceId = fbox.modelData.id; namer.currentName = fbox.modelData.name || ""; namer.personId = fbox.modelData.personId || 0; namer.open() } }
                }
            }
        }

        // arrows
        component Arrow: Rectangle {
            property string icon
            property bool enabledArrow: true
            width: 44; height: 44; radius: 22
            color: Qt.rgba(0, 0, 0, 0.45)
            visible: enabledArrow
            opacity: stageHover.hovered ? 0.95 : 0.35
            Behavior on opacity { NumberAnimation { duration: 120 } }
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

    // ---- caption: date · camera · size · file, always in view ----------------------
    Rectangle {
        id: caption
        anchors.left: parent.left
        anchors.right: info.visible ? info.left : parent.right
        anchors.bottom: strip.visible ? strip.top : parent.bottom
        height: 30
        color: theme.viewerBg
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 18
            Label {
                text: viewer.photo ? viewer.formatDate(viewer.photo.takenAt) : ""
                color: theme.text
                font.pixelSize: 12
            }
            Label {
                visible: text.length > 0
                text: viewer.photo && viewer.photo.camera ? viewer.photo.camera : ""
                color: theme.muted
                font.pixelSize: 12
                elide: Text.ElideRight
                Layout.maximumWidth: 240
            }
            Label {
                text: viewer.photo ? viewer.photo.width + " × " + viewer.photo.height : ""
                color: theme.muted
                font.pixelSize: 12
            }
            Label {
                text: viewer.photo ? viewer.formatSize(viewer.photo.size) : ""
                color: theme.muted
                font.pixelSize: 12
            }
            Label {
                visible: viewer.photo && viewer.photo.kind && viewer.photo.kind !== "photo" ? true : false
                text: viewer.photo && viewer.photo.kind === "screenshot" ? "Screenshot" : "Meme"
                color: theme.muted
                font.pixelSize: 12
            }
            Item { Layout.fillWidth: true }
            Label {
                text: viewer.photo ? viewer.photo.path : ""
                color: theme.muted
                font.pixelSize: 12
                elide: Text.ElideMiddle
                Layout.maximumWidth: 420
                Layout.fillWidth: true
                horizontalAlignment: Text.AlignRight
            }
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
                RowLayout {
                    Layout.fillWidth: true
                    Label { text: "Type"; color: theme.muted; font.pixelSize: 12; Layout.preferredWidth: 80 }
                    ComboBox {
                        id: kindBox
                        Layout.fillWidth: true
                        font.pixelSize: 12
                        model: ["Photo", "Screenshot", "Meme"]
                        readonly property var kinds: ["photo", "screenshot", "meme"]
                        currentIndex: viewer.photo && viewer.photo.kind ? Math.max(0, kinds.indexOf(viewer.photo.kind)) : 0
                        onActivated: (i) => { if (viewer.photo && kinds[i] !== viewer.photo.kind) viewer.setKind(viewer.photo.id, kinds[i]) }
                    }
                    Label {
                        visible: viewer.photo && viewer.photo.kindBy === "user"
                        text: "chosen by you"
                        color: theme.muted
                        font.pixelSize: 10
                    }
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
                                TapHandler { onTapped: { namer.faceId = pf.modelData.id; namer.currentName = pf.modelData.name || ""; namer.personId = pf.modelData.personId || 0; namer.open() } }
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
        property int personId: 0
        // the named people, alphabetical, narrowed by what is typed (prefix of a word first);
        // with nothing typed, the likely ones (closest to this face) come first
        readonly property var matches: {
            const q = nameField.text.trim().toLowerCase()
            const named = viewer.people.filter(p => p.name)
            if (!q.length && viewer.candidates.faceId === namer.faceId && viewer.candidates.people.length) {
                const likely = viewer.candidates.people.filter(p => p.name && p.similarity >= 0.3)
                const seen = {}
                likely.forEach(p => seen[p.id] = true)
                const rest = named.filter(p => !seen[p.id]).sort((a, b) => a.name.localeCompare(b.name, Qt.locale().name, { sensitivity: "base" }))
                return likely.concat(rest)
            }
            const score = p => {
                const n = p.name.toLowerCase()
                if (!q.length) return 0
                if (n.startsWith(q)) return 0
                if (n.split(/\s+/).some(w => w.startsWith(q))) return 1
                if (n.includes(q)) return 2
                return -1
            }
            return named.filter(p => score(p) >= 0)
                        .sort((a, b) => score(a) - score(b) || a.name.localeCompare(b.name, Qt.locale().name, { sensitivity: "base" }))
        }
        readonly property var exact: matches.find(p => p.name.toLowerCase() === nameField.text.trim().toLowerCase()) || null
        /// keyboard cursor in the list (-1 = none); ListView.currentIndex would jump to 0 on its own
        property int cursor: -1
        modal: true
        anchors.centerIn: parent
        width: 400
        padding: 16
        background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 10 }
        onOpened: { nameField.text = currentName; nameField.forceActiveFocus(); nameField.selectAll(); cursor = -1; library.loadCandidates(faceId) }
        ColumnLayout {
            id: namerBody
            anchors.fill: parent
            spacing: 10
            Label { text: "Who is this?"; font.bold: true; color: theme.text }
            TextField {
                id: nameField
                placeholderText: "Type a name"
                Layout.fillWidth: true
                // Return: the highlighted person, the exact name, or a new name
                onAccepted: {
                    if (namer.cursor >= 0 && namer.cursor < namer.matches.length)
                        viewer.nameFace(namer.faceId, namer.matches[namer.cursor].id, "")
                    else if (namer.exact)
                        viewer.nameFace(namer.faceId, namer.exact.id, "")
                    else if (text.trim().length)
                        viewer.nameFace(namer.faceId, 0, text.trim())
                    else
                        return
                    namer.close()
                }
                Keys.onDownPressed: { if (namer.cursor < namer.matches.length - 1) namer.cursor++; peopleList.positionViewAtIndex(namer.cursor, ListView.Contain) }
                Keys.onUpPressed: if (namer.cursor > -1) namer.cursor--
                onTextChanged: namer.cursor = -1
            }
            Label {
                visible: namer.matches.length > 0
                text: nameField.text.trim().length && !namer.exact ? "Already known, matching:" : "Someone already known:"
                color: theme.muted
                font.pixelSize: 12
            }
            ListView {
                id: peopleList
                visible: namer.matches.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(280, namer.matches.length * 40)
                clip: true
                model: namer.matches
                ScrollBar.vertical: ScrollBar { }
                delegate: Item {
                    id: personRow
                    required property var modelData
                    required property int index
                    width: ListView.view.width
                    height: 40
                    readonly property bool lit: index === namer.cursor || rowHover.hovered
                    Rectangle { anchors.fill: parent; radius: 6; color: personRow.lit ? theme.hover : "transparent" }
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 10
                        spacing: 10
                        Item {
                            width: 30; height: 30
                            Rectangle { anchors.fill: parent; radius: 15; color: theme.tile }
                            Image {
                                anchors.fill: parent
                                source: personRow.modelData.coverUrl || ""
                                fillMode: Image.PreserveAspectCrop
                                sourceSize.width: 60; sourceSize.height: 60
                                asynchronous: true
                            }
                            Image {
                                anchors.fill: parent
                                source: icons.ringMask(personRow.lit ? theme.hover : theme.panel)
                                sourceSize.width: 30; sourceSize.height: 30
                            }
                        }
                        Label {
                            text: personRow.modelData.name
                            color: theme.text
                            font.pixelSize: 13
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                        Label {
                            visible: personRow.modelData.similarity !== undefined
                            text: personRow.modelData.similarity !== undefined ? Math.round(personRow.modelData.similarity * 100) + "%" : ""
                            color: theme.accent
                            font.pixelSize: 11
                        }
                        Label {
                            text: personRow.modelData.faces + (personRow.modelData.faces === 1 ? " photo" : " photos")
                            color: theme.muted
                            font.pixelSize: 11
                        }
                    }
                    HoverHandler { id: rowHover }
                    TapHandler { onTapped: { viewer.nameFace(namer.faceId, personRow.modelData.id, ""); namer.close() } }
                }
            }
            Label {
                visible: namer.matches.length === 0 && nameField.text.trim().length > 0
                text: "Nobody called that yet — Save adds a new person."
                color: theme.muted
                font.pixelSize: 12
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
            }
            RowLayout {
                Button { text: "Nobody"; flat: true; onClicked: { viewer.nameFace(namer.faceId, 0, ""); namer.close() } }
                Button { text: "Not a face"; flat: true; onClicked: { viewer.notAFace(namer.faceId); namer.close() } }
                Button {
                    visible: namer.personId > 0
                    text: "Use as portrait"; flat: true
                    ToolTip.text: "This face becomes " + namer.currentName + "'s picture in People"; ToolTip.visible: hovered
                    onClicked: { viewer.setCover(namer.personId, namer.faceId); namer.close() }
                }
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; onClicked: namer.close() }
                Button {
                    text: namer.exact ? "Use " + namer.exact.name : "Save"
                    enabled: nameField.text.trim().length > 0
                    onClicked: nameField.accepted()
                }
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
