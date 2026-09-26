import QtQuick
import QtQuick.Controls

// The photo grid: square thumbnails packed edge to edge with a 2 px gap, sized by the zoom
// slider. "all" is one continuous mosaic the way Google Photos lays it out (a big tile beside
// small ones; the rows are built and reconciled in D, library.rows), the day of the top row
// floating in a pill while it scrolls; "days" adds a header per day.
// Click selects, ⌘/Ctrl-click extends, double-click opens; hover shows the
// heart; keyboard arrows move the selection, Return opens.
Item {
    id: grid
    required property QtObject theme
    required property QtObject icons
    property var page: ({ total: 0, offset: 0, items: [] })
    property string mode: "all"          // "all" | "days"
    property int cellSize: 176
    property var selected: ({})          // id -> true
    property int cursor: -1              // index in page.items of the keyboard cursor
    readonly property bool hasMore: page.offset < page.total
    property bool requesting: false

    signal loadMore()
    signal open(int id)
    signal favorite(int id)
    signal selectionChanged()
    /// Right-click: the menu for the selection (the clicked photo joins it if it was outside).
    signal contextMenu(var ids, string path, bool favorite)
    /// Delete moves the selection to the trash; Shift+Delete asks and removes for good.
    signal remove(var ids, bool permanent)

    /// Mouse wheel: a notch moves about a row and a half of photos; a touchpad's
    /// pixel deltas are taken as they come, tripled.
    // (bounds from originY: items inserted above the viewport shift the content's origin)
    function wheel(view, ev) {
        const min = view.originY
        const max = view.originY + Math.max(0, view.contentHeight - view.height)
        const dy = ev.pixelDelta.y !== 0 ? ev.pixelDelta.y * 3 : ev.angleDelta.y / 120 * (grid.cell + grid.gap) * 1.5
        view.contentY = Math.max(min, Math.min(max, view.contentY - dy))
        ev.accepted = true
        if (view.contentY - view.originY > view.contentHeight - view.height * 3) grid.requestMore()
    }

    // The rows (every photo of the listing, laid out) are built and reconciled in D
    // (library.rows): a new page never throws a delegate away, the scroll stays.
    onPageChanged: {
        requesting = false
        syncModels()
        const c = closedOverStacks(selected)   // a page brought more of a selected stack
        if (c) { selected = c; selectionChanged() }
    }
    // Days: a header per day and a plain grid, every photo on its own; All Photos: the mosaic
    onModeChanged: { applyModel(); selectedChanged() }   // (re-close the selection over stacks)
    function applyModel() {
        library.setGridHeaders(mode === "days", 0)
        library.setGridMosaicMax(mode === "days" ? 0 : 8)
        library.setGridStacks(stacks && mode !== "days")
        library.setGridColumns(columns, 0)
    }

    // photo id → its index in the page (selection, cursor and range use page indexes)
    readonly property var indexOfId: {
        const m = {}
        const items = (page && page.items) ? page.items : []
        for (let i = 0; i < items.length; i++) m[items[i].id] = i
        return m
    }
    property var lastItems: []

    function syncModels() {
        const items = (page && page.items) ? page.items : []
        // the keyboard cursor and the range anchor follow their PHOTOS, not their positions
        const cid = cursor >= 0 && cursor < lastItems.length ? lastItems[cursor].id : null
        const aid = anchor >= 0 && anchor < lastItems.length ? lastItems[anchor].id : null
        lastItems = items
        // (from `items` itself: the indexOfId binding has not caught up with the page yet)
        const at = id => { for (let i = 0; i < items.length; i++) if (items[i].id === id) return i; return -1 }
        if (cid !== null) cursor = at(cid)
        if (aid !== null) anchor = at(aid)
    }

    readonly property int gap: 2
    // dragging the scroll bar through thousands of photos: only the quick decodes
    readonly property bool fast: allBar.pressed
    readonly property int columns: Math.max(1, Math.floor((width + gap) / (cellSize + gap)))
    readonly property int cell: Math.floor((width - (columns - 1) * gap) / columns)
    // the D row model follows this grid's columns; a mosaic up to 8 across (denser zooms plain)
    onColumnsChanged: library.setGridColumns(columns, 0)
    Component.onCompleted: applyModel()
    Connections {
        target: library
        function onRevealRowChanged() { if (library.revealRow >= 0) allView.positionViewAtIndex(library.revealRow, ListView.Contain) }
    }

    function requestMore() {
        if (requesting || !hasMore) return
        requesting = true
        loadMore()
    }

    // A stack's photos are selected together, however the selection was made (a click, the
    // arrows, a Shift range, Select All) and also when a later page brings more of a stack
    // in: the selection is always closed over the loaded stacks. (Off with stacks off.)
    property bool stacks: true
    property bool _closing: false
    function closedOverStacks(sel) {
        if (!stacks || mode !== "all") return null   // (Days shows every photo on its own)
        const byStack = {}
        for (const it of page.items) if (it.stack) (byStack[it.stack] = byStack[it.stack] || []).push(it.id)
        let out = null
        for (const k in byStack) {
            const ids = byStack[k]
            if (ids.some(id => sel[id]) && !ids.every(id => sel[id])) {
                out = out || Object.assign({}, sel)
                for (const id of ids) out[id] = true
            }
        }
        return out
    }
    onSelectedChanged: if (!_closing) { const c = closedOverStacks(selected); if (c) { _closing = true; selected = c; _closing = false } }
    onStacksChanged: { library.setGridStacks(stacks && mode !== "days"); selectedChanged() }

    function selectOnly(id) { selected = ({ [id]: true }); selectionChanged() }
    /// A stack's tile stands for all its photos: selecting it selects them all.
    function selectIds(ids) { const s = {}; for (const id of ids) s[id] = true; selected = s; selectionChanged() }
    // every loaded photo of the stacks these belong to (a stack a video splits in two tiles)
    function stackMates(ids) {
        if (!stacks || mode !== "all") return ids
        const st = {}
        for (const it of page.items) if (it.stack && ids.indexOf(it.id) >= 0) st[it.stack] = true
        const out = ids.slice()
        for (const it of page.items) if (it.stack && st[it.stack] && out.indexOf(it.id) < 0) out.push(it.id)
        return out
    }
    function toggleIds(ids) {
        ids = stackMates(ids)
        const s = Object.assign({}, selected)
        const on = !s[ids[0]]
        for (const id of ids) { if (on) s[id] = true; else delete s[id] }
        selected = s; selectionChanged()
    }
    function toggle(id) {
        const s = Object.assign({}, selected)
        if (s[id]) delete s[id]; else s[id] = true
        selected = s; selectionChanged()
    }
    function clearSelection() { selected = ({}); cursor = -1; selectionChanged() }
    /// Shift-click: everything from the last plain click (the anchor) to here, added to the selection.
    property int anchor: -1
    function selectRange(to) {
        const from = anchor < 0 ? to : anchor
        const s = Object.assign({}, selected)
        for (let i = Math.min(from, to); i <= Math.max(from, to); i++)
            if (i >= 0 && i < page.items.length) s[page.items[i].id] = true
        selected = s
        cursor = to
        selectionChanged()
    }
    function selectedIds() { return Object.keys(selected).map(Number) }
    /// how many photos are selected — reactive (menus/toolbar bind to it)
    readonly property int selectionCount: Object.keys(selected).length
    /// select every photo currently loaded in the page (Edit ▸ Select All)
    function selectAll() {
        const s = {}
        for (const it of page.items) s[it.id] = true
        selected = s
        selectionChanged()
    }

    function indexOf(id) {
        const it = page.items
        for (let i = 0; i < it.length; i++) if (it[i].id === id) return i
        return -1
    }
    function moveCursor(delta) {
        const it = page.items
        if (!it.length) return
        let i = cursor < 0 ? 0 : Math.max(0, Math.min(it.length - 1, cursor + delta))
        cursor = i
        selectOnly(it[i].id)
        library.revealPhoto(it[i].id)
    }

    property bool _navExtend: false
    function nav(dir, extend) {
        const it = page.items
        if (!it.length) return
        if (cursor < 0) { moveCursor(0); anchor = cursor; return }
        _navExtend = extend
        library.navigatePhoto(it[cursor].id, dir)
    }
    Connections {
        target: library
        function onNavTargetChanged() {
            const i = library.navTarget > 0 ? grid.indexOf(library.navTarget) : -1
            if (i < 0) return
            if (grid._navExtend) { if (grid.anchor < 0) grid.anchor = Math.max(0, grid.cursor); grid.selectRange(i) }
            else { grid.cursor = i; grid.selectOnly(library.navTarget); grid.anchor = i }
            library.revealPhoto(library.navTarget)
        }
    }
    Keys.onPressed: (event) => {
        const extend = event.modifiers & Qt.ShiftModifier
        const step = (d) => { if (extend) { if (anchor < 0) anchor = Math.max(0, cursor); selectRange(Math.max(0, Math.min(page.items.length - 1, (cursor < 0 ? 0 : cursor) + d))) } else { moveCursor(d); anchor = cursor } }
        const view = allView
        const minY = view.originY
        const maxY = view.originY + Math.max(0, view.contentHeight - view.height)
        switch (event.key) {
        case Qt.Key_Delete:   // Backspace deletes only on a Mac; here it is a text key
            if (selectedIds().length) remove(selectedIds(), (event.modifiers & Qt.ShiftModifier) !== 0); break
        case Qt.Key_Home: view.contentY = minY; if (page.items.length) { cursor = 0; selectOnly(page.items[0].id) } break
        case Qt.Key_End: view.contentY = maxY; if (page.items.length) { cursor = page.items.length - 1; selectOnly(page.items[cursor].id) } requestMore(); break
        case Qt.Key_PageDown: view.contentY = Math.min(maxY, view.contentY + view.height * 0.9); if (view.contentY - view.originY > view.contentHeight - view.height * 3) requestMore(); break
        case Qt.Key_PageUp: view.contentY = Math.max(minY, view.contentY - view.height * 0.9); break
        case Qt.Key_A: if (event.modifiers & Qt.ControlModifier) { anchor = 0; selectRange(page.items.length - 1); break } return
        // the arrows follow the tiles as laid out (the backend answers in navTarget)
        case Qt.Key_Left: nav(0, extend); break
        case Qt.Key_Right: nav(1, extend); break
        case Qt.Key_Up: nav(2, extend); break
        case Qt.Key_Down: nav(3, extend); break
        case Qt.Key_Return: case Qt.Key_Enter: case Qt.Key_Space:
            if (cursor >= 0 && cursor < page.items.length) grid.open(page.items[cursor].id); break
        case Qt.Key_Escape: clearSelection(); break
        default: return
        }
        event.accepted = true
    }

    // One thumbnail cell.
    component Cell: Item {
        id: cell
        required property var photo
        property int cw: 1   // its size in cells (a mosaic's big tile is 2×2)
        property int ch: 1
        property var members: []   // a stack: every photo it stands for (the cover first)
        readonly property var ids: members.length ? members : [photo.id]
        readonly property int cellIndex: grid.indexOfId[photo.id] !== undefined ? grid.indexOfId[photo.id] : -1
        width: cw * grid.cell + (cw - 1) * grid.gap
        height: ch * grid.cell + (ch - 1) * grid.gap
        readonly property bool isSelected: grid.selected[photo.id] === true
        Rectangle { anchors.fill: parent; color: theme.tile }
        // progressive: a 64 px decode first (the JPEG thumbnail decoded at 1/8, almost free),
        // then the sharp one on top — not while the scroll bar is being dragged through
        readonly property string url: cell.photo.thumbUrl || ""
        property bool sharp: false
        Component.onCompleted: sharp = !grid.fast
        onUrlChanged: sharp = !grid.fast
        Connections { target: grid; function onFastChanged() { if (!grid.fast) cell.sharp = true } }
        Image {
            anchors.fill: parent
            source: cell.url
            visible: status === Image.Ready && hi.status !== Image.Ready
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: 64; sourceSize.height: 64
            smooth: true
        }
        Image {
            id: hi
            anchors.fill: parent
            source: cell.sharp ? cell.url : ""
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: Math.min(1024, cell.width * 2)
            sourceSize.height: Math.min(1024, cell.height * 2)
            smooth: true
        }
        // video: a play glyph in the middle and the running time in the corner
        Rectangle {
            visible: cell.photo.video === true
            anchors.centerIn: parent
            width: 40; height: 40; radius: 20
            color: Qt.rgba(0, 0, 0, 0.45)
            Text { anchors.centerIn: parent; text: "▶"; color: "white"; font.pixelSize: 17 }
        }
        Rectangle {
            visible: cell.photo.video === true && cell.photo.duration > 0
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 5
            width: durLabel.implicitWidth + 10; height: 17; radius: 4
            color: Qt.rgba(0, 0, 0, 0.6)
            Label {
                id: durLabel
                anchors.centerIn: parent
                text: Math.floor(cell.photo.duration / 60000) + ":" + ("0" + Math.floor(cell.photo.duration / 1000) % 60).slice(-2)
                color: "white"; font.pixelSize: 10
            }
        }
        // a stack of near-identical photos: its count, top right (as Google Photos shows it)
        Rectangle {
            visible: cell.members.length > 1
            anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 6
            width: stackRow.implicitWidth + 12; height: 22; radius: 11
            color: Qt.rgba(0, 0, 0, 0.55)
            Row {
                id: stackRow
                anchors.centerIn: parent
                spacing: 5
                Item {   // two offset squares: "a stack"
                    width: 12; height: 12
                    anchors.verticalCenter: parent.verticalCenter
                    Rectangle { x: 3; y: 0; width: 9; height: 9; radius: 1.5; color: "transparent"; border.color: "white"; border.width: 1.2 }
                    Rectangle { x: 0; y: 3; width: 9; height: 9; radius: 1.5; color: Qt.rgba(0, 0, 0, 0.55); border.color: "white"; border.width: 1.2 }
                }
                Label { text: cell.members.length; color: "white"; font.pixelSize: 11; font.bold: true }
            }
            ToolTip.visible: stackHover.hovered
            ToolTip.text: cell.members.length + " similar photos — open to see them all"
            HoverHandler { id: stackHover }
        }
        // selection: white inner line + accent ring, check badge
        Rectangle {
            anchors.fill: parent
            visible: cell.isSelected
            color: "transparent"
            border.color: theme.accent
            border.width: 3
        }
        Rectangle {
            visible: cell.isSelected
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.margins: 6
            width: 20; height: 20; radius: 10
            color: theme.accent
            border.color: "white"; border.width: 1.5
            Image { anchors.centerIn: parent; source: icons.tint(icons.check, "white"); sourceSize.width: 12; sourceSize.height: 12 }
        }
        // the classifiers' word, top left, while hovering
        Row {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.margins: 6
            spacing: 4
            visible: cellHover.hovered && grid.cell >= 120
            Repeater {
                model: [cell.photo.scene, cell.photo.holiday, cell.photo.weather].filter(t => t)
                Rectangle {
                    required property string modelData
                    height: 18
                    width: badgeLabel.implicitWidth + 12
                    radius: 9
                    color: Qt.rgba(0, 0, 0, 0.55)
                    Label { id: badgeLabel; anchors.centerIn: parent; text: modelData; color: "white"; font.pixelSize: 10 }
                }
            }
        }
        // favorite heart (shown on hover, or always when set)
        Image {
            anchors.left: parent.left
            anchors.bottom: parent.bottom
            anchors.margins: 6
            visible: cellHover.hovered || cell.photo.favorite
            source: icons.tint(cell.photo.favorite ? icons.heartFill : icons.heart, "white")
            sourceSize.width: 16; sourceSize.height: 16
            opacity: cellHover.hovered || cell.photo.favorite ? 1 : 0
            TapHandler { onTapped: grid.favorite(cell.photo.id) }
        }
        Rectangle { // subtle hover veil
            anchors.fill: parent
            color: "white"
            opacity: cellHover.hovered && !cell.isSelected ? 0.06 : 0
        }
        HoverHandler { id: cellHover }
        TapHandler {
            acceptedModifiers: Qt.NoModifier
            onTapped: { grid.cursor = cell.cellIndex; grid.anchor = cell.cellIndex; grid.selectIds(cell.ids); grid.forceActiveFocus() }
            onDoubleTapped: grid.open(cell.photo.id)
        }
        TapHandler {
            acceptedModifiers: Qt.ControlModifier
            onTapped: { grid.cursor = cell.cellIndex; grid.anchor = cell.cellIndex; grid.toggleIds(cell.ids); grid.forceActiveFocus() }
        }
        TapHandler {
            acceptedModifiers: Qt.ShiftModifier
            onTapped: { grid.selectRange(cell.cellIndex); grid.forceActiveFocus() }
        }
        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: {
                if (!cell.isSelected) { grid.cursor = cell.cellIndex; grid.selectIds(cell.ids) }
                grid.forceActiveFocus()
                grid.contextMenu(grid.selectedIds(), cell.photo.path || "", cell.photo.favorite === true)
            }
        }
    }

    // ---- "all": the mosaic, one band of rows per model row -------------------------------
    ListView {
        id: allView
        anchors.fill: parent
        clip: true
        model: library.rows
        reuseItems: true
        cacheBuffer: Math.max(0, (grid.cell + grid.gap) * 6)
        ScrollBar.vertical: ScrollBar { id: allBar }
        delegate: Item {
            id: band
            required property string kind    // "h" a day header (Days), "r" a band of tiles
            required property string tiles   // JSON: the row's photos with their x, y, w, h (cells); a header: {count}
            required property string label
            required property int span
            readonly property var tileList: kind === "r" ? JSON.parse(tiles) : []
            readonly property int count: kind === "h" ? (JSON.parse(tiles).count || 0) : 0
            width: allView.width
            height: kind === "h" ? 44 : span * (grid.cell + grid.gap)
            // ---- a day header (Days)
            Label {
                visible: band.kind === "h"
                anchors.left: parent.left; anchors.leftMargin: 12
                anchors.bottom: parent.bottom; anchors.bottomMargin: 8
                text: band.kind === "h" ? band.label : ""
                color: theme.text
                font.pixelSize: 15; font.bold: true
            }
            Label {
                visible: band.kind === "h"
                anchors.right: parent.right; anchors.rightMargin: 12
                anchors.bottom: parent.bottom; anchors.bottomMargin: 9
                text: band.count + (band.count === 1 ? " photo" : " photos")
                color: theme.muted
                font.pixelSize: 12
            }
            Repeater {
                model: band.tileList
                delegate: Cell {
                    required property var modelData
                    // everything the cell draws comes with the tile (the D row model)
                    photo: ({ id: modelData.pid, thumbUrl: modelData.thumbUrl, video: modelData.video === true,
                              duration: modelData.duration || 0, favorite: modelData.favorite === true,
                              scene: modelData.scene, holiday: modelData.holiday, weather: modelData.weather,
                              path: modelData.path })
                    cw: modelData.w || 1
                    ch: modelData.h || 1
                    members: modelData.members || []
                    x: (modelData.x || 0) * (grid.cell + grid.gap)
                    y: (modelData.y || 0) * (grid.cell + grid.gap)
                }
            }
        }
        onAtYEndChanged: if (atYEnd && count > 0) grid.requestMore()
        onContentYChanged: {
            if (count > 0 && contentY - originY > contentHeight - height * 3) grid.requestMore()
            const it = itemAtIndex(indexAt(8, contentY + 8))
            if (it && it.label) grid.topDay = it.label
        }
        onMovingChanged: if (moving) { grid.pillShown = true; pillHide.stop() } else pillHide.restart()
        footer: Item { width: 1; height: 24 }
        WheelHandler { acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad; onWheel: (ev) => { grid.wheel(allView, ev); grid.pillShown = true; pillHide.restart() } }
    }

    // the day of the top row, floating while the mosaic scrolls
    property string topDay: ""
    property bool pillShown: false
    Timer { id: pillHide; interval: 1200; onTriggered: grid.pillShown = false }
    Rectangle {
        anchors.top: parent.top; anchors.topMargin: 12
        anchors.horizontalCenter: parent.horizontalCenter
        visible: grid.mode === "all" && opacity > 0.01 && grid.topDay.length > 0   // (Days has its headers)
        opacity: grid.pillShown ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 220 } }
        height: 34; radius: 17
        width: pillText.implicitWidth + 30
        color: Qt.rgba(theme.window.r, theme.window.g, theme.window.b, 0.92)
        border.color: theme.separator
        Label {
            id: pillText
            anchors.centerIn: parent
            text: grid.topDay
            color: theme.text
            font.pixelSize: 14; font.weight: Font.DemiBold
        }
    }

    Label {
        anchors.centerIn: parent
        visible: grid.page.items.length === 0
        text: grid.page.total === 0 ? "No Photos" : "Loading…"
        color: theme.muted
        font.pixelSize: 22
        font.bold: true
    }
}
