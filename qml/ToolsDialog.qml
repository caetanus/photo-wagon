import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Tools — clean-up work over the whole library, each one a quick question instead of a hunt
// photo by photo: small copies of photos (a USB import's thumbnail cache), groups of
// near-identical photos, and faces nobody has named yet. Same look as Settings: sections on
// the left, the tool on the right. Deleting goes to the system trash (photo.delete).
Dialog {
    id: dlg
    required property QtObject theme
    required property QtObject icons
    property int section: 0               // 0 Thumbnails · 1 Similar photos · 2 Unnamed faces

    function openAt(s) { section = s; open() }

    readonly property var similar: { try { return JSON.parse(library.toolsSimilar) } catch (e) { return ({}) } }
    readonly property var thumbs: { try { return JSON.parse(library.toolsThumbs) } catch (e) { return ({}) } }
    readonly property var face: { try { return JSON.parse(library.toolsFace) } catch (e) { return ({}) } }

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
    }

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
                                || (dlg.section !== 2 && dlg.similar.running === undefined))
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
        }
    }
}
