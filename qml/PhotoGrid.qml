import QtQuick
import QtQuick.Controls

// The photo grid: square thumbnails packed with a 2 px gap, sized by the zoom
// slider. "all" is one continuous grid; "days" adds a header per day.
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

    // A new page never replaces the views' models: it is RECONCILED into them — a photo
    // whose data changed (a thumbnail arrived, a heart, a tag) is updated in place, new
    // ones are inserted where they belong, gone ones removed. Replacing the model threw
    // every delegate away on each refresh (every 3 s while indexing or syncing): the
    // thumbnails decoded again and the scroll jumped. Keys are photo ids (sections: days).
    onPageChanged: {
        requesting = false
        syncModels()
    }
    onModeChanged: syncModels()

    ListModel { id: allModel; dynamicRoles: true }
    ListModel { id: daysModel; dynamicRoles: true }

    // Keyed reconcile: in place when the signature changed, MOVED when it sits later in
    // the model (its delegate survives), inserted when new, removed when gone.
    function reconcile(model, next) {
        const keys = new Set()
        for (const e of next) keys.add(e._k)
        let i = 0
        while (i < next.length) {
            const e = next[i]
            if (i < model.count) {
                const cur = model.get(i)
                if (cur._k === e._k) {
                    if (cur._s !== e._s) model.set(i, e)
                    i++
                    continue
                }
                if (!keys.has(cur._k)) { model.remove(i); continue }   // gone
                let j = i + 1
                while (j < model.count && model.get(j)._k !== e._k) j++
                if (j < model.count) {   // further down: move it up, keeping its delegate
                    model.move(j, i, 1)
                    if (model.get(i)._s !== e._s) model.set(i, e)
                    i++
                    continue
                }
            }
            model.insert(i, e)   // new
            i++
        }
        if (model.count > next.length) model.remove(next.length, model.count - next.length)
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
        if (mode === "days") {
            reconcile(daysModel, daysOf(items).map(d => {
                const js = JSON.stringify(d.items)
                return { _k: d.key, _s: d.title + js, title: d.title, n: d.items.length, itemsJson: js }
            }))
            if (allModel.count) allModel.clear()
        } else {
            reconcile(allModel, items.map(it => ({ _k: String(it.id), _s: JSON.stringify(it), photo: it })))
            if (daysModel.count) daysModel.clear()
        }
        lastItems = items
        // (from `items` itself: the indexOfId binding has not caught up with the page yet)
        const at = id => { for (let i = 0; i < items.length; i++) if (items[i].id === id) return i; return -1 }
        if (cid !== null) cursor = at(cid)
        if (aid !== null) anchor = at(aid)
    }

    readonly property int gap: 2
    readonly property int columns: Math.max(1, Math.floor((width - 16) / (cellSize + gap)))
    readonly property int cell: Math.floor((width - 16 - (columns - 1) * gap) / columns)

    function requestMore() {
        if (requesting || !hasMore) return
        requesting = true
        loadMore()
    }

    function selectOnly(id) { selected = ({ [id]: true }); selectionChanged() }
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
        if (mode === "all") allView.positionViewAtIndex(i, GridView.Contain)
    }

    Keys.onPressed: (event) => {
        const extend = event.modifiers & Qt.ShiftModifier
        const step = (d) => { if (extend) { if (anchor < 0) anchor = Math.max(0, cursor); selectRange(Math.max(0, Math.min(page.items.length - 1, (cursor < 0 ? 0 : cursor) + d))) } else { moveCursor(d); anchor = cursor } }
        const view = mode === "days" ? daysView : allView
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
        case Qt.Key_Left: step(-1); break
        case Qt.Key_Right: step(1); break
        case Qt.Key_Up: step(-columns); break
        case Qt.Key_Down: step(columns); break
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
        readonly property int cellIndex: grid.indexOfId[photo.id] !== undefined ? grid.indexOfId[photo.id] : -1
        width: grid.cell
        height: grid.cell
        readonly property bool isSelected: grid.selected[photo.id] === true
        Rectangle { anchors.fill: parent; color: theme.tile }
        Image {
            anchors.fill: parent
            source: cell.photo.thumbUrl || ""
            asynchronous: true
            cache: true
            fillMode: Image.PreserveAspectCrop
            sourceSize.width: Math.min(512, grid.cell * 2)
            sourceSize.height: Math.min(512, grid.cell * 2)
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
            onTapped: { grid.cursor = cell.cellIndex; grid.anchor = cell.cellIndex; grid.selectOnly(cell.photo.id); grid.forceActiveFocus() }
            onDoubleTapped: grid.open(cell.photo.id)
        }
        TapHandler {
            acceptedModifiers: Qt.ControlModifier
            onTapped: { grid.cursor = cell.cellIndex; grid.anchor = cell.cellIndex; grid.toggle(cell.photo.id); grid.forceActiveFocus() }
        }
        TapHandler {
            acceptedModifiers: Qt.ShiftModifier
            onTapped: { grid.selectRange(cell.cellIndex); grid.forceActiveFocus() }
        }
        TapHandler {
            acceptedButtons: Qt.RightButton
            onTapped: {
                if (!cell.isSelected) { grid.cursor = cell.cellIndex; grid.selectOnly(cell.photo.id) }
                grid.forceActiveFocus()
                grid.contextMenu(grid.selectedIds(), cell.photo.path || "", cell.photo.favorite === true)
            }
        }
    }

    // ---- "all": one GridView -------------------------------------------------------
    GridView {
        id: allView
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.leftMargin: 8
        anchors.topMargin: 8
        width: grid.columns * (grid.cell + grid.gap)   // exact multiple: no column lost to rounding
        visible: grid.mode === "all"
        clip: true
        cellWidth: grid.cell + grid.gap
        cellHeight: grid.cell + grid.gap
        model: allModel
        cacheBuffer: cellHeight * 6
        ScrollBar.vertical: ScrollBar { }
        delegate: Cell { }
        onAtYEndChanged: if (atYEnd && count > 0) grid.requestMore()
        onContentYChanged: if (count > 0 && contentY - originY > contentHeight - height * 3) grid.requestMore()
        footer: Item { width: 1; height: 24 }
        WheelHandler { acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad; onWheel: (ev) => grid.wheel(allView, ev) }
    }

    // ---- "days": sections with a date header ---------------------------------------
    function daysOf(items) {
        const out = []
        let cur = null
        for (let i = 0; i < items.length; i++) {
            const it = items[i]
            const d = new Date(it.takenAt)
            const key = isNaN(d.getTime()) ? "" : d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate()
            if (!cur || cur.key !== key) {
                cur = { key: key, title: grid.dayTitle(d), items: [] }
                out.push(cur)
            }
            cur.items.push(it)
        }
        return out
    }

    function dayTitle(d) {
        if (isNaN(d.getTime())) return "Unknown date"
        const now = new Date()
        const sameDay = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
        if (sameDay(d, now)) return "Today"
        const y = new Date(now); y.setDate(now.getDate() - 1)
        if (sameDay(d, y)) return "Yesterday"
        return d.toLocaleDateString(Qt.locale(), d.getFullYear() === now.getFullYear() ? "dddd, d MMMM" : "d MMMM yyyy")
    }

    ListView {
        id: daysView
        anchors.fill: parent
        anchors.leftMargin: 8
        anchors.rightMargin: 8
        visible: grid.mode === "days"
        clip: true
        model: daysModel
        spacing: 0
        cacheBuffer: 2000
        ScrollBar.vertical: ScrollBar { }
        delegate: Column {
            id: section
            required property string title
            required property int n
            required property string itemsJson
            width: daysView.width
            Item {
                width: parent.width
                height: 44
                Label {
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 8
                    text: section.title
                    color: theme.text
                    font.pixelSize: 15
                    font.bold: true
                }
                Label {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 9
                    text: section.n + (section.n === 1 ? " photo" : " photos")
                    color: theme.muted
                    font.pixelSize: 12
                }
            }
            Flow {
                width: parent.width
                spacing: grid.gap
                Repeater {
                    model: JSON.parse(section.itemsJson)
                    delegate: Cell { required property var modelData; photo: modelData }
                }
            }
            Item { width: 1; height: 12 }
        }
        onAtYEndChanged: if (atYEnd && count > 0) grid.requestMore()
        onContentYChanged: if (count > 0 && contentY - originY > contentHeight - height * 3) grid.requestMore()
        footer: Item { width: 1; height: 24 }
        WheelHandler { acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad; onWheel: (ev) => grid.wheel(daysView, ev) }
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
