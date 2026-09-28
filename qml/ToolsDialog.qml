import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

// Tools — clean-up work over the whole library, each one a quick question instead of a hunt
// photo by photo: small copies of photos (a USB import's thumbnail cache), groups of
// near-identical photos, faces nobody has named yet, and screenshots and memes grouped by
// where they came from. Same look as Settings: sections on
// the left, the tool on the right. Deleting goes to the system trash (photo.delete).
Dialog {
    id: dlg
    required property QtObject theme
    required property QtObject icons
    property int section: 0               // 0 Thumbnails · 1 Similar photos · 2 Unnamed faces · 3 Screenshots & memes · 4 From phones · 5 Removed from Wagon · 6 Google Photos

    function openAt(s) { section = s; open() }

    readonly property var similar: { try { return JSON.parse(library.toolsSimilar) } catch (e) { return ({}) } }
    readonly property var thumbs: { try { return JSON.parse(library.toolsThumbs) } catch (e) { return ({}) } }
    readonly property var face: { try { return JSON.parse(library.toolsFace) } catch (e) { return ({}) } }
    readonly property var junk: { try { return JSON.parse(library.toolsJunk) } catch (e) { return ({}) } }
    readonly property var imports: { try { return JSON.parse(library.toolsImports) } catch (e) { return ({}) } }
    readonly property var removed: { try { return JSON.parse(library.removedList) } catch (e) { return ({}) } }
    readonly property var takeout: { try { return JSON.parse(library.toolsTakeout) } catch (e) { return ({}) } }
    property string junkKind: "screenshot"

    title: "Tools"
    modal: true
    anchors.centerIn: Overlay.overlay
    width: Math.min(980, (Overlay.overlay ? Overlay.overlay.width : 1000) - 40)
    height: Math.min(700, (Overlay.overlay ? Overlay.overlay.height : 760) - 40)
    padding: 0
    closePolicy: Popup.CloseOnEscape
    background: Rectangle { color: theme.panel; border.color: theme.separator; radius: 10 }
    header: null
    footer: null

    onOpened: refresh()
    onSectionChanged: if (opened) refresh()
    function refresh() {
        library.pollSimilar()
        if (section === 0) library.loadThumbTool()
        if (section === 2) library.loadUnidentified(Math.max(0, face.offset || 0))
        if (section === 3) library.loadJunk(junkKind)
        if (section === 4) library.loadImports()
        if (section === 5) library.loadRemoved()
        if (section === 6) library.loadTakeout()
    }
    // an import from Google Photos runs in the core: follow it
    Timer {
        interval: 1000; repeat: true
        running: dlg.opened && dlg.section === 6 && dlg.takeout.running === true
        onTriggered: library.loadTakeout()
    }
    onJunkKindChanged: if (opened && section === 3) library.loadJunk(junkKind)

    // the similar-photos scan runs in the daemon: follow it while it runs
    Timer {
        interval: 1500; repeat: true
        running: dlg.opened && dlg.similar.running === true
        onTriggered: library.pollSimilar()
    }
    // opened before the core answered (at start-up): ask again until there is something
    Timer {
        interval: 1000; repeat: true
        running: dlg.opened && ((dlg.section === 2 && dlg.face.total === undefined)
                                || (dlg.section === 3 && dlg.junk.kind !== dlg.junkKind)
                                || (dlg.section < 2 && dlg.similar.running === undefined))
        onTriggered: dlg.refresh()
    }
    // a finished scan also answers the thumbnail question
    property bool _wasRunning: false
    Connections {
        target: library
        function onToolsSimilarChanged() {
            const running = dlg.similar.running === true
            if (dlg._wasRunning && !running) library.loadThumbTool()
            dlg._wasRunning = running
        }
    }

    // ---- small shared pieces -----------------------------------------------------------
    component NavRow: Rectangle {
        id: nav
        required property int index
        required property string label
        required property string hint
        Layout.fillWidth: true
        Layout.preferredHeight: 46
        radius: 7
        color: dlg.section === index ? dlg.theme.accent : (hov.hovered ? dlg.theme.hover : "transparent")
        ColumnLayout {
            anchors.fill: parent; anchors.leftMargin: 11; anchors.rightMargin: 8
            spacing: 0
            Item { Layout.fillHeight: true }
            Label { text: nav.label; color: dlg.section === nav.index ? "white" : dlg.theme.text; font.pixelSize: 13; font.weight: Font.DemiBold }
            Label { text: nav.hint; color: dlg.section === nav.index ? Qt.rgba(1, 1, 1, 0.8) : dlg.theme.muted; font.pixelSize: 11; elide: Text.ElideRight; Layout.fillWidth: true }
            Item { Layout.fillHeight: true }
        }
        HoverHandler { id: hov }
        TapHandler { onTapped: dlg.section = nav.index }
    }

    // A photo tile with a check mark; `checked` drawn, `toggled` reported.
    component PickTile: Item {
        id: pt
        property var photo: ({})
        property bool checked: false
        property string badge: ""
        property real side: 112
        signal toggled()
        width: side; height: side
        Rectangle { anchors.fill: parent; radius: 5; color: dlg.theme.tile }
        Image {
            anchors.fill: parent; anchors.margins: 1
            source: pt.photo.thumbUrl || ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true; cache: false
            sourceSize.width: 224; sourceSize.height: 224
            opacity: pt.checked ? 0.55 : 1
        }
        Rectangle {
            anchors.fill: parent; radius: 5; color: "transparent"
            border.width: pt.checked ? 3 : 0; border.color: "#e5484d"
        }
        Rectangle {
            visible: pt.checked
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 6
            width: 22; height: 22; radius: 11; color: "#e5484d"
            Label { anchors.centerIn: parent; text: "✕"; color: "white"; font.pixelSize: 12; font.bold: true }
        }
        Rectangle {
            visible: pt.badge.length > 0
            anchors.left: parent.left; anchors.bottom: parent.bottom; anchors.margins: 5
            radius: 4; color: Qt.rgba(0, 0, 0, 0.62)
            width: bl.implicitWidth + 10; height: bl.implicitHeight + 4
            Label { id: bl; anchors.centerIn: parent; text: pt.badge; color: "white"; font.pixelSize: 10 }
        }
        TapHandler { onTapped: pt.toggled() }
    }

    // A two-step "move to trash": the first press arms it, the second confirms.
    component TrashButton: Button {
        id: tb
        property int count: 0
        property bool armed: false
        signal confirmed()
        enabled: count > 0
        text: armed ? "Confirm: move " + count + " to Trash" : "Move " + count + " to Trash"
        highlighted: armed
        onClicked: { if (armed) { armed = false; confirmed() } else armed = true }
        onCountChanged: armed = false
        Timer { running: tb.armed; interval: 5000; onTriggered: tb.armed = false }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ---- sections ----
        Rectangle {
            Layout.preferredWidth: 230; Layout.fillHeight: true
            color: dlg.theme.sidebar; radius: 10
            ColumnLayout {
                anchors.fill: parent; anchors.margins: 10
                spacing: 4
                Label { text: "Tools"; color: dlg.theme.text; font.pixelSize: 17; font.weight: Font.DemiBold; Layout.bottomMargin: 8; Layout.leftMargin: 6; Layout.topMargin: 4 }
                NavRow { index: 0; label: "Thumbnails"; hint: dlg.thumbs.scanned ? (dlg.thumbs.redundant.length + " small copies") : "Small copies of photos" }
                NavRow { index: 1; label: "Similar photos"; hint: dlg.similar.done ? (dlg.similar.groups.length + " groups") : "Near-identical photos" }
                NavRow { index: 2; label: "Unnamed faces"; hint: dlg.face.total !== undefined ? (dlg.face.total + " to go") : "Name them quickly" }
                NavRow { index: 3; label: "Screenshots & memes"; hint: dlg.junk.total !== undefined ? (dlg.junk.total + (dlg.junk.kind === "meme" ? " memes" : " screenshots")) : "Remove them by group" }
                NavRow { index: 4; label: "From phones"; hint: dlg.imports.count !== undefined ? (dlg.imports.count + " photos") : "Photos the phones sent" }
                NavRow { index: 5; label: "Removed from Wagon"; hint: dlg.removed.items !== undefined ? (dlg.removed.items.length + (dlg.removed.items.length === 1 ? " photo" : " photos")) : "Out of the library, kept on disk" }
                NavRow { index: 6; label: "Google Photos"; hint: dlg.takeout.running === true ? ("Importing · " + (dlg.takeout.done || 0) + " of " + (dlg.takeout.total || 0)) : "Import a Takeout export" }
                Item { Layout.fillHeight: true }
                Button { text: "Close"; Layout.fillWidth: true; onClicked: dlg.close() }
            }
        }

        StackLayout {
            Layout.fillWidth: true; Layout.fillHeight: true
            Layout.margins: 18
            currentIndex: dlg.section

            // ================= Thumbnails =================
            ColumnLayout {
                id: thumbTool
                spacing: 10
                property var marked: ({})        // photo id → true (the orphans the user picked)
                property int markVersion: 0
                readonly property var redundant: dlg.thumbs.redundant || []
                readonly property var orphans: dlg.thumbs.orphans || []
                function orphanIds() { markVersion; return Object.keys(marked).filter(k => marked[k]).map(Number) }

                Label { text: "Thumbnails"; color: dlg.theme.text; font.pixelSize: 20; font.weight: Font.DemiBold }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 13
                    text: "Small copies (512 px or less) of photos you also have in full size — usually the phone's thumbnail cache that a USB import brought along. The full-size photo stays; the copy goes to the Trash."
                }
                RowLayout {
                    visible: !dlg.thumbs.scanned
                    spacing: 10
                    Button {
                        text: dlg.similar.running ? "Scanning…" : "Scan the library"
                        enabled: !dlg.similar.running
                        onClicked: library.startSimilarScan(0.95)
                    }
                    ProgressBar {
                        visible: dlg.similar.running === true
                        Layout.preferredWidth: 260
                        from: 0; to: Math.max(1, dlg.similar.total || 1); value: dlg.similar.progress || 0
                    }
                    Label { visible: dlg.similar.running === true; color: dlg.theme.muted; text: (dlg.similar.progress || 0) + " / " + (dlg.similar.total || 0) }
                }
                RowLayout {
                    visible: dlg.thumbs.scanned === true
                    Label { text: thumbTool.redundant.length + " small copies with a full-size photo"; color: dlg.theme.text; font.pixelSize: 14; font.weight: Font.DemiBold; Layout.fillWidth: true }
                    TrashButton {
                        count: thumbTool.redundant.length
                        onConfirmed: library.trashPhotos(JSON.stringify(thumbTool.redundant.map(r => r.photo.id)))
                    }
                }
                GridView {
                    visible: dlg.thumbs.scanned === true
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    cellWidth: 104; cellHeight: 104
                    model: thumbTool.redundant
                    ScrollBar.vertical: ScrollBar { }
                    delegate: PickTile {
                        required property var modelData
                        side: 98; photo: modelData.photo; checked: true
                        badge: modelData.photo.maxSide + " px · full " + modelData.keep.maxSide + " px"
                    }
                }
                RowLayout {
                    visible: dlg.thumbs.scanned === true && thumbTool.orphans.length > 0
                    Label { text: thumbTool.orphans.length + " small images with no full-size copy — pick the ones to remove"; color: dlg.theme.text; font.pixelSize: 13; Layout.fillWidth: true; elide: Text.ElideRight }
                    TrashButton {
                        count: thumbTool.orphanIds().length
                        onConfirmed: { library.trashPhotos(JSON.stringify(thumbTool.orphanIds())); thumbTool.marked = ({}); thumbTool.markVersion++ }
                    }
                }
                GridView {
                    visible: dlg.thumbs.scanned === true && thumbTool.orphans.length > 0
                    Layout.fillWidth: true; Layout.preferredHeight: 190
                    clip: true
                    cellWidth: 94; cellHeight: 94
                    model: thumbTool.orphans
                    ScrollBar.vertical: ScrollBar { }
                    delegate: PickTile {
                        required property var modelData
                        side: 88; photo: modelData
                        checked: { thumbTool.markVersion; return thumbTool.marked[modelData.id] === true }
                        badge: modelData.maxSide + " px"
                        onToggled: { thumbTool.marked[modelData.id] = !thumbTool.marked[modelData.id]; thumbTool.markVersion++ }
                    }
                }
            }

            // ================= Similar photos =================
            ColumnLayout {
                id: simTool
                spacing: 10
                // group identity (its photo ids) → id of the photo kept (default: the group's best,
                // first). Keyed by identity, not position: deleting elsewhere shifts the positions,
                // and a choice must never land on another group (it would doom all of that one).
                property var keepOf: ({})
                property int keepVersion: 0
                readonly property var groups: dlg.similar.groups || []
                function groupKey(g) { return g.items.map(it => it.id).sort((a, b) => a - b).join(",") }
                function keepId(gi) {
                    keepVersion
                    const g = groups[gi]
                    if (!g || !g.items.length) return -1
                    const k = keepOf[groupKey(g)]
                    return k !== undefined && g.items.some(it => it.id === k) ? k : g.items[0].id
                }
                function doomed() {
                    keepVersion
                    const out = []
                    for (let gi = 0; gi < groups.length; gi++) {
                        const k = keepId(gi)
                        for (const it of groups[gi].items) if (it.id !== k) out.push(it.id)
                    }
                    return out
                }

                Label { text: "Similar photos"; color: dlg.theme.text; font.pixelSize: 20; font.weight: Font.DemiBold }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 13
                    text: "Groups of near-identical photos: bursts, re-saves, copies. The best one of each group is kept (the largest); tap another to keep it instead. The rest go to the Trash."
                }
                RowLayout {
                    spacing: 10
                    Label { text: "Alike at least"; color: dlg.theme.text }
                    Slider { id: sim; from: 0.90; to: 0.99; stepSize: 0.01; value: dlg.similar.minSimilarity || 0.95; Layout.preferredWidth: 180 }
                    Label { text: Math.round(sim.value * 100) + "%"; color: dlg.theme.text; Layout.preferredWidth: 40 }
                    Button {
                        text: dlg.similar.running ? "Scanning…" : (dlg.similar.done ? "Scan again" : "Scan the library")
                        enabled: !dlg.similar.running
                        onClicked: { simTool.keepOf = ({}); simTool.keepVersion++; library.startSimilarScan(sim.value) }
                    }
                    ProgressBar {
                        visible: dlg.similar.running === true
                        Layout.fillWidth: true
                        from: 0; to: Math.max(1, dlg.similar.total || 1); value: dlg.similar.progress || 0
                    }
                    Item { Layout.fillWidth: true; visible: !dlg.similar.running }
                    TrashButton {
                        count: simTool.doomed().length
                        onConfirmed: library.trashPhotos(JSON.stringify(simTool.doomed()))
                    }
                }
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    spacing: 12
                    model: simTool.groups
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Flickable {
                        id: grp
                        required property var modelData
                        required property int index
                        width: ListView.view.width
                        height: 124
                        contentWidth: rowT.implicitWidth
                        clip: true
                        Row {
                            id: rowT
                            spacing: 6
                            Repeater {
                                model: grp.modelData.items
                                delegate: PickTile {
                                    required property var modelData
                                    side: 118; photo: modelData
                                    checked: modelData.id !== simTool.keepId(grp.index)
                                    badge: modelData.id === simTool.keepId(grp.index) ? "Keep · " + modelData.maxSide + " px" : modelData.maxSide + " px"
                                    onToggled: { simTool.keepOf[simTool.groupKey(grp.modelData)] = modelData.id; simTool.keepVersion++ }
                                }
                            }
                        }
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: dlg.similar.done === true && simTool.groups.length === 0
                        text: "No near-identical photos at this level."
                        color: dlg.theme.muted
                    }
                }
            }

            // ================= Unnamed faces =================
            ColumnLayout {
                id: faceTool
                spacing: 12
                readonly property var item: dlg.face.item
                readonly property int offset: dlg.face.offset || 0
                readonly property bool isCluster: item !== undefined && item.type === "cluster"
                readonly property var candidates: dlg.face.candidates || []
                // faces of a group the user says are not this person (the automatic grouping mixes
                // people up, babies especially): let go before the group is named or merged
                property var excluded: ({})
                property int exVersion: 0
                onItemChanged: { excluded = ({}); exVersion++ }
                // an action in flight: nothing else acts on the item shown until the next one loads
                property bool busy: false
                Connections {
                    target: library
                    function onToolsFaceChanged() {
                        faceTool.busy = false
                        // resolved past the end (the list shrank under us): step back onto it
                        const f = dlg.face
                        if (!f.item && f.total > 0 && (f.offset || 0) >= f.total) library.loadUnidentified(f.total - 1)
                    }
                }
                function excludedJson() { exVersion; return JSON.stringify(Object.keys(excluded).filter(k => excluded[k]).map(Number)) }
                function pick(c) {
                    if (!item || busy) return
                    busy = true
                    if (isCluster) library.resolveCluster(item.personId, c.id, "", offset, excludedJson())
                    else library.resolveFace(item.faceId, c.id, "", offset)
                }
                function named(n) {
                    if (!item || busy || !n.trim().length) return
                    busy = true
                    if (isCluster) library.resolveCluster(item.personId, 0, n, offset, excludedJson())
                    else library.resolveFace(item.faceId, 0, n, offset)
                    newName.text = ""
                }
                function notFaces() {
                    if (!item || busy) return
                    busy = true
                    if (isCluster) library.dismissCluster(item.personId, offset)
                    else library.dismissFace(item.faceId, offset)
                }
                function skip() { if (!busy) { busy = true; library.loadUnidentified(offset + 1) } }
                function back() { if (!busy) { busy = true; library.loadUnidentified(Math.max(0, offset - 1)) } }
                function breakUp() { if (item && !busy) { busy = true; library.dissolveCluster(item.personId, offset) } }

                Label { text: "Unnamed faces"; color: dlg.theme.text; font.pixelSize: 20; font.weight: Font.DemiBold }
                Label {
                    Layout.fillWidth: true; color: dlg.theme.muted; font.pixelSize: 13; wrapMode: Text.WordWrap
                    text: dlg.face.total === undefined ? "Loading…"
                        : dlg.face.total === 0 ? "Every face has a name."
                        : faceTool.isCluster
                          ? "Group " + (faceTool.offset + 1) + " of " + dlg.face.clusters + " — " + faceTool.item.count + " faces the app thinks are one person. Tap any that is someone else before naming the group. " + dlg.face.loose + " single faces after the groups."
                          : "Face " + (faceTool.offset - dlg.face.clusters + 1) + " of " + dlg.face.loose + "."
                }

                // the faces themselves
                Flow {
                    visible: faceTool.item !== undefined
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: faceTool.isCluster ? faceTool.item.faces : (faceTool.item ? [faceTool.item] : [])
                        delegate: Rectangle {
                            id: fc
                            required property var modelData
                            readonly property bool out_: { faceTool.exVersion; return faceTool.isCluster && faceTool.excluded[modelData.faceId] === true }
                            width: faceTool.isCluster ? 84 : 150; height: width; radius: 8
                            color: dlg.theme.tile; clip: true
                            Image { anchors.fill: parent; source: fc.modelData.url || ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false; opacity: fc.out_ ? 0.35 : 1 }
                            Rectangle {
                                anchors.fill: parent; radius: 8; color: "transparent"
                                border.width: fc.out_ ? 3 : 0; border.color: "#e5484d"
                            }
                            Label { visible: fc.out_; anchors.centerIn: parent; text: "Not them"; color: "white"; font.pixelSize: 11; font.bold: true
                                    background: Rectangle { color: "#e5484d"; radius: 4 } padding: 3 }
                            TapHandler {
                                enabled: faceTool.isCluster && !faceTool.busy
                                onTapped: { faceTool.excluded[fc.modelData.faceId] = !faceTool.excluded[fc.modelData.faceId]; faceTool.exVersion++ }
                            }
                        }
                    }
                    Rectangle {
                        visible: !faceTool.isCluster && faceTool.item !== undefined && (faceTool.item.photoThumbUrl || "").length > 0
                        width: 150; height: 150; radius: 8; color: dlg.theme.tile; clip: true
                        Image { anchors.fill: parent; source: faceTool.item ? (faceTool.item.photoThumbUrl || "") : ""; fillMode: Image.PreserveAspectCrop; asynchronous: true; cache: false }
                    }
                }

                Label { visible: faceTool.candidates.length > 0; text: "Is it…"; color: dlg.theme.text; font.pixelSize: 14; font.weight: Font.DemiBold }
                Flow {
                    Layout.fillWidth: true
                    spacing: 8
                    Repeater {
                        model: faceTool.candidates
                        delegate: Button {
                            required property var modelData
                            required property int index
                            enabled: !faceTool.busy
                            text: (index + 1) + "  " + modelData.name + (modelData.similarity !== undefined ? "  " + Math.round(modelData.similarity * 100) + "%" : "")
                            icon.source: modelData.coverUrl || ""
                            icon.color: "transparent"
                            icon.width: 32; icon.height: 32
                            onClicked: faceTool.pick(modelData)
                        }
                    }
                }
                RowLayout {
                    visible: faceTool.item !== undefined
                    spacing: 8
                    TextField {
                        id: newName
                        placeholderText: "Someone else — type a name and press Enter"
                        Layout.preferredWidth: 320
                        onAccepted: faceTool.named(text)
                    }
                    Button { text: "Name"; enabled: !faceTool.busy && newName.text.trim().length > 0; onClicked: faceTool.named(newName.text) }
                }
                RowLayout {
                    visible: faceTool.item !== undefined || faceTool.offset > 0
                    spacing: 8
                    Button { text: "← Back"; enabled: faceTool.offset > 0 && !faceTool.busy; onClicked: faceTool.back() }
                    Button { text: "Skip →"; visible: faceTool.item !== undefined; enabled: !faceTool.busy; onClicked: faceTool.skip() }
                    Item { Layout.fillWidth: true }
                    Button {
                        visible: faceTool.isCluster
                        enabled: !faceTool.busy
                        text: "Break up group"
                        ToolTip.visible: hovered; ToolTip.text: "Several people in one group: each face goes back on its own"
                        onClicked: faceTool.breakUp()
                    }
                    Button { visible: faceTool.item !== undefined; enabled: !faceTool.busy; text: faceTool.isCluster ? "Not faces" : "Not a face"; onClicked: faceTool.notFaces() }
                }
                Label { color: dlg.theme.muted; font.pixelSize: 11; text: "Keys: 1–6 pick a suggestion · S skip · B back · X not a face" }
                Item { Layout.fillHeight: true }

                // quick keys while the faces tool is showing (not while typing a name)
                Shortcut { sequence: "1"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy && faceTool.candidates.length > 0; onActivated: faceTool.pick(faceTool.candidates[0]) }
                Shortcut { sequence: "2"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy && faceTool.candidates.length > 1; onActivated: faceTool.pick(faceTool.candidates[1]) }
                Shortcut { sequence: "3"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy && faceTool.candidates.length > 2; onActivated: faceTool.pick(faceTool.candidates[2]) }
                Shortcut { sequence: "4"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy && faceTool.candidates.length > 3; onActivated: faceTool.pick(faceTool.candidates[3]) }
                Shortcut { sequence: "5"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy && faceTool.candidates.length > 4; onActivated: faceTool.pick(faceTool.candidates[4]) }
                Shortcut { sequence: "6"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy && faceTool.candidates.length > 5; onActivated: faceTool.pick(faceTool.candidates[5]) }
                Shortcut { sequence: "S"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy; onActivated: faceTool.skip() }
                Shortcut { sequence: "B"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy; onActivated: faceTool.back() }
                Shortcut { sequence: "X"; enabled: dlg.opened && dlg.section === 2 && !newName.activeFocus && !faceTool.busy; onActivated: faceTool.notFaces() }
            }

            // ================= Screenshots & memes =================
            ColumnLayout {
                id: junkTool
                spacing: 10
                // photo id → true: what goes to the Trash (nothing is picked until the user picks)
                property var marked: ({})
                property int markVersion: 0
                readonly property var groups: dlg.junk.kind === dlg.junkKind ? (dlg.junk.groups || []) : []
                // only what is on screen now: a pick that left the list (reclassified, deleted
                // elsewhere) is neither counted nor trashed
                function ids() {
                    markVersion
                    const out = []
                    for (const g of groups) for (const it of g.items) if (marked[it.id] === true) out.push(it.id)
                    return out
                }
                function groupMarked(g) { markVersion; return g.items.length > 0 && g.items.every(it => marked[it.id] === true) }
                function groupCount(g) { markVersion; return g.items.filter(it => marked[it.id] === true).length }
                function setGroup(g, on) { for (const it of g.items) marked[it.id] = on; markVersion++ }
                function setAll(on) { for (const g of groups) for (const it of g.items) marked[it.id] = on; markVersion++ }
                function clear() { marked = ({}); markVersion++ }
                Connections { target: dlg; function onJunkKindChanged() { junkTool.clear() } }

                Label { text: "Screenshots & memes"; color: dlg.theme.text; font.pixelSize: 20; font.weight: Font.DemiBold }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 13
                    text: "Grouped by where they came from — the app in a screenshot's name, WhatsApp — or else by month. Pick a whole group with one click, or single pictures; they go to the Trash."
                }
                RowLayout {
                    spacing: 8
                    Repeater {
                        model: [{ kind: "screenshot", label: "Screenshots" }, { kind: "meme", label: "Memes" }]
                        delegate: Button {
                            required property var modelData
                            text: modelData.label
                            checkable: true
                            checked: dlg.junkKind === modelData.kind
                            highlighted: checked
                            onClicked: dlg.junkKind = modelData.kind
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Label {
                        color: dlg.theme.muted
                        text: dlg.junk.kind !== dlg.junkKind ? "Loading…"
                            : junkTool.groups.length + " groups · " + (dlg.junk.total || 0) + (dlg.junkKind === "meme" ? " memes" : " screenshots")
                    }
                    Button { text: "Select all"; enabled: junkTool.groups.length > 0; onClicked: junkTool.setAll(true) }
                    Button { text: "Clear"; enabled: junkTool.ids().length > 0; onClicked: junkTool.clear() }
                    TrashButton {
                        count: junkTool.ids().length
                        onConfirmed: { library.trashPhotos(JSON.stringify(junkTool.ids())); junkTool.clear() }
                    }
                }
                ListView {
                    Layout.fillWidth: true; Layout.fillHeight: true
                    clip: true
                    spacing: 14
                    id: junkList
                    model: junkTool.groups
                    reuseItems: false
                    ScrollBar.vertical: ScrollBar { }
                    // plain anchors, not a layout: a ColumnLayout delegate laid out late drew the first
                    // group's tiles over its own header
                    delegate: Item {
                        id: jg
                        required property var modelData
                        width: ListView.view.width
                        height: 36 + 6 + 112
                        readonly property bool all: junkTool.groupMarked(modelData)
                        RowLayout {
                            id: jgHead
                            anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                            height: 36
                            spacing: 10
                            Label { text: jg.modelData.label; color: dlg.theme.text; font.pixelSize: 14; font.weight: Font.DemiBold }
                            Label {
                                color: dlg.theme.muted; font.pixelSize: 12
                                text: jg.modelData.items.length + (junkTool.groupCount(jg.modelData) > 0 && !jg.all ? " · " + junkTool.groupCount(jg.modelData) + " picked" : "")
                            }
                            Item { Layout.fillWidth: true }
                            Button {
                                flat: true
                                text: jg.all ? "Unpick group" : "Pick group (" + jg.modelData.items.length + ")"
                                onClicked: junkTool.setGroup(jg.modelData, !jg.all)
                            }
                        }
                        ListView {
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.top: jgHead.bottom; anchors.topMargin: 6
                            height: 112
                            orientation: ListView.Horizontal
                            spacing: 6
                            clip: true
                            model: jg.modelData.items
                            ScrollBar.horizontal: ScrollBar { }
                            delegate: PickTile {
                                required property var modelData
                                side: 104; photo: modelData
                                checked: { junkTool.markVersion; return junkTool.marked[modelData.id] === true }
                                onToggled: { junkTool.marked[modelData.id] = !junkTool.marked[modelData.id]; junkTool.markVersion++ }
                                HoverHandler { id: th }
                                ToolTip.visible: th.hovered
                                ToolTip.delay: 600
                                ToolTip.text: modelData.name + " · " + new Date(modelData.takenTs * 1000).toLocaleDateString()
                            }
                        }
                    }
                    Label {
                        anchors.centerIn: parent
                        visible: dlg.junk.kind === dlg.junkKind && junkTool.groups.length === 0
                        text: dlg.junkKind === "meme" ? "No memes in the library." : "No screenshots in the library."
                        color: dlg.theme.muted
                    }
                }
            }

            // ================= Photos the phones sent =================
            ColumnLayout {
                id: importsTool
                spacing: 12
                property bool armed: false
                property bool busy: false
                Connections {
                    target: library
                    function onToolsImportsChanged() { importsTool.busy = false }
                }
                function mb(b) {
                    return b >= 1e9 ? (b / 1e9).toFixed(1) + " GB" : b >= 1e6 ? Math.round(b / 1e6) + " MB"
                        : Math.max(1, Math.round(b / 1e3)) + " KB"
                }

                Label { text: "Photos from phones"; color: dlg.theme.text; font.pixelSize: 20; font.weight: Font.DemiBold }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 13
                    text: "Everything the phones sent to this computer. Removing them moves the files to the Trash and takes them out of the library; the phones then send them again on their next sync."
                }
                Label {
                    color: dlg.theme.text; font.pixelSize: 15
                    text: dlg.imports.done === true
                        ? (dlg.imports.removed + " photos moved to the Trash"
                           + (dlg.imports.failed > 0 ? " · " + dlg.imports.failed + " could not be moved and stay" : "")
                           + ". The phones will send them again.")
                        : dlg.imports.count === undefined ? "Counting…"
                        : dlg.imports.count === 0 ? "No photos from phones on this computer."
                        : dlg.imports.count + " photos · " + importsTool.mb(dlg.imports.bytes || 0)
                }
                RowLayout {
                    spacing: 8
                    visible: dlg.imports.done !== true && (dlg.imports.count || 0) > 0
                    Button {
                        text: importsTool.busy ? "Removing…"
                            : importsTool.armed ? "Confirm: move " + dlg.imports.count + " photos to the Trash"
                            : "Remove from this computer…"
                        highlighted: importsTool.armed
                        enabled: !importsTool.busy
                        onClicked: {
                            if (!importsTool.armed) { importsTool.armed = true; return }
                            importsTool.armed = false
                            importsTool.busy = true
                            library.removeImports()
                        }
                    }
                    Button { text: "Cancel"; visible: importsTool.armed; onClicked: importsTool.armed = false }
                    Timer { running: importsTool.armed; interval: 8000; onTriggered: importsTool.armed = false }
                }
                Label {
                    visible: importsTool.armed
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 12
                    text: "They can be restored from the Trash. Albums, favorites and names given to faces on these photos are lost."
                }
                Item { Layout.fillHeight: true }
            }

            // ================= Removed from Wagon =================
            ColumnLayout {
                id: removedTool
                spacing: 12
                readonly property var items: dlg.removed.items || []
                function restore(hashes) { library.restoreToWagon(JSON.stringify(hashes)) }

                Label { text: "Removed from Wagon"; color: dlg.theme.text; font.pixelSize: 20; font.weight: Font.DemiBold }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 13
                    text: "Photos taken out of the library with their files left on disk. They are not picked up again — not by a folder scan, not from a phone — until you restore them."
                }
                RowLayout {
                    spacing: 8
                    Label {
                        color: dlg.theme.text; font.pixelSize: 15
                        text: dlg.removed.items === undefined ? "Loading…"
                            : removedTool.items.length === 0 ? "Nothing removed from Wagon."
                            : removedTool.items.length + (removedTool.items.length === 1 ? " photo" : " photos")
                    }
                    Item { Layout.fillWidth: true }
                    Button {
                        text: "Restore all"
                        visible: removedTool.items.length > 1
                        onClicked: removedTool.restore(removedTool.items.map(it => it.hash))
                    }
                }
                ListView {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 6
                    model: removedTool.items
                    ScrollBar.vertical: ScrollBar { }
                    delegate: Rectangle {
                        required property var modelData
                        width: ListView.view.width - 12
                        height: 64
                        radius: 6
                        color: dlg.theme.tile
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 10
                            Rectangle {
                                Layout.preferredWidth: 52; Layout.preferredHeight: 52
                                radius: 4; clip: true; color: dlg.theme.panel
                                Image {
                                    anchors.fill: parent
                                    source: modelData.thumbUrl || ""
                                    fillMode: Image.PreserveAspectCrop
                                    asynchronous: true
                                    sourceSize.width: 104; sourceSize.height: 104
                                }
                            }
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Label { text: modelData.name || modelData.hash.substring(0, 12); color: dlg.theme.text; font.pixelSize: 13; elide: Text.ElideMiddle; Layout.fillWidth: true }
                                Label {
                                    Layout.fillWidth: true; elide: Text.ElideMiddle; font.pixelSize: 11
                                    color: modelData.exists ? dlg.theme.muted : "#e5484d"
                                    text: (modelData.exists ? (modelData.path || "") : "The file is no longer at " + (modelData.path || "its place"))
                                        + " · removed " + (modelData.removedAt || "").substring(0, 10)
                                }
                            }
                            Button { text: "Restore"; onClicked: removedTool.restore([modelData.hash]) }
                        }
                    }
                }
            }

            // ================= Google Photos (Takeout) =================
            ColumnLayout {
                id: takeoutTool
                spacing: 12
                readonly property var rep: dlg.takeout.report || ({})
                readonly property bool running: dlg.takeout.running === true
                readonly property bool finished: dlg.takeout.finishedAt !== undefined && !running
                FolderDialog {
                    id: takeoutFolder
                    title: "The unpacked Google Takeout folder"
                    onAccepted: library.takeoutImport(selectedFolder.toString())
                }

                Label { text: "Google Photos"; color: dlg.theme.text; font.pixelSize: 20; font.weight: Font.DemiBold }
                Label {
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 13
                    text: "Export your library at takeout.google.com (\u201cGoogle Photos\u201d only), unpack it into one folder and choose it here. Each photo comes with the date it was taken, its location, its description and the people named in Google; named folders become albums. Photos already in the library are not copied again. Nothing is deleted \u2014 not here, not in Google Photos."
                }
                RowLayout {
                    spacing: 8
                    Button {
                        text: takeoutTool.running ? "Importing\u2026" : "Choose the Takeout folder\u2026"
                        enabled: !takeoutTool.running
                        highlighted: !takeoutTool.running && !takeoutTool.finished
                        onClicked: takeoutFolder.open()
                    }
                    Button { text: "Stop"; visible: takeoutTool.running; onClicked: library.takeoutCancel() }
                    Button { text: "Open takeout.google.com"; visible: !takeoutTool.running; onClicked: Qt.openUrlExternally("https://takeout.google.com/") }
                }
                ProgressBar {
                    Layout.fillWidth: true
                    visible: takeoutTool.running || takeoutTool.finished
                    from: 0; to: Math.max(1, dlg.takeout.total || 0); value: dlg.takeout.done || 0
                }
                Label {
                    visible: takeoutTool.running || takeoutTool.finished
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.text; font.pixelSize: 14
                    text: (takeoutTool.running && dlg.takeout.phase === "reading the export" ? "Reading the export\u2026 \u00b7 "
                           : takeoutTool.running ? (dlg.takeout.done || 0) + " of " + (dlg.takeout.total || 0) + " \u00b7 "
                           : dlg.takeout.cancelled ? "Stopped \u00b7 " : "Done \u00b7 ")
                        + (takeoutTool.rep.imported || 0) + " new, " + (takeoutTool.rep.alreadyPresent || 0) + " already here"
                        + ((takeoutTool.rep.skippedDeleted || 0) > 0 ? ", " + takeoutTool.rep.skippedDeleted + " kept out (deleted in Photo Wagon)" : "")
                        + ((takeoutTool.rep.failuresTotal || 0) > 0 ? ", " + takeoutTool.rep.failuresTotal + " failed" : "")
                }
                Label {
                    visible: takeoutTool.running || takeoutTool.finished
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 12
                    text: (takeoutTool.rep.albumsCreated || 0) + " albums created \u00b7 " + (takeoutTool.rep.albumMemberships || 0) + " photos put in albums \u00b7 "
                        + (takeoutTool.rep.locations || 0) + " locations \u00b7 " + (takeoutTool.rep.favorites || 0) + " favorites \u00b7 "
                        + (takeoutTool.rep.keywords || 0) + " words (descriptions, people)"
                        + ((takeoutTool.rep.withoutSidecar || 0) > 0 ? " \u00b7 " + takeoutTool.rep.withoutSidecar + " without Google data" : "")
                        + (Object.keys(takeoutTool.rep.unsupported || {}).length > 0
                           ? " \u00b7 not imported (not photos or videos): " + Object.keys(takeoutTool.rep.unsupported).map(k => takeoutTool.rep.unsupported[k] + " " + k).join(", ") : "")
                }
                Label {
                    visible: takeoutTool.finished && (dlg.takeout.reportFile || "") !== ""
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: dlg.theme.muted; font.pixelSize: 12
                    text: ((takeoutTool.rep.failuresTotal || 0) === 0 && !dlg.takeout.cancelled
                           && (takeoutTool.rep.skippedDeleted || 0) === 0 && Object.keys(takeoutTool.rep.unsupported || {}).length === 0
                           ? "Every photo of the export is in the library. " : "")
                        + "Full report: " + (dlg.takeout.reportFile || "")
                }
                Label {
                    visible: (dlg.takeout.error || "") !== ""
                    Layout.fillWidth: true; wrapMode: Text.WordWrap; color: "#e5484d"; font.pixelSize: 13
                    text: dlg.takeout.error || ""
                }
                Item { Layout.fillHeight: true }
            }
        }
    }
}
