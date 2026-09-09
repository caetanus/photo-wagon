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

    onPageChanged: requesting = false
    Rectangle { anchors.fill: parent; color: theme.content }

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
    function selectedIds() { return Object.keys(selected).map(Number) }

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
        switch (event.key) {
        case Qt.Key_Left: moveCursor(-1); break
        case Qt.Key_Right: moveCursor(1); break
        case Qt.Key_Up: moveCursor(-columns); break
        case Qt.Key_Down: moveCursor(columns); break
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
        property int cellIndex: -1
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
            onTapped: { grid.cursor = cell.cellIndex; grid.selectOnly(cell.photo.id); grid.forceActiveFocus() }
            onDoubleTapped: grid.open(cell.photo.id)
        }
        TapHandler {
            acceptedModifiers: Qt.ControlModifier
            onTapped: { grid.cursor = cell.cellIndex; grid.toggle(cell.photo.id); grid.forceActiveFocus() }
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
        model: grid.page.items
        cacheBuffer: cellHeight * 6
        ScrollBar.vertical: ScrollBar { }
        delegate: Cell { required property var modelData; required property int index; photo: modelData; cellIndex: index }
        onAtYEndChanged: if (atYEnd && count > 0) grid.requestMore()
        footer: Item { width: 1; height: 24 }
    }

    // ---- "days": sections with a date header ---------------------------------------
    readonly property var days: {
        if (mode !== "days") return []
        const out = []
        let cur = null
        for (let i = 0; i < page.items.length; i++) {
            const it = page.items[i]
            const d = new Date(it.takenAt)
            const key = isNaN(d.getTime()) ? "" : d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate()
            if (!cur || cur.key !== key) {
                cur = { key: key, title: grid.dayTitle(d), items: [] }
                out.push(cur)
            }
            cur.items.push(Object.assign({ _index: i }, it))
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
        model: grid.days
        spacing: 0
        cacheBuffer: 2000
        ScrollBar.vertical: ScrollBar { }
        delegate: Column {
            id: section
            required property var modelData
            width: daysView.width
            Item {
                width: parent.width
                height: 44
                Label {
                    anchors.left: parent.left
                    anchors.leftMargin: 4
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 8
                    text: section.modelData.title
                    color: theme.text
                    font.pixelSize: 15
                    font.bold: true
                }
                Label {
                    anchors.right: parent.right
                    anchors.rightMargin: 12
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 9
                    text: section.modelData.items.length + (section.modelData.items.length === 1 ? " photo" : " photos")
                    color: theme.muted
                    font.pixelSize: 12
                }
            }
            Flow {
                width: parent.width
                spacing: grid.gap
                Repeater {
                    model: section.modelData.items
                    delegate: Cell { required property var modelData; photo: modelData; cellIndex: modelData._index }
                }
            }
            Item { width: 1; height: 12 }
        }
        onAtYEndChanged: if (atYEnd && count > 0) grid.requestMore()
        footer: Item { width: 1; height: 24 }
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
