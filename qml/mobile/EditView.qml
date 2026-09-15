import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts
import QtQuick.Effects

// A small Telegram-style editor on the phone: live filters and adjustments over the
// photo (GPU, via MultiEffect — the phone has no libvips), rotate and flip, a freehand
// pen, an undo stack, and Save, which grabs the edited frame to a JPEG the library picks
// up. Same Edits vocabulary as the desktop (brightness/contrast/saturation/warmth/fade/
// vignette/sepia + rotate/flip) plus the pen, which is phone-only.
Rectangle {
    id: editor
    required property QtObject theme
    required property QtObject icons
    property var photo: null          // library.current
    property string tool: "filters"

    signal cancelled()
    signal saved(string path)         // a JPEG was written here; the library should pick it up

    color: "#000000"
    visible: photo !== null

    // ---- the edit state (mirrors core/edit/edits.d) --------------------------------------
    property real brightness: 0     // -1..1
    property real contrast: 0       // -1..1
    property real saturation: 0     // -1..1
    property real warmth: 0         // -1..1
    property real fade: 0           // 0..1
    property real vignette: 0       // 0..1
    property real sepia: 0          // 0..1
    property int photoRot: 0        // 0/90/180/270
    property real straighten: 0     // fine level, degrees (−15..15)
    property bool flipH: false
    property bool flipV: false
    property string preset: "Original"
    // pen: committed strokes, each {color, width (fraction of frame width), points:[{x,y} 0..1]}
    property var strokes: []
    property color penColor: "#ff3b30"
    property real penWidth: 0.012

    // ---- undo -----------------------------------------------------------------------------
    // A snapshot of every editable value. Before each discrete change (a slider drag, a
    // preset, a rotate/flip, a pen stroke) we push one; Undo pops and restores it.
    property var undoStack: []
    property int undoCount: 0
    readonly property bool canUndo: undoCount > 0

    function snapshot() {
        return { b: brightness, c: contrast, s: saturation, w: warmth, f: fade,
                 vig: vignette, se: sepia, rot: photoRot, stt: straighten, fH: flipH, fV: flipV,
                 preset: preset, strokes: JSON.parse(JSON.stringify(strokes)) }
    }
    function pushHistory() { undoStack.push(snapshot()); undoCount = undoStack.length }
    function applySnap(s) {
        brightness = s.b; contrast = s.c; saturation = s.s; warmth = s.w; fade = s.f
        vignette = s.vig; sepia = s.se; photoRot = s.rot; straighten = s.stt; flipH = s.fH; flipV = s.fV
        preset = s.preset; strokes = s.strokes; strokesChanged(); canvas.requestPaint()
    }
    function undo() {
        if (!undoStack.length) return
        applySnap(undoStack.pop()); undoCount = undoStack.length
    }

    function reset() {
        brightness = contrast = saturation = warmth = fade = vignette = sepia = 0
        photoRot = 0; straighten = 0; flipH = false; flipV = false; preset = "Original"
        strokes = []; strokesChanged()
        undoStack = []; undoCount = 0
        drawing = false; curPts = []
        if (canvas.available) canvas.requestPaint()
    }
    onPhotoChanged: reset()

    // A preset is just a bundle of the adjustments above (b/c/s brightness·contrast·saturation,
    // w warmth −cool..+warm, f fade, se sepia tint). MultiEffect renders them on the GPU.
    readonly property var presets: [
        { name: "Original", b: 0,     c: 0,    s: 0,    w: 0,    f: 0,   se: 0 },
        { name: "Vivid",    b: 0.03,  c: 0.12, s: 0.35, w: 0.05, f: 0,   se: 0 },
        { name: "Pop",      b: 0.08,  c: 0.15, s: 0.45, w: 0,    f: 0,   se: 0 },
        { name: "Punch",    b: 0,     c: 0.22, s: 0.5,  w: 0,    f: 0,   se: 0 },
        { name: "Crisp",    b: 0.03,  c: 0.15, s: 0.1,  w: 0,    f: 0,   se: 0 },
        { name: "Clear",    b: 0.06,  c: 0.08, s: 0.12, w: -0.1, f: 0,   se: 0 },
        { name: "Warm",     b: 0.04,  c: 0.05, s: 0.12, w: 0.45, f: 0,   se: 0 },
        { name: "Sunny",    b: 0.1,   c: 0.05, s: 0.2,  w: 0.25, f: 0,   se: 0 },
        { name: "Golden",   b: 0.04,  c: 0.04, s: 0.15, w: 0.6,  f: 0.05,se: 0 },
        { name: "Sunset",   b: 0,     c: 0.1,  s: 0.25, w: 0.5,  f: 0.05,se: 0 },
        { name: "Rose",     b: 0.05,  c: 0.03, s: 0.1,  w: 0.35, f: 0.1, se: 0 },
        { name: "Coffee",   b: 0.02,  c: 0.06, s: -0.4, w: 0.25, f: 0,   se: 0.5 },
        { name: "Cool",     b: 0.02,  c: 0.06, s: 0.1,  w: -0.4, f: 0,   se: 0 },
        { name: "Aqua",     b: 0,     c: 0.06, s: 0.2,  w: -0.35,f: 0,   se: 0 },
        { name: "Mint",     b: 0,     c: 0.05, s: 0.15, w: -0.4, f: 0,   se: 0 },
        { name: "Arctic",   b: 0.05,  c: 0.05, s: -0.1, w: -0.7, f: 0,   se: 0 },
        { name: "Twilight", b: -0.03, c: 0.08, s: 0.05, w: -0.55,f: 0.05,se: 0 },
        { name: "Dramatic", b: -0.08, c: 0.3,  s: 0.1,  w: 0,    f: 0,   se: 0 },
        { name: "Moody",    b: -0.06, c: 0.15, s: -0.1, w: -0.15,f: 0.1, se: 0 },
        { name: "Fade",     b: 0.06,  c: -0.12,s: -0.1, w: 0.05, f: 0.5, se: 0 },
        { name: "Matte",    b: 0.04,  c: -0.08,s: -0.05,w: 0,    f: 0.35,se: 0 },
        { name: "Retro",    b: 0.06,  c: -0.1, s: -0.15,w: 0.3,  f: 0.45,se: 0 },
        { name: "Vintage",  b: 0.02,  c: 0.05, s: -0.3, w: 0.2,  f: 0.35,se: 0.3 },
        { name: "Noir",     b: -0.02, c: 0.35, s: -1,   w: 0,    f: 0,   se: 0 },
        { name: "Silver",   b: 0.05,  c: -0.05,s: -1,   w: 0,    f: 0.2, se: 0 },
        { name: "Mono",     b: 0,     c: 0.08, s: -1,   w: 0,    f: 0,   se: 0 },
        { name: "Sepia",    b: 0.02,  c: 0.05, s: -1,   w: 0,    f: 0.1, se: 0.8 }
    ]
    function applyPreset(p) {
        pushHistory()
        brightness = p.b; contrast = p.c; saturation = p.s; warmth = p.w; fade = p.f; sepia = p.se
        preset = p.name
    }

    // ---- freehand pen state ---------------------------------------------------------------
    property bool drawing: false
    property var curPts: []
    function beginStroke() { drawing = true; curPts = [] }
    function addPoint(nx, ny) { curPts.push({ x: nx, y: ny }); canvas.requestPaint() }
    function endStroke() {
        if (drawing && curPts.length) {
            strokes.push({ color: String(penColor), width: penWidth, points: curPts.slice() })
            strokesChanged()
        }
        drawing = false; curPts = []
        canvas.requestPaint()
    }

    // ---- the photo with its live effects -------------------------------------------------
    Item {
        id: stage
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.bottom: toolbar.top
        anchors.margins: 8

        // OUTPUT container — what grabToImage captures. Its size is the final image's aspect
        // (width and height swap at a 90°/270° turn). It has no transform of its own, so every
        // transform on `content` below is a child transform and IS captured by the grab. It
        // clips, so a straighten tilt that oversizes the content shows no empty corners.
        Item {
            id: frame
            anchors.centerIn: parent
            clip: true
            readonly property real srcAr: image.implicitHeight > 0 ? image.implicitWidth / image.implicitHeight : 1
            readonly property bool swap: editor.photoRot % 180 !== 0
            readonly property real outAr: swap ? 1 / srcAr : srcAr
            width: Math.min(stage.width, stage.height * outAr)
            height: width / outAr

            // The photo and its effects, sized in the photo's own orientation, then rotated,
            // straightened, flipped and scaled to cover the frame. The Image is invisible; the
            // MultiEffect over it is what shows.
            Item {
                id: content
                anchors.centerIn: parent
                width: frame.swap ? frame.height : frame.width
                height: frame.swap ? frame.width : frame.height
                // 90° turns animate; a straighten drag stays live (it is its own transform below)
                rotation: editor.photoRot
                Behavior on rotation { NumberAnimation { duration: 280; easing.type: Easing.OutCubic } }
                // scale up just enough that a straighten tilt leaves no empty corner in the frame
                readonly property real cover: {
                    var a = editor.straighten * Math.PI / 180
                    var s = Math.abs(Math.sin(a)), c = Math.abs(Math.cos(a))
                    return Math.max((width * c + height * s) / width, (height * c + width * s) / height)
                }
                transform: [
                    // live fine level from the straighten slider
                    Rotation { origin.x: content.width / 2; origin.y: content.height / 2; angle: editor.straighten },
                    // live cover scale so the tilt shows no empty corners
                    Scale { origin.x: content.width / 2; origin.y: content.height / 2
                            xScale: content.cover; yScale: content.cover },
                    // flip: the sign swings through 0, which reads as an animated flip
                    Scale {
                        origin.x: content.width / 2; origin.y: content.height / 2
                        xScale: editor.flipH ? -1 : 1
                        yScale: editor.flipV ? -1 : 1
                        Behavior on xScale { NumberAnimation { duration: 320; easing.type: Easing.InOutCubic } }
                        Behavior on yScale { NumberAnimation { duration: 320; easing.type: Easing.InOutCubic } }
                    }
                ]

                Image {
                    id: image
                    anchors.fill: parent
                    source: editor.photo ? editor.photo.fileUrl : ""
                    sourceSize.width: 2048
                    fillMode: Image.Stretch     // the content box already matches the photo's aspect
                    autoTransform: true
                    smooth: true
                    visible: false     // MultiEffect draws it
                }
                MultiEffect {
                    anchors.fill: parent
                    source: image
                    brightness: editor.brightness + editor.fade * 0.12
                    contrast: editor.contrast - editor.fade * 0.15
                    saturation: editor.saturation
                    // warmth: tint toward orange (warm) or blue (cool); sepia tints brown
                    colorization: editor.sepia > 0 ? editor.sepia * 0.7 : Math.abs(editor.warmth) * 0.5
                    colorizationColor: editor.sepia > 0 ? Qt.rgba(0.44, 0.26, 0.08, 1)
                                     : editor.warmth >= 0 ? Qt.rgba(1.0, 0.55, 0.1, 1)
                                     : Qt.rgba(0.1, 0.4, 1.0, 1)
                }
                // vignette: a radial darkening at the edges
                Rectangle {
                    anchors.fill: parent
                    visible: editor.vignette > 0.001
                    gradient: Gradient {
                        orientation: Gradient.Vertical
                        GradientStop { position: 0.0; color: Qt.rgba(0, 0, 0, editor.vignette * 0.55) }
                        GradientStop { position: 0.25; color: "transparent" }
                        GradientStop { position: 0.75; color: "transparent" }
                        GradientStop { position: 1.0; color: Qt.rgba(0, 0, 0, editor.vignette * 0.55) }
                    }
                }
                // pen strokes, on top of everything (and captured by grabToImage)
                Canvas {
                    id: canvas
                    anchors.fill: parent
                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)
                        ctx.lineJoin = "round"; ctx.lineCap = "round"
                        function drawStroke(color, w, pts) {
                            if (!pts || !pts.length) return
                            ctx.strokeStyle = color
                            ctx.lineWidth = Math.max(1, w * width)
                            ctx.beginPath()
                            ctx.moveTo(pts[0].x * width, pts[0].y * height)
                            if (pts.length === 1)
                                ctx.lineTo(pts[0].x * width + 0.1, pts[0].y * height + 0.1)
                            else
                                for (var j = 1; j < pts.length; j++)
                                    ctx.lineTo(pts[j].x * width, pts[j].y * height)
                            ctx.stroke()
                        }
                        for (var i = 0; i < editor.strokes.length; i++)
                            drawStroke(editor.strokes[i].color, editor.strokes[i].width, editor.strokes[i].points)
                        if (editor.drawing)
                            drawStroke(String(editor.penColor), editor.penWidth, editor.curPts)
                    }
                }
                // pen input — only while the Draw tool is active, so it never blocks the rest
                MouseArea {
                    anchors.fill: parent
                    enabled: editor.tool === "draw"
                    visible: enabled
                    preventStealing: true
                    onPressed: (m) => { editor.pushHistory(); editor.beginStroke(); editor.addPoint(m.x / width, m.y / height) }
                    onPositionChanged: (m) => { if (editor.drawing) editor.addPoint(m.x / width, m.y / height) }
                    onReleased: editor.endStroke()
                    onCanceled: editor.endStroke()
                }
            }
        }
    }

    // ---- controls ------------------------------------------------------------------------
    component Slider0: RowLayout {
        property string label
        property alias value: sl.value
        Layout.fillWidth: true
        spacing: 10
        Label { text: label; color: theme.text; font.pixelSize: 13; Layout.preferredWidth: 92 }
        Slider {
            id: sl; from: -1; to: 1; value: 0; Layout.fillWidth: true; Material.accent: theme.accent
            onPressedChanged: if (pressed) editor.pushHistory()   // one undo step per drag
        }
        Label { text: Math.round(sl.value * 100); color: theme.muted; font.pixelSize: 12; Layout.preferredWidth: 34; horizontalAlignment: Text.AlignRight }
    }

    Rectangle {
        id: toolbar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        color: theme.panel
        height: panelStack.height + tabRow.height + 24

        Column {
            width: parent.width
            spacing: 8
            padding: 8

            // the active tool's panel — a fixed viewport; overflowing panels scroll
            Item {
                id: panelStack
                width: parent.width - 16
                height: 140

                // FILTERS
                ListView {
                    anchors.fill: parent
                    visible: editor.tool === "filters"
                    orientation: ListView.Horizontal
                    spacing: 10
                    clip: true
                    model: editor.presets
                    delegate: Column {
                        required property var modelData
                        width: 74; spacing: 4
                        Rectangle {
                            width: 74; height: 74; radius: 8; clip: true
                            color: theme.panelAlt
                            border.color: editor.preset === modelData.name ? theme.accent : "transparent"
                            border.width: 2
                            Image {
                                anchors.fill: parent; anchors.margins: 2
                                source: editor.photo ? editor.photo.fileUrl : ""
                                sourceSize.width: 150; sourceSize.height: 150
                                fillMode: Image.PreserveAspectCrop
                                visible: false
                            }
                            MultiEffect {
                                anchors.fill: parent; anchors.margins: 2
                                source: parent.children[0]
                                saturation: modelData.s
                                contrast: modelData.c
                                brightness: modelData.b
                                colorization: modelData.se > 0 ? modelData.se * 0.7 : Math.abs(modelData.w) * 0.5
                                colorizationColor: modelData.se > 0 ? Qt.rgba(0.44,0.26,0.08,1)
                                                 : modelData.w >= 0 ? Qt.rgba(1,0.55,0.1,1) : Qt.rgba(0.1,0.4,1,1)
                            }
                            TapHandler { onTapped: editor.applyPreset(modelData) }
                        }
                        Label { text: modelData.name; color: theme.muted; font.pixelSize: 11
                                width: 74; horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight }
                    }
                }

                // ADJUST — scrolls if the sliders don't all fit
                Flickable {
                    anchors.fill: parent
                    visible: editor.tool === "adjust"
                    clip: true
                    contentHeight: adjustCol.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    Column {
                        id: adjustCol
                        width: parent.width
                        spacing: 4
                        Slider0 { label: "Brightness"; value: editor.brightness; onValueChanged: editor.brightness = value }
                        Slider0 { label: "Contrast";   value: editor.contrast;   onValueChanged: editor.contrast = value }
                        Slider0 { label: "Saturation"; value: editor.saturation; onValueChanged: editor.saturation = value }
                        Slider0 { label: "Warmth";     value: editor.warmth;     onValueChanged: editor.warmth = value }
                    }
                }

                // EFFECTS (fade / vignette, 0..1) — also scrollable
                Flickable {
                    anchors.fill: parent
                    visible: editor.tool === "effects"
                    clip: true
                    contentHeight: effectsCol.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds
                    ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                    Column {
                        id: effectsCol
                        width: parent.width
                        spacing: 4
                        RowLayout {
                            width: parent.width; spacing: 10
                            Label { text: "Fade"; color: theme.text; font.pixelSize: 13; Layout.preferredWidth: 92 }
                            Slider { from: 0; to: 1; value: editor.fade; Layout.fillWidth: true
                                     onPressedChanged: if (pressed) editor.pushHistory()
                                     onValueChanged: editor.fade = value; Material.accent: theme.accent }
                        }
                        RowLayout {
                            width: parent.width; spacing: 10
                            Label { text: "Vignette"; color: theme.text; font.pixelSize: 13; Layout.preferredWidth: 92 }
                            Slider { from: 0; to: 1; value: editor.vignette; Layout.fillWidth: true
                                     onPressedChanged: if (pressed) editor.pushHistory()
                                     onValueChanged: editor.vignette = value; Material.accent: theme.accent }
                        }
                    }
                }

                // DRAW — a color and a brush size; then draw on the photo
                Column {
                    anchors.fill: parent
                    visible: editor.tool === "draw"
                    spacing: 12
                    Row {
                        spacing: 10
                        Repeater {
                            model: ["#ff3b30", "#ffcc00", "#34c759", "#0a84ff", "#ffffff", "#000000"]
                            delegate: Rectangle {
                                required property var modelData
                                width: 34; height: 34; radius: 17
                                color: modelData
                                border.color: editor.penColor == modelData ? theme.accent : "#66ffffff"
                                border.width: editor.penColor == modelData ? 3 : 1
                                TapHandler { onTapped: editor.penColor = modelData }
                            }
                        }
                    }
                    Row {
                        spacing: 14
                        Label { text: "Brush"; color: theme.text; font.pixelSize: 13; anchors.verticalCenter: parent.verticalCenter }
                        Repeater {
                            model: [{ w: 0.006, d: 8 }, { w: 0.012, d: 14 }, { w: 0.024, d: 22 }]
                            delegate: Rectangle {
                                required property var modelData
                                width: 34; height: 34; radius: 17
                                color: "transparent"
                                border.color: editor.penWidth === modelData.w ? theme.accent : "#66ffffff"
                                border.width: editor.penWidth === modelData.w ? 2 : 1
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: modelData.d; height: modelData.d; radius: width / 2
                                    color: editor.penColor
                                }
                                TapHandler { onTapped: editor.penWidth = modelData.w }
                            }
                        }
                    }
                    Label { text: "Draw on the photo with your finger"; color: theme.muted; font.pixelSize: 12 }
                }

                // ROTATE / FLIP / STRAIGHTEN
                Column {
                    anchors.fill: parent
                    visible: editor.tool === "crop"
                    spacing: 8
                    RowLayout {
                        width: parent.width
                        Item { Layout.fillWidth: true }
                        Button { text: "⟲ Rotate"; flat: true; onClicked: { editor.pushHistory(); editor.photoRot = (editor.photoRot + 270) % 360 } }
                        Button { text: "⟳ Rotate"; flat: true; onClicked: { editor.pushHistory(); editor.photoRot = (editor.photoRot + 90) % 360 } }
                        Button { text: "⇄ Flip"; flat: true; onClicked: { editor.pushHistory(); editor.flipH = !editor.flipH } }
                        Button { text: "⇅ Flip"; flat: true; onClicked: { editor.pushHistory(); editor.flipV = !editor.flipV } }
                        Item { Layout.fillWidth: true }
                    }
                    RowLayout {
                        width: parent.width; spacing: 10
                        Label { text: "Straighten"; color: theme.text; font.pixelSize: 13; Layout.preferredWidth: 92 }
                        Slider {
                            id: sttSlider
                            from: -15; to: 15; value: editor.straighten; Layout.fillWidth: true
                            Material.accent: theme.accent
                            onPressedChanged: if (pressed) editor.pushHistory()
                            onValueChanged: editor.straighten = value
                        }
                        Label { text: (editor.straighten >= 0 ? "+" : "") + editor.straighten.toFixed(1) + "°"
                                color: theme.muted; font.pixelSize: 12; Layout.preferredWidth: 44; horizontalAlignment: Text.AlignRight }
                    }
                }
            }

            // tool tabs
            RowLayout {
                id: tabRow
                width: parent.width - 16
                spacing: 0
                Repeater {
                    model: [ { key: "filters", label: "Filters" }, { key: "adjust", label: "Adjust" },
                             { key: "effects", label: "Effects" }, { key: "draw", label: "Draw" },
                             { key: "crop", label: "Crop" } ]
                    delegate: Button {
                        required property var modelData
                        Layout.fillWidth: true
                        flat: true
                        text: modelData.label
                        font.bold: editor.tool === modelData.key
                        palette.buttonText: editor.tool === modelData.key ? theme.accent : theme.muted
                        onClicked: editor.tool = modelData.key
                    }
                }
            }
        }
    }

    // ---- top bar: cancel / undo / save ---------------------------------------------------
    RowLayout {
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.margins: 10
        z: 2
        Button { text: "Cancel"; flat: true; palette.buttonText: "#ffffff"; onClicked: editor.cancelled() }
        Item { Layout.fillWidth: true }
        Button {
            text: "Undo"
            flat: true
            enabled: editor.canUndo
            palette.buttonText: editor.canUndo ? "#ffffff" : "#66ffffff"
            onClicked: editor.undo()
        }
        Button {
            text: "Save"
            highlighted: true
            Material.accent: theme.accent
            onClicked: editor.doSave()
        }
    }

    function doSave() {
        // grab the edited photo (effects + pen included) to a JPEG next to the original —
        // that folder is one of the phone's scanned roots, so it appears on the next scan.
        const src = editor.photo ? (editor.photo.path || "") : ""
        if (!src.length) { editor.cancelled(); return }
        const slash = src.lastIndexOf("/")
        const dot = src.lastIndexOf(".")
        const base = (dot > slash ? src.substring(0, dot) : src)
        const path = base + "-PW" + Date.now() + ".jpg"
        frame.grabToImage(function (result) {
            if (result.saveToFile(path)) {
                library.rescanPhotos()   // pick the new file up now, not on the next timer tick
                editor.saved(path)
            } else {
                editor.cancelled()
            }
        })
    }
}
