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
    /// parsed library.photoTags: {id, scene, mood, by, scores: {scene: [{tag, prob}], mood: […]}}
    property var photoTags: ({ id: 0 })
    /// "Beach 48 %  (Group 38 %)" — the tag with its confidence, then the runner-up; "—" when nothing fits
    function tagLine(group) {
        if (!viewer.photo) return ""
        const t = viewer.photoTags && viewer.photoTags.id === viewer.photo.id ? viewer.photoTags : null
        const tag = t ? (t[group] || "") : (viewer.photo[group] || "")
        const by = t && t.by && t.by[group] === "user" ? " (yours)" : t && t.by && t.by[group] === "date" ? " (calendar)" : ""
        const sc = t && t.scores && t.scores[group] ? t.scores[group] : []
        const pct = g => g.tag + " " + Math.round(g.prob * 100) + " %"
        if (!tag) return sc.length ? "—  (" + pct(sc[0]) + ")" : "—"
        const own = sc.find(g => g.tag === tag)
        const other = sc.find(g => g.tag !== tag)
        return tag + by + (own ? "  " + Math.round(own.prob * 100) + " %" : "") + (other ? "  (" + pct(other) + ")" : "")
    }
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
    signal remove(var ids, bool permanent)
    signal renamePerson(int personId, string name)
    /// A chip of the tag strip was clicked: show every photo with it.
    signal filterTag(string group, string tag)
    signal filterPlace(string place, string country)
    signal filterKeyword(string keyword)
    signal addKeywords(int id, string text)
    signal removeKeyword(int id, string keyword)
    /// Editing: previews and results come back through `preview` / `presetPreviews` / the photo.
    signal previewRequest(int id, string editsJson)
    signal presetPreviewRequest(int id, string editsJson)
    signal applyEdits(int id, string editsJson)
    signal revertEdits(int id)
    signal saveCopy(int id, string editsJson)

    // ---- editing state -----------------------------------------------------------------
    property bool editing: false
    property int editingId: 0
    property string tool: "filters"
    property var edits: ({})
    property var presets: []
    property var preview: ({ id: 0 })
    property var presetPreviews: ({ id: 0, items: [] })
    property real cropAspect: 0
    readonly property var emptyEdits: ({ rotate: 0, flipH: false, flipV: false, crop: null, brightness: 0, contrast: 0,
                                         saturation: 0, warmth: 0, fade: 0, vignette: 0, sharpen: 0, sepia: 0, preset: null })
    function startEdit() {
        if (!viewer.photo || !viewer.photo.fileUrl) return
        viewer.resetZoom()
        viewer.edits = Object.assign({}, emptyEdits, viewer.photo.edits || {})
        viewer.editingId = viewer.photo.id
        viewer.editing = true
        viewer.requestPreview()
        viewer.presetPreviewRequest(viewer.photo.id, JSON.stringify(viewer.edits))
    }
    function endEdit() { viewer.editing = false; viewer.forceActiveFocus() }
    /// The edits the preview shows: while cropping, the whole rotated picture (the frame is drawn on top).
    function previewEdits() {
        const e = Object.assign({}, viewer.edits)
        if (viewer.tool === "crop") e.crop = null
        return e
    }
    function requestPreview() { previewDebounce.restart() }
    Timer { id: previewDebounce; interval: 120; onTriggered: if (viewer.editing && viewer.photo) viewer.previewRequest(viewer.photo.id, JSON.stringify(viewer.previewEdits())) }
    function setEdits(e) { viewer.edits = e; viewer.requestPreview() }
    onToolChanged: if (editing) requestPreview()
    /// Rotation swaps the crop frame's axes so it keeps framing the same pixels.
    function rotateBy(deg) {
        const e = Object.assign({}, viewer.edits)
        e.rotate = (((e.rotate || 0) + deg) % 360 + 360) % 360
        if (e.crop) {
            const c = e.crop
            e.crop = deg > 0 ? [1 - c[1] - c[3], c[0], c[3], c[2]] : [c[1], 1 - c[0] - c[2], c[3], c[2]]
        }
        viewer.setEdits(e)
        viewer.presetPreviewRequest(viewer.photo.id, JSON.stringify(e))
    }
    function flipBy(axis) {
        const e = Object.assign({}, viewer.edits)
        if (axis === "h") { e.flipH = !e.flipH; if (e.crop) e.crop = [1 - e.crop[0] - e.crop[2], e.crop[1], e.crop[2], e.crop[3]] }
        else { e.flipV = !e.flipV; if (e.crop) e.crop = [e.crop[0], 1 - e.crop[1] - e.crop[3], e.crop[2], e.crop[3]] }
        viewer.setEdits(e)
        viewer.presetPreviewRequest(viewer.photo.id, JSON.stringify(e))
    }
    /// A crop of the given aspect (0 = free), centred, as large as fits.
    function cropToAspect(ratio) {
        viewer.cropAspect = ratio
        const e = Object.assign({}, viewer.edits)
        if (ratio <= 0) { viewer.setEdits(e); return }
        const pw = viewer.paintedW, ph = viewer.paintedH
        if (pw <= 0 || ph <= 0) return
        let w = 1, h = 1
        if (pw / ph > ratio) w = (ph * ratio) / pw; else h = (pw / ratio) / ph
        e.crop = [(1 - w) / 2, (1 - h) / 2, w, h]
        viewer.setEdits(e)
    }
    function resetCrop() { const e = Object.assign({}, viewer.edits); e.crop = null; viewer.cropAspect = 0; viewer.setEdits(e) }

    // Right-click on a face: what to do with the tag.
    Menu {
        id: faceMenu
        property int faceId: 0
        property int personId: 0
        property string name: ""
        MenuItem { text: faceMenu.personId ? "Change who this is…" : "Name…"; onTriggered: { namer.faceId = faceMenu.faceId; namer.currentName = faceMenu.name; namer.personId = faceMenu.personId; namer.open() } }
        MenuItem { visible: faceMenu.personId > 0; height: visible ? implicitHeight : 0; text: "Rename " + faceMenu.name + "…"; onTriggered: { renamer.personId = faceMenu.personId; renamer.name = faceMenu.name; renamer.open() } }
        MenuItem { visible: faceMenu.personId > 0; height: visible ? implicitHeight : 0; text: "Use as portrait"; onTriggered: viewer.setCover(faceMenu.personId, faceMenu.faceId) }
        MenuSeparator { }
        MenuItem { visible: faceMenu.personId > 0; height: visible ? implicitHeight : 0; text: "Remove tag"; onTriggered: viewer.nameFace(faceMenu.faceId, 0, "") }
        MenuItem { text: "Not a face"; onTriggered: viewer.notAFace(faceMenu.faceId) }
    }
    /// capture hook: the face menu for the first face
    property alias faceMenuBody: faceMenu.contentItem
    function openFaceMenu() { if (faces.length) faceMenuFor(faces[0]) }
    function faceMenuFor(f) { faceMenu.faceId = f.id; faceMenu.personId = f.personId || 0; faceMenu.name = f.name || ""; faceMenu.popup() }

    // "Rename Patricia…": the person's name everywhere.
    Popup {
        id: renamer
        property int personId: 0
        property string name: ""
        modal: true
        anchors.centerIn: parent
        width: 320
        padding: 16
        background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 10 }
        onOpened: { renameField.text = name; renameField.forceActiveFocus(); renameField.selectAll() }
        ColumnLayout {
            anchors.fill: parent
            spacing: 10
            Label { text: "Rename " + renamer.name; font.bold: true; color: theme.text }
            TextField {
                id: renameField
                Layout.fillWidth: true
                placeholderText: "Name"
                onAccepted: { if (text.trim().length) viewer.renamePerson(renamer.personId, text.trim()); renamer.close() }
            }
            Label { text: "A name that already exists merges the two people."; color: theme.muted; font.pixelSize: 11; wrapMode: Text.WordWrap; Layout.fillWidth: true }
            RowLayout {
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; onClicked: renamer.close() }
                Button { text: "Rename"; highlighted: true; enabled: renameField.text.trim().length > 0; onClicked: renameField.accepted() }
            }
        }
    }
    /// parsed library.candidates, for the naming popup
    property var candidates: ({ faceId: 0, people: [] })
    /// parsed library.region: the visible part at full resolution while zoomed
    property var region: ({ id: 0 })
    signal loadRegion(int id, double x, double y, double w, double h, int px)
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
    onPhotoChanged: { if (editing && photo && photo.id === editingId) return; resetZoom(); if (editing) endEdit() }
    onZoomChanged: regionTimer.restart()
    onPanXChanged: regionTimer.restart()
    onPanYChanged: regionTimer.restart()

    // The painted picture on screen, after scale and pan.
    readonly property real paintedW: image.paintedWidth * zoom
    readonly property real paintedH: image.paintedHeight * zoom
    readonly property real paintedX: image.x + image.width / 2 - paintedW / 2
    readonly property real paintedY: image.y + image.height / 2 - paintedH / 2
    // The visible part of it, as fractions of the picture.
    function visibleRegion() {
        const x0 = Math.max(0, (0 - paintedX) / paintedW), y0 = Math.max(0, (0 - paintedY) / paintedH)
        const x1 = Math.min(1, (stage.width - paintedX) / paintedW), y1 = Math.min(1, (stage.height - paintedY) / paintedH)
        return { x: x0, y: y0, w: Math.max(0, x1 - x0), h: Math.max(0, y1 - y0) }
    }
    Timer {   // a pause after zooming or panning: ask for that part at full resolution
        id: regionTimer
        interval: 250
        onTriggered: {
            if (!viewer.photo || viewer.zoom <= 1.05 || image.paintedWidth <= 0) return
            const r = viewer.visibleRegion()
            if (r.w <= 0 || r.h <= 0) return
            const px = Math.ceil(Math.max(r.w * viewer.paintedW, r.h * viewer.paintedH) * Screen.devicePixelRatio)
            viewer.loadRegion(viewer.photo.id, r.x, r.y, r.w, r.h, Math.min(8192, px))
        }
    }

    readonly property int currentIndex: {
        if (!photo) return -1
        for (let i = 0; i < items.length; i++) if (items[i].id === photo.id) return i
        return -1
    }

    Rectangle { anchors.fill: parent; color: viewer.fullscreen ? "black" : theme.viewerBg }

    focus: visible
    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_E && !viewer.editing && viewer.photo) { viewer.startEdit(); event.accepted = true; return }
        if (event.key === Qt.Key_Escape) {
            if (viewer.editing) viewer.endEdit()
            else if (viewer.zoom !== 1) viewer.resetZoom()
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
        else if (event.key === Qt.Key_Delete && viewer.photo) { viewer.remove([viewer.photo.id], (event.modifiers & Qt.ShiftModifier) !== 0); event.accepted = true }
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
        anchors.right: info.visible ? info.left : editPanel.visible ? editPanel.left : parent.right
        anchors.bottom: caption.top

        Image {
            id: image
            width: stage.width - 24
            height: stage.height - 24
            x: 12 + viewer.panX
            y: 12 + viewer.panY
            scale: viewer.zoom
            transformOrigin: Item.Center
            // while editing: the core's preview of the current edits; otherwise the saved result, or the file
            source: viewer.editing ? (viewer.preview.id === (viewer.photo ? viewer.photo.id : -1) ? viewer.preview.url : "")
                                   : (viewer.photo ? (viewer.photo.editedUrl || viewer.photo.fileUrl) : "")
            cache: !viewer.editing
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
        // the zoomed-in region at the original's resolution, laid over the scaled picture
        Image {
            id: regionImage
            readonly property var r: viewer.region
            visible: !viewer.editing && viewer.zoom > 1.05 && viewer.photo && r.id === viewer.photo.id && status === Image.Ready
            x: viewer.paintedX + (r.x || 0) * viewer.paintedW
            y: viewer.paintedY + (r.y || 0) * viewer.paintedH
            width: (r.w || 0) * viewer.paintedW
            height: (r.h || 0) * viewer.paintedH
            source: r.url || ""
            asynchronous: true
            cache: false
            fillMode: Image.Stretch
            smooth: true
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
            onDoubleTapped: (point) => { if (!(overlay.visible && overlay.childAt(point.position.x, point.position.y))) viewer.setZoom(viewer.zoom === 1 ? 2.5 : 1) }
        }
        TapHandler {
            acceptedButtons: Qt.RightButton
            // several TapHandlers all fire on one click: a face under the pointer has its own menu
            onTapped: (point) => {
                if (!viewer.photo) return
                if (overlay.visible && overlay.childAt(point.position.x, point.position.y)) return
                viewer.contextMenu(viewer.photo.id, viewer.photo.path || "", viewer.photo.favorite === true)
            }
        }

        // the crop frame: dimmed outside, draggable corners and body
        Item {
            id: cropFrame
            visible: viewer.editing && viewer.tool === "crop" && image.status === Image.Ready
            x: viewer.paintedX; y: viewer.paintedY
            width: viewer.paintedW; height: viewer.paintedH
            readonly property var c: viewer.edits.crop || [0, 0, 1, 1]
            readonly property real fx: c[0] * width
            readonly property real fy: c[1] * height
            readonly property real fw: c[2] * width
            readonly property real fh: c[3] * height
            function setCrop(x, y, w, h) {
                const minW = 0.05, minH = 0.05
                w = Math.max(minW, Math.min(1, w)); h = Math.max(minH, Math.min(1, h))
                x = Math.max(0, Math.min(1 - w, x)); y = Math.max(0, Math.min(1 - h, y))
                const e = Object.assign({}, viewer.edits)
                e.crop = (x < 0.002 && y < 0.002 && w > 0.998 && h > 0.998) ? null : [x, y, w, h]
                viewer.edits = e   // no preview request: the frame is drawn here
            }
            Rectangle { x: 0; y: 0; width: parent.width; height: cropFrame.fy; color: Qt.rgba(0, 0, 0, 0.55) }
            Rectangle { x: 0; y: cropFrame.fy + cropFrame.fh; width: parent.width; height: parent.height - y; color: Qt.rgba(0, 0, 0, 0.55) }
            Rectangle { x: 0; y: cropFrame.fy; width: cropFrame.fx; height: cropFrame.fh; color: Qt.rgba(0, 0, 0, 0.55) }
            Rectangle { x: cropFrame.fx + cropFrame.fw; y: cropFrame.fy; width: parent.width - x; height: cropFrame.fh; color: Qt.rgba(0, 0, 0, 0.55) }
            Rectangle {
                id: frameRect
                x: cropFrame.fx; y: cropFrame.fy; width: cropFrame.fw; height: cropFrame.fh
                color: "transparent"
                border.color: "white"; border.width: 1.5
                // thirds
                Rectangle { x: parent.width / 3; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, 0.35) }
                Rectangle { x: parent.width * 2 / 3; width: 1; height: parent.height; color: Qt.rgba(1, 1, 1, 0.35) }
                Rectangle { y: parent.height / 3; height: 1; width: parent.width; color: Qt.rgba(1, 1, 1, 0.35) }
                Rectangle { y: parent.height * 2 / 3; height: 1; width: parent.width; color: Qt.rgba(1, 1, 1, 0.35) }
                DragHandler {   // move the frame
                    target: null
                    property var start: null
                    onActiveChanged: start = active ? cropFrame.c.slice() : null
                    onTranslationChanged: if (start) cropFrame.setCrop(start[0] + translation.x / cropFrame.width, start[1] + translation.y / cropFrame.height, start[2], start[3])
                }
            }
            // corner handles
            Repeater {
                model: [ { cx: 0, cy: 0 }, { cx: 1, cy: 0 }, { cx: 0, cy: 1 }, { cx: 1, cy: 1 } ]
                Rectangle {
                    required property var modelData
                    width: 18; height: 18; radius: 3
                    color: "white"
                    border.color: Qt.rgba(0, 0, 0, 0.5)
                    x: cropFrame.fx + modelData.cx * cropFrame.fw - width / 2
                    y: cropFrame.fy + modelData.cy * cropFrame.fh - height / 2
                    DragHandler {
                        target: null
                        property var start: null
                        onActiveChanged: start = active ? cropFrame.c.slice() : null
                        onTranslationChanged: {
                            if (!start) return
                            const dx = translation.x / cropFrame.width, dy = translation.y / cropFrame.height
                            let x = start[0], y = start[1], w = start[2], h = start[3]
                            if (modelData.cx === 0) { x = start[0] + dx; w = start[2] - dx } else w = start[2] + dx
                            if (modelData.cy === 0) { y = start[1] + dy; h = start[3] - dy } else h = start[3] + dy
                            if (viewer.cropAspect > 0) {   // keep the ratio: height follows width
                                const ratioPx = viewer.cropAspect * cropFrame.height / cropFrame.width
                                const nh = w / ratioPx
                                if (modelData.cy === 0) y = y + h - nh
                                h = nh
                            }
                            cropFrame.setCrop(x, y, w, h)
                        }
                    }
                }
            }
        }

        // face circles
        Item {
            id: overlay
            visible: !viewer.editing && image.status === Image.Ready && viewer.zoom === 1 && (stageHover.hovered || namer.opened)
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
                    TapHandler { acceptedButtons: Qt.RightButton; onTapped: viewer.faceMenuFor(fbox.modelData) }
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
        anchors.right: info.visible ? info.left : editPanel.visible ? editPanel.left : parent.right
        anchors.bottom: tagBar.top
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

    // ---- tags: what the classifiers, the calendar, the map and you say about the photo ----
    Rectangle {
        id: tagBar
        anchors.left: parent.left
        anchors.right: info.visible ? info.left : editPanel.visible ? editPanel.left : parent.right
        anchors.bottom: strip.visible ? strip.top : parent.bottom
        height: viewer.photo ? 34 : 0
        color: theme.viewerBg
        readonly property var chips: {
            if (!viewer.photo) return []
            const p = viewer.photo
            const out = []
            if (p.scene) out.push({ group: "scene", text: p.scene, icon: icons.tag })
            if (p.mood) out.push({ group: "mood", text: p.mood, icon: icons.mood })
            if (p.weather) out.push({ group: "weather", text: p.weather, icon: icons.weather })
            if (p.holiday) out.push({ group: "holiday", text: p.holiday, icon: icons.holiday })
            if (p.place) out.push({ group: "place", text: p.place + (p.country ? ", " + p.country : ""), icon: icons.pin, country: p.country || "" })
            for (const k of (p.keywords || [])) out.push({ group: "keyword", text: k, icon: icons.hash })
            return out
        }
        component Chip: Rectangle {
            id: chip
            required property var modelData
            height: 22
            width: chipRow.implicitWidth + 18 + (chip.modelData.group === "keyword" && chipHover.hovered ? 14 : 0)
            radius: 11
            color: chipHover.hovered ? theme.selection : theme.hover
            Behavior on width { NumberAnimation { duration: 80 } }
            Row {
                id: chipRow
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 5
                Image { source: icons.tint(chip.modelData.icon, chip.modelData.group === "keyword" ? theme.accent : theme.muted); sourceSize.width: 12; sourceSize.height: 12; anchors.verticalCenter: parent.verticalCenter }
                Label { text: chip.modelData.text; color: theme.text; font.pixelSize: 12; anchors.verticalCenter: parent.verticalCenter }
            }
            Image {   // × on a keyword: remove it from this photo
                visible: chip.modelData.group === "keyword" && chipHover.hovered
                anchors.right: parent.right
                anchors.rightMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                source: icons.tint(icons.close, theme.text)
                sourceSize.width: 9; sourceSize.height: 9
                TapHandler { onTapped: viewer.removeKeyword(viewer.photo.id, chip.modelData.text) }
            }
            HoverHandler { id: chipHover }
            TapHandler {
                onTapped: {
                    const m = chip.modelData
                    if (m.group === "place") viewer.filterPlace(viewer.photo.place, m.country)
                    else if (m.group === "keyword") viewer.filterKeyword(m.text)
                    else viewer.filterTag(m.group, m.text)
                }
            }
            ToolTip.visible: chipHover.hovered
            ToolTip.delay: 600
            ToolTip.text: chip.modelData.group === "keyword" ? "Your tag — click to see every photo with it, × removes it"
                        : chip.modelData.group === "place" ? "Place — click to see every photo taken there"
                        : chip.modelData.group.charAt(0).toUpperCase() + chip.modelData.group.slice(1) + " — click to see every photo tagged " + chip.modelData.text
        }
        Flickable {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            contentWidth: chipsRow.implicitWidth
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            Row {
                id: chipsRow
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6
                Repeater { model: tagBar.chips; Chip { } }
                // "+ Tag": a word of your own, or several separated by commas
                Rectangle {
                    height: 22
                    width: tagEditor.visible ? 180 : addLabel.implicitWidth + 18
                    radius: 11
                    color: addHover.hovered || tagEditor.visible ? theme.hover : "transparent"
                    border.color: theme.separator
                    border.width: 1
                    Label { id: addLabel; visible: !tagEditor.visible; anchors.centerIn: parent; text: "+ Tag"; color: theme.muted; font.pixelSize: 12 }
                    TextField {
                        id: tagEditor
                        visible: false
                        anchors.fill: parent
                        anchors.leftMargin: 6
                        anchors.rightMargin: 6
                        font.pixelSize: 12
                        color: theme.text
                        placeholderText: "tag, another tag"
                        background: Item { }
                        verticalAlignment: TextInput.AlignVCenter
                        onAccepted: { if (text.trim().length) viewer.addKeywords(viewer.photo.id, text); text = ""; visible = false }
                        onActiveFocusChanged: if (!activeFocus) { visible = false; text = "" }
                        Keys.onEscapePressed: { text = ""; visible = false; viewer.forceActiveFocus() }
                    }
                    HoverHandler { id: addHover }
                    TapHandler { enabled: !tagEditor.visible; onTapped: { tagEditor.visible = true; tagEditor.forceActiveFocus() } }
                }
            }
        }
    }

    // ---- the edit panel (in place of Info while editing) ----------------------------
    EditPanel {
        id: editPanel
        visible: viewer.editing
        theme: viewer.theme
        icons: viewer.icons
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        edits: viewer.edits
        tool: viewer.tool
        onToolChanged: viewer.tool = tool
        presetItems: viewer.photo && viewer.presetPreviews.id === viewer.photo.id ? viewer.presetPreviews.items : []
        busy: viewer.photo ? viewer.presetPreviews.id !== viewer.photo.id : false
        hasSavedEdits: viewer.photo && viewer.photo.edits ? true : false
        onPick: (e) => { viewer.setEdits(Object.assign({}, viewer.emptyEdits, e)) }
        onRotate: (deg) => viewer.rotateBy(deg)
        onFlip: (axis) => viewer.flipBy(axis)
        onAspect: (ratio) => viewer.cropToAspect(ratio)
        onResetCrop: viewer.resetCrop()
        onSave: { viewer.applyEdits(viewer.photo.id, JSON.stringify(viewer.edits)); viewer.endEdit() }
        onSaveCopy: { viewer.saveCopy(viewer.photo.id, JSON.stringify(viewer.edits)); viewer.endEdit() }
        onRevert: { viewer.revertEdits(viewer.photo.id); viewer.endEdit() }
        onCancel: viewer.endEdit()
    }

    // ---- filmstrip ------------------------------------------------------------------
    Rectangle {
        id: strip
        visible: viewer.showStrip && viewer.items.length > 1
        anchors.left: parent.left
        anchors.right: info.visible ? info.left : editPanel.visible ? editPanel.left : parent.right
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
        visible: viewer.infoOpen && !viewer.editing
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
                InfoRow { label: "Place"; value: viewer.photo && viewer.photo.place ? viewer.photo.place + (viewer.photo.country ? ", " + viewer.photo.country : "") : "" }
                InfoRow { label: "Scene"; value: viewer.tagLine("scene") }
                InfoRow { label: "Mood"; value: viewer.tagLine("mood") }
                InfoRow { label: "Weather"; value: viewer.tagLine("weather") }
                InfoRow { label: "Holiday"; value: viewer.tagLine("holiday") }
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
                                TapHandler { acceptedButtons: Qt.RightButton; onTapped: viewer.faceMenuFor(pf.modelData) }
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
