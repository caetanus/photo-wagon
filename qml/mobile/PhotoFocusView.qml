import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtMultimedia

// Full-size viewer over the grid. `photo` is the parsed library.current object
// (a Photo plus prev/next ids) or null.
Rectangle {
    id: viewer
    required property QtObject theme
    property var photo: null
    /// Faces of `photo` (parsed library.faces.faces) and the known people, for naming.
    property var faces: []
    property var people: []
    property bool showFaces: true
    /// Boxes appear only while the pointer is over the photo (desktop); false = always.
    property bool facesOnHover: true
    /// Phone: show "Send to computer" (enabled when a computer is reachable).
    property bool canSend: false
    property bool sendEnabled: false
    /// The photos around this one, for the bottom filmstrip: [{id, thumbUrl}, …]
    /// (the grid's loaded page — no extra backend round-trip).
    property var strip: []
    /// Cast screens the computer can see (it does the casting); for the viewer's cast menu.
    property var castDevices: []

    signal closed()
    signal edit()
    signal send(int id)
    signal addToAlbum(int id)
    signal nameFace(int faceId, int personId, string name)

    color: "#000000"
    focus: visible
    // edge to edge (the window's system bars): the controls stay clear of them
    readonly property real safeTop: SafeArea.margins.top
    readonly property real safeBottom: SafeArea.margins.bottom
    Icons { id: icons }
    component GlassButton: RoundButton {
        required property string icon_
        width: 44; height: 44
        Material.background: Qt.rgba(0, 0, 0, 0.45)
        Material.elevation: 0
        contentItem: Image {
            source: icons.tint(parent.icon_, "#ffffff")
            sourceSize.width: 20; sourceSize.height: 20
            fillMode: Image.Pad
            horizontalAlignment: Image.AlignHCenter
            verticalAlignment: Image.AlignVCenter
        }
    }
    // a plain icon button on the dark top bar
    component TopButton: ToolButton {
        required property string icon_
        implicitWidth: 48; implicitHeight: 48
        contentItem: Image {
            source: icons.tint(parent.icon_, "#ffffff")
            sourceSize.width: 22; sourceSize.height: 22
            fillMode: Image.Pad
            horizontalAlignment: Image.AlignHCenter; verticalAlignment: Image.AlignVCenter
        }
    }
    // one action of the bottom bar: an icon over its name, in reach of the thumb
    component BarAction: ItemDelegate {
        id: ba
        required property string icon_
        property string label: ""
        Layout.fillWidth: true
        implicitHeight: 64
        opacity: enabled ? 1 : 0.4
        background: Rectangle { color: ba.pressed ? Qt.rgba(1, 1, 1, 0.08) : "transparent"; radius: 12 }
        contentItem: ColumnLayout {
            spacing: 4
            Image {
                Layout.alignment: Qt.AlignHCenter
                source: icons.tint(ba.icon_, "#ffffff")
                sourceSize.width: 22; sourceSize.height: 22
            }
            Label {
                Layout.alignment: Qt.AlignHCenter
                text: ba.label
                color: "#e6e8ec"; font.pixelSize: 11
            }
        }
    }
    // one line of the swipe-up detail sheet: a muted label over its value, hidden when empty
    component DetailRow: RowLayout {
        id: drow
        property string icon_: ""
        property string label: ""
        property string value: ""
        visible: value.length > 0
        Layout.fillWidth: true
        spacing: 12
        Image {
            source: icons.tint(drow.icon_, viewer.theme.muted)
            sourceSize.width: 17; sourceSize.height: 17
            Layout.alignment: Qt.AlignTop; Layout.topMargin: 3
        }
        ColumnLayout {
            spacing: 1; Layout.fillWidth: true
            Label { text: drow.label; color: viewer.theme.muted; font.pixelSize: 11; font.letterSpacing: 0.4 }
            Label { text: drow.value; color: viewer.theme.text; font.pixelSize: 15; wrapMode: Text.WordWrap; Layout.fillWidth: true }
        }
    }
    component DetailChip: Rectangle {
        property string text_: ""
        implicitWidth: chl.implicitWidth + 22; implicitHeight: 28; radius: 14
        color: Qt.rgba(viewer.theme.accent.r, viewer.theme.accent.g, viewer.theme.accent.b, 0.16)
        Label { id: chl; anchors.centerIn: parent; text: parent.text_; color: viewer.theme.accent; font.pixelSize: 12; font.weight: Font.Medium }
    }
    onVisibleChanged: if (visible) forceActiveFocus()
    onPhotoChanged: {
        resetZoom(); chrome = true; Qt.callLater(centerStrip)
        // video → video: a fresh player (its first-frame priming and speed start over)
        if (isVideo) { videoLoader.active = false; videoLoader.active = Qt.binding(() => viewer.isVideo) }
    }   // a new photo always opens un-zoomed, controls shown

    // A single tap on the photo hides / shows every control (the photo alone, like a gallery);
    // a double tap still zooms.
    property bool chrome: true

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) { viewer.closed(); event.accepted = true }
        else if (event.key === Qt.Key_Left) { library.prev(); event.accepted = true }
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Space) { library.next(); event.accepted = true }
    }

    // Block the grid underneath from getting taps, but do NOT close on tap: a tap-to-close
    // here ate the first tap of a double-tap (so zoom never fired) and grabbed the swipe. A
    // DragHandler can still steal from this for the swipe; close is the ✕ button.
    MouseArea { anchors.fill: parent; onClicked: {} }

    // A soft scrim under the top controls, so the close / nav buttons stay legible
    // over a bright photo without a hard black bar.
    Rectangle {
        visible: viewer.chrome
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        height: 96
        gradient: Gradient {
            GradientStop { position: 0; color: Qt.rgba(0, 0, 0, 0.5) }
            GradientStop { position: 1; color: "transparent" }
        }
    }

    // Pinch / double-tap to zoom, drag to pan when zoomed. `zoomed` gates the swipe
    // navigation (a one-finger drag pans instead of changing photo) and hides the face
    // overlay (its boxes are computed for the un-transformed image).
    readonly property bool zoomed: image.scale > 1.01
    function resetZoom() {
        image.scale = 1
        // bindings again, not values: the frame follows the controls once un-zoomed
        image.x = Qt.binding(() => image.baseX)
        image.y = Qt.binding(() => image.baseY)
    }

    readonly property bool isVideo: photo && photo.video === true

    // With the controls shown the photo fits BETWEEN the bars (nothing of it — a face to
    // name, say — lies under a button); alone, it takes the whole screen. The frame only
    // follows the controls while not zoomed, so a tap on a zoomed photo never moves it.
    property bool framed: true
    onChromeChanged: if (!zoomed) framed = chrome
    onZoomedChanged: if (!zoomed) framed = chrome
    readonly property real topReserve: framed ? 64 + safeTop : 0
    readonly property real bottomReserve: framed ? 72 + safeBottom + (strip && strip.length > 1 ? 60 : 0) : 0

    Image {
        id: image
        visible: !viewer.isVideo
        readonly property real baseX: (viewer.width - width) / 2
        readonly property real baseY: viewer.topReserve
        width: viewer.width
        height: Math.max(1, viewer.height - viewer.topReserve - viewer.bottomReserve)
        x: baseX
        y: baseY
        transformOrigin: Item.Center
        source: viewer.isVideo ? "" : (viewer.photo ? viewer.photo.fileUrl : "")
        // decode scaled: a 108 MP photo (434 MB decoded) is over Qt's 256 MB image limit
        sourceSize.width: 2560
        sourceSize.height: 2560
        asynchronous: true
        fillMode: Image.PreserveAspectFit
        autoTransform: true
        smooth: true
        mipmap: true
        HoverHandler { id: imageHover }

        PinchHandler {
            target: image
            minimumScale: 1
            maximumScale: 6
            // pinch is zoom only — a photo viewer does not free-rotate the picture. Left on,
            // PinchHandler twists `image` a little on every pinch and never puts it back.
            rotationAxis.enabled: false
            onActiveChanged: if (!active) {
                image.rotation = 0            // undo any stray rotation from a two-finger twist
                if (image.scale < 1.05) viewer.resetZoom()
            }
        }
        WheelHandler {
            target: image
            property: "scale"
            // desktop / trackpad zoom
            onWheel: (e) => { if (image.scale < 1.02) viewer.resetZoom() }
        }
        DragHandler {
            // pan only while zoomed; when not zoomed the outer swipe navigates
            enabled: viewer.zoomed
            target: image
        }
        TapHandler {
            // exclusive: singleTapped waits out the double-tap interval, so a double tap is
            // never also a chrome toggle
            exclusiveSignals: TapHandler.SingleTap | TapHandler.DoubleTap
            onSingleTapped: viewer.chrome = !viewer.chrome
            onDoubleTapped: (pt) => {
                if (viewer.zoomed) { viewer.resetZoom(); return }
                // zoom INTO the tapped point: keep it under the finger (scale is about the centre)
                const s = 2.5
                const p = pt.position
                image.scale = s
                image.x -= (s - 1) * (p.x - image.width / 2)
                image.y -= (s - 1) * (p.y - image.height / 2)
            }
        }
    }

    // Video: plays in place of the still with play/pause, a scrub bar and 0.5×/1×/2×/3× speed.
    // Loaded only for a video and torn down (which stops it) when you move to a still. The
    // frame thumbnail arrives in the grid once the computer has the video and made one.
    Loader {
        id: videoLoader
        anchors.fill: parent
        active: viewer.isVideo
        sourceComponent: Component {
            Rectangle {
                color: "#000000"
                function fmt(ms) {
                    if (!ms || ms < 0) ms = 0
                    const s = Math.floor(ms / 1000)
                    return Math.floor(s / 60) + ":" + ("0" + (s % 60)).slice(-2)
                }
                // A crisp filled play triangle (the "▶" glyph rendered thin and off-centre).
                readonly property string playGlyph: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#ffffff"><path d="M8 5v14l11-7z"/></svg>')
                MediaPlayer {
                    id: mp
                    source: viewer.photo ? (viewer.photo.fileUrl || "") : ""
                    videoOutput: vout
                    audioOutput: AudioOutput { id: aout; muted: mp.priming }
                    // Phone videos carry no thumbnail (the computer makes one on sync), so on open
                    // the frame was just black. Prime the first frame — play muted until the first
                    // frame renders, then pause back to 0 — so a paused poster shows, like a gallery.
                    property bool priming: true
                    onMediaStatusChanged: if (mediaStatus === MediaPlayer.LoadedMedia && priming && position === 0) play()
                    onPositionChanged: if (priming && position > 0) { pause(); position = 0; priming = false }
                }
                VideoOutput { id: vout; anchors.fill: parent; fillMode: VideoOutput.PreserveAspectFit }
                Image {   // a stored thumbnail, if the computer already made one, over the first frame
                    anchors.fill: parent
                    fillMode: Image.PreserveAspectFit
                    source: viewer.photo ? (viewer.photo.thumbUrl || "") : ""
                    visible: source != "" && mp.playbackState !== MediaPlayer.PlayingState && mp.position === 0
                }
                MouseArea {
                    anchors.fill: parent
                    onClicked: { mp.priming = false; mp.playbackState === MediaPlayer.PlayingState ? mp.pause() : mp.play() }
                }
                Rectangle {   // big play/pause
                    anchors.centerIn: parent
                    width: 88; height: 88; radius: 44
                    color: Qt.rgba(0, 0, 0, 0.5)
                    visible: mp.playbackState !== MediaPlayer.PlayingState
                    Image {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: 3   // optical centre of a triangle
                        source: playGlyph
                        sourceSize.width: 38; sourceSize.height: 38
                    }
                    TapHandler { onTapped: { mp.priming = false; mp.play() } }
                }
                Row {   // speed
                    anchors.top: parent.top; anchors.right: parent.right; anchors.topMargin: 70; anchors.rightMargin: 14
                    spacing: 6
                    visible: mp.duration > 0
                    Repeater {
                        model: [0.5, 1, 2, 3]
                        Rectangle {
                            required property var modelData
                            width: 46; height: 32; radius: 16
                            color: Math.abs(mp.playbackRate - modelData) < 0.01 ? viewer.theme.accent : Qt.rgba(0, 0, 0, 0.5)
                            Text { anchors.centerIn: parent; text: modelData + "×"; color: "white"; font.pixelSize: 13 }
                            TapHandler { onTapped: mp.playbackRate = modelData }
                        }
                    }
                }
                Rectangle {   // scrub bar
                    anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
                    anchors.margins: 16
                    // above the action bar and the filmstrip while they show
                    anchors.bottomMargin: viewer.chrome ? actionBar.height + (filmstripBar.visible ? filmstripBar.height : 0) + 12 : 40
                    height: 40; radius: 10
                    color: Qt.rgba(0, 0, 0, 0.5)
                    visible: mp.duration > 0
                    RowLayout {
                        anchors.fill: parent; anchors.leftMargin: 14; anchors.rightMargin: 14; spacing: 10
                        Label { text: fmt(mp.position); color: "white"; font.pixelSize: 12 }
                        Slider {
                            Layout.fillWidth: true
                            from: 0; to: Math.max(1, mp.duration)
                            value: mp.position
                            onMoved: mp.position = value
                            Material.accent: viewer.theme.accent
                        }
                        Label { text: fmt(mp.duration); color: "white"; font.pixelSize: 12 }
                    }
                }
            }
        }
    }

    // Face boxes over the painted image area.
    Item {
        id: overlay
        visible: viewer.chrome && viewer.showFaces && !viewer.zoomed && image.status === Image.Ready && (!viewer.facesOnHover || imageHover.hovered || namer.opened)
        readonly property real px: image.x + (image.width - image.paintedWidth) / 2
        readonly property real py: image.y + (image.height - image.paintedHeight) / 2
        Repeater {
            model: viewer.faces
            delegate: Item {
                required property var modelData
                x: overlay.px + modelData.x * image.paintedWidth
                y: overlay.py + modelData.y * image.paintedHeight
                width: modelData.w * image.paintedWidth
                height: modelData.h * image.paintedHeight
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.color: modelData.name ? theme.accent : "#22d3ee"
                    border.width: 2
                    radius: 3
                }
                Rectangle {
                    anchors.top: parent.bottom
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.topMargin: 2
                    width: tag.implicitWidth + 12
                    height: tag.implicitHeight + 6
                    radius: 3
                    color: modelData.name ? theme.accent : "#22d3ee"
                    Label {
                        id: tag
                        anchors.centerIn: parent
                        text: modelData.name || "Who is this?"
                        color: modelData.name ? "#ffffff" : "#222222"
                        font.pixelSize: 12
                    }
                }
                TapHandler {
                    onTapped: {
                        namer.faceId = modelData.id
                        namer.currentName = modelData.name || ""
                        namer.open()
                    }
                }
            }
        }
    }

    // "Who is this?": type a name or pick a known person.
    Popup {
        id: namer
        property int faceId: 0
        property string currentName: ""
        modal: true
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.55) }
        anchors.centerIn: parent
        width: 320
        padding: 16
        background: Rectangle { color: theme.panel; border.color: theme.border; radius: 8 }
        onOpened: { nameField.text = currentName; nameField.forceActiveFocus(); nameField.selectAll() }
        ColumnLayout {
            anchors.fill: parent
            spacing: 10
            Label { text: "Who is this?"; font.bold: true; color: theme.text }
            TextField {
                id: nameField
                placeholderText: "Name"
                Layout.fillWidth: true
                onAccepted: { viewer.nameFace(namer.faceId, 0, text); namer.close() }
            }
            Label { visible: viewer.people.length > 0; text: "or someone already known:"; color: theme.muted; font.pixelSize: 12 }
            ListView {
                visible: viewer.people.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(200, viewer.people.length * 32)
                clip: true
                model: viewer.people
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
                Item { Layout.fillWidth: true }
                Button { text: "Cancel"; onClicked: namer.close() }
                Button { text: "Save"; enabled: nameField.text.trim().length > 0; onClicked: { viewer.nameFace(namer.faceId, 0, nameField.text); namer.close() } }
            }
        }
    }

    BusyIndicator {
        anchors.centerIn: image
        running: image.status === Image.Loading
        visible: running
    }

    GlassButton {
        icon_: icons.chevronLeft
        anchors.left: parent.left
        anchors.verticalCenter: image.verticalCenter
        anchors.leftMargin: 8
        visible: viewer.chrome
        enabled: viewer.photo && viewer.photo.prev !== null
        opacity: enabled ? 0.9 : 0.25
        onClicked: library.prev()
    }
    GlassButton {
        icon_: icons.chevronRight
        anchors.right: parent.right
        anchors.verticalCenter: image.verticalCenter
        anchors.rightMargin: 8
        visible: viewer.chrome
        enabled: viewer.photo && viewer.photo.next !== null
        opacity: enabled ? 0.9 : 0.25
        onClicked: library.next()
    }
    // ---- top: back, when and where, details and cast ---------------------------------
    RowLayout {
        id: topBar
        visible: viewer.chrome
        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
        anchors.leftMargin: 4; anchors.rightMargin: 4; anchors.topMargin: 6 + viewer.safeTop
        height: 52
        spacing: 2
        TopButton { icon_: icons.chevronLeft; onClicked: viewer.closed() }
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 0
            Label {
                text: viewer.photo ? viewer.formatDate(viewer.photo.takenAt) : ""
                color: "#ffffff"; font.pixelSize: 15; font.weight: Font.DemiBold
                elide: Text.ElideRight; Layout.fillWidth: true
            }
            Label {
                // where, else what it is (camera · size)
                text: viewer.photo ? (viewer.placeText() || [viewer.photo.camera, viewer.formatSize(viewer.photo.size)].filter(x => x).join("  ·  ")) : ""
                visible: text.length > 0
                color: "#c4c8d0"; font.pixelSize: 12
                elide: Text.ElideRight; Layout.fillWidth: true
            }
        }
        // Cast to a TV — the phone drives the computer's CastService (it is on the TV's LAN).
        TopButton {
            icon_: icons.cast
            visible: viewer.photo && !viewer.zoomed
            onClicked: { library.loadCastDevices(); castMenu.open() }
        }
        // Details: swipe up on the photo, or tap ⓘ.
        TopButton {
            icon_: icons.info
            visible: viewer.photo && !viewer.zoomed
            onClicked: detailSheet.open()
        }
    }
    Menu {
        id: castMenu
        Material.background: viewer.theme.panel
        MenuItem { enabled: false; text: viewer.castDevices.length ? "Cast this photo to:" : "Looking for TVs…" }
        Repeater {
            model: viewer.castDevices
            MenuItem {
                required property var modelData
                text: modelData.name
                onTriggered: library.castTo(modelData.host, modelData.port, modelData.kind || "chromecast", modelData.control || "", viewer.photo.id)
            }
        }
        MenuSeparator { visible: viewer.castDevices.length > 0 }
        MenuItem { text: "Stop casting"; onTriggered: library.castStop() }
    }
    // swipe left / right for the neighbours — off while zoomed, where a drag pans instead
    DragHandler {
        target: null
        enabled: !viewer.zoomed
        xAxis.enabled: true
        yAxis.enabled: false
        onActiveChanged: if (!active) {
            if (translation.x < -60 && viewer.photo && viewer.photo.next !== null) library.next()
            else if (translation.x > 60 && viewer.photo && viewer.photo.prev !== null) library.prev()
        }
    }

    // Bottom filmstrip: scrub the surrounding photos, the current one ringed; tap to jump.
    // Uses the grid's already-loaded page, so it costs no extra backend round-trip.
    Rectangle {
        id: filmstripBar
        visible: viewer.chrome && viewer.strip && viewer.strip.length > 1 && !viewer.zoomed
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: actionBar.top
        height: 60
        color: Qt.rgba(0, 0, 0, 0.62)
        ListView {
            id: filmstrip
            anchors.fill: parent
            orientation: ListView.Horizontal
            model: viewer.strip
            spacing: 3
            clip: true
            boundsBehavior: Flickable.StopAtBounds
            leftMargin: viewer.width / 2 - 22
            rightMargin: viewer.width / 2 - 22
            delegate: Item {
                id: fsCell
                required property var modelData
                readonly property bool isCurrent: viewer.photo && modelData.id === viewer.photo.id
                width: fsCell.isCurrent ? 50 : 42
                height: filmstrip.height
                Rectangle {
                    anchors.centerIn: parent
                    width: fsCell.isCurrent ? 48 : 38
                    height: width
                    radius: 5
                    color: viewer.theme.panelAlt
                    border.color: fsCell.isCurrent ? viewer.theme.accent : "transparent"
                    border.width: 2
                    clip: true
                    Image {
                        anchors.fill: parent
                        source: fsCell.modelData.thumbUrl || ""
                        visible: status === Image.Ready
                        fillMode: Image.PreserveAspectCrop
                        sourceSize.width: 108; sourceSize.height: 108
                    }
                }
                TapHandler { onTapped: library.openPhoto(fsCell.modelData.id) }
            }
        }
    }
    function centerStrip() {
        if (!photo || !strip || !strip.length) return
        for (let i = 0; i < strip.length; i++)
            if (strip[i].id === photo.id) { filmstrip.positionViewAtIndex(i, ListView.Center); return }
    }

    // ---- bottom: what can be done with this photo ---------------------------------------
    Rectangle {
        id: actionBar
        visible: viewer.chrome
        anchors.left: parent.left; anchors.right: parent.right; anchors.bottom: parent.bottom
        height: visible ? 72 + viewer.safeBottom : 0
        color: Qt.rgba(0, 0, 0, 0.62)
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 8; anchors.rightMargin: 8; anchors.bottomMargin: 4 + viewer.safeBottom
            spacing: 4
            // to WhatsApp / e-mail / … through the Android share sheet
            BarAction {
                icon_: icons.share; label: "Share"
                enabled: !!viewer.photo
                onClicked: library.sharePhoto(viewer.photo.id)
            }
            // the mini editor: the phone's own stills (the editor paints a picture; a video has none)
            BarAction {
                icon_: icons.edit; label: "Edit"
                enabled: !!viewer.photo && viewer.photo.remote !== true && !viewer.isVideo
                onClicked: viewer.edit()
            }
            // albums live on the computer; a phone photo is sent there first
            BarAction {
                icon_: icons.album; label: "Add to album"
                enabled: !!viewer.photo
                onClicked: viewer.addToAlbum(viewer.photo.id)
            }
            BarAction {
                visible: viewer.canSend
                icon_: viewer.photo && viewer.photo.sent ? icons.check : icons.upload
                label: viewer.photo && viewer.photo.sent ? "On computer" : "Send"
                enabled: viewer.sendEnabled && !!viewer.photo && !viewer.photo.sent
                onClicked: viewer.send(viewer.photo.id)
            }
        }
    }

    // Swipe up from the bottom (or the ⓘ button) for the full Apple-style detail sheet.
    Drawer {
        id: detailSheet
        edge: Qt.BottomEdge
        width: viewer.width
        height: Math.min(viewer.height * 0.66, sheetCol.implicitHeight + 34)
        dragMargin: viewer.zoomed ? 0 : 24
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.55) }   // dim the photo, don't wash it pale
        Material.background: viewer.theme.panel
        background: Rectangle { color: viewer.theme.panel; topLeftRadius: 20; topRightRadius: 20 }

        Flickable {
            anchors.fill: parent
            contentHeight: sheetCol.implicitHeight + 20
            clip: true
            ColumnLayout {
                id: sheetCol
                x: 20; width: parent.width - 40
                spacing: 15
                Rectangle {
                    Layout.alignment: Qt.AlignHCenter; Layout.topMargin: 9
                    width: 36; height: 4; radius: 2; color: viewer.theme.border
                }
                Label {
                    text: viewer.photo ? viewer.formatDate(viewer.photo.takenAt) : ""
                    color: viewer.theme.text; font.pixelSize: 19; font.weight: Font.DemiBold
                    Layout.fillWidth: true; wrapMode: Text.WordWrap
                }
                DetailRow { icon_: icons.pin;        label: "PLACE";      value: viewer.placeText() }
                DetailRow { icon_: icons.people;     label: "PEOPLE";     value: viewer.peopleNames() }
                DetailRow { icon_: icons.info;       label: "CAMERA";     value: viewer.photo ? (viewer.photo.camera || "") : "" }
                DetailRow { icon_: icons.photos;     label: "DIMENSIONS"; value: viewer.dimsText() }
                DetailRow { icon_: icons.info;       label: "FILE SIZE";  value: viewer.photo ? viewer.formatSize(viewer.photo.size) : "" }
                Flow {
                    Layout.fillWidth: true; spacing: 8
                    visible: chipRep.count > 0
                    Repeater { id: chipRep; model: viewer.photo ? viewer.tagChips() : []; DetailChip { text_: modelData } }
                }
                DetailRow { icon_: icons.screenshot; label: "TEXT";       value: viewer.photo ? (viewer.photo.ocrText || "") : "" }
                DetailRow { icon_: icons.folderPlus; label: "PATH";       value: viewer.photo ? (viewer.photo.path || "") : "" }
                Item { Layout.preferredHeight: 6 }
            }
        }
    }

    function peopleNames() {
        if (!faces || !faces.length) return ""
        const seen = ({}), out = []
        for (const f of faces) if (f.name && !seen[f.name]) { seen[f.name] = 1; out.push(f.name) }
        return out.join(", ")
    }
    function placeText() {
        if (!photo) return ""
        if (photo.place) return photo.country ? photo.place + ", " + photo.country : photo.place
        if (photo.lat !== null && photo.lat !== undefined) return photo.lat.toFixed(4) + ", " + photo.lon.toFixed(4)
        return ""
    }
    function dimsText() {
        if (!photo || !photo.width) return ""
        const mp = photo.width * photo.height / 1e6
        return photo.width + " × " + photo.height + (mp >= 0.1 ? "  ·  " + mp.toFixed(1) + " MP" : "")
    }
    function tagChips() {
        if (!photo) return []
        const out = []
        for (const k of ["scene", "mood", "weather", "holiday"]) if (photo[k]) out.push(photo[k])
        if (photo.keywords && photo.keywords.length) for (const kw of photo.keywords) out.push(kw)
        return out
    }

    function formatDate(iso) {
        if (!iso) return "unknown date"
        const d = new Date(iso)
        return isNaN(d.getTime()) ? iso : d.toLocaleString(Qt.locale(), "yyyy-MM-dd  HH:mm")
    }

    function formatSize(bytes) {
        if (!bytes) return ""
        if (bytes > 1048576) return (bytes / 1048576).toFixed(1) + " MB"
        if (bytes > 1024) return Math.round(bytes / 1024) + " KB"
        return bytes + " B"
    }
}
