import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material

// A date-grouped photo timeline, the way Google Photos / Apple Photos read: photos
// under a per-day header ("Today", "Sat, Sep 20"), square tiles edge to edge, one
// seamless scroll. `page` is the parsed library.page {total, offset, items}; every
// item already carries `takenTs` (the merge that builds the page sorts on it), so the
// grouping is done here with no backend change.
//
// PERFORMANCE (kept from the flat GridView it replaces): the ListView holds ROWS —
// a header row, or a row of up to `cols` tiles — so it virtualises and RECYCLES row
// delegates (reuseItems), and only the rows within a screenful are ever built. The
// `rows` model is RECONCILED against each new page, never rebuilt: appended photos
// keep every earlier row's delegates (no thumbnail re-decode during a scan, which was
// the "atualizar a biblioteca deixa o app instável" bug), and a thumbnail that streams
// in late patches only its own row's tiles in place.
Item {
    id: grid
    required property QtObject theme
    property bool ready: true   // the core (and so the listing) is up
    Icons { id: icons }
    // what an empty listing means (a search that found nothing is not "no photos yet")
    property string emptyText: "No photos yet — allow access to your photos, or wait for the scan."
    property var page: ({ total: 0, offset: 0, items: [] })
    readonly property bool hasMore: page.offset < page.total
    property bool requesting: false
    // fast-scroll date scrubber state
    property bool scrubbing: false
    property bool _scrubActive: false
    property string scrubText: ""

    // three across on a phone, more on a tablet; square cells, flush to the edges.
    // Pinch sets `density` (columns); 0 = the width-based default.
    readonly property int gap: 2
    property int density: 0
    readonly property int cols: density > 0 ? Math.max(2, Math.min(6, density)) : Math.max(3, Math.floor(width / 150))
    readonly property real cellSize: (width - (cols - 1) * gap) / cols

    // Pinch to change grid density, keeping the asset under the fingers in view (the
    // Apple/Google "pinch the wall of photos" gesture). Rebuilds only when the column
    // count actually crosses a threshold, so a pinch is a couple of re-chunks, not churn.
    function setDensity(d) {
        d = Math.max(2, Math.min(6, d))
        if (d === grid.cols) return
        const idx = view.indexAt(4, view.contentY + 6)
        let anchorPid = -1
        if (idx >= 0) { const r = rows.get(idx); if (r && r.tiles && r.tiles.length) anchorPid = r.tiles[0].pid }
        grid.density = d
        if (anchorPid >= 0) Qt.callLater(function () {
            for (let n = 0; n < rows.count; n++) {
                const rr = rows.get(n)
                if (rr.tiles) for (let m = 0; m < rr.tiles.length; m++)
                    if (rr.tiles[m].pid === anchorPid) { view.positionViewAtIndex(n, ListView.Beginning); return }
            }
        })
    }

    // built-once glyphs shared by every tile
    readonly property string checkIcon: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>')
    readonly property string playGlyph: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="#ffffff"><path d="M8 5v14l11-7z"/></svg>')

    signal loadMore()
    signal open(int id)

    // ---- selection: a long press starts it, taps then add / remove -------------------
    // `selected` maps id → what the tile knew of it ({id, remote, sent}), kept even when a
    // refresh moves the photo out of the loaded page; selVersion bumps on every change
    // (bindings cannot see a JS object's keys change).
    property var selected: ({})
    property int selVersion: 0
    property bool selectMode: false          // "Select" from the bar, before the first tap
    readonly property int selectedCount: { selVersion; return Object.keys(selected).length }
    readonly property bool selecting: selectMode || selectedCount > 0
    function isSelected(pid) { selVersion; return selected[pid] !== undefined }
    function toggleSelected(tile) {
        if (selected[tile.pid] !== undefined) delete selected[tile.pid]
        else selected[tile.pid] = { id: tile.pid, remote: tile.remote === true, sent: tile.sent === true }
        selVersion++
    }
    function clearSelection() { selected = ({}); selectMode = false; selVersion++ }
    function selectedIds() { return Object.keys(selected).map(k => Number(k)) }
    function selectedItems() { return Object.keys(selected).map(k => selected[k]) }

    onPageChanged: { requesting = false; syncRows() }
    onColsChanged: rebuildRows()   // a rotation / width change re-chunks the rows

    // ---- day grouping -----------------------------------------------------------
    // taken_ts is Unix SECONDS (the backend stores it with 'unixepoch'); JS Date wants
    // milliseconds, so ×1000 — without it every photo collapsed onto Jan 1970. 0 = undated.
    function dayKey(ts) { if (!ts) return "undated"; const d = new Date(ts * 1000); return d.getFullYear() + "-" + (d.getMonth() + 1) + "-" + d.getDate() }
    function dayLabel(ts) {
        if (!ts) return "Sem data"
        const d = new Date(ts * 1000), now = new Date()
        const today = new Date(now.getFullYear(), now.getMonth(), now.getDate())
        const that = new Date(d.getFullYear(), d.getMonth(), d.getDate())
        const diff = Math.round((today.getTime() - that.getTime()) / 86400000)
        if (diff === 0) return "Today"
        if (diff === 1) return "Yesterday"
        const wd = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"][d.getDay()]
        const mo = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"][d.getMonth()]
        const base = wd + ", " + mo + " " + d.getDate()
        return d.getFullYear() === now.getFullYear() ? base : base + " " + d.getFullYear()
    }

    // items -> [ {kind:"h",key,label}, {kind:"r",key,tiles:[…]} … ], chunked by `cols`
    function buildRows() {
        const items = (page && page.items) ? page.items : []
        const out = []
        let i = 0
        while (i < items.length) {
            const ts = items[i].takenTs || 0
            const key = dayKey(ts)
            out.push({ kind: "h", key: key, label: dayLabel(ts), tiles: [] })
            const day = []
            while (i < items.length && dayKey(items[i].takenTs || 0) === key) { day.push(items[i]); i++ }
            for (let j = 0; j < day.length; j += cols) {
                const tiles = []
                for (let k = j; k < Math.min(j + cols, day.length); k++) {
                    const it = day[k]
                    tiles.push({ pid: it.id, thumbUrl: it.thumbUrl || "", sent: it.sent === true, remote: it.remote === true,
                                 video: it.video === true, duration: it.duration || 0 })
                }
                out.push({ kind: "r", key: key + "#" + j, label: "", tiles: tiles })
            }
        }
        return out
    }

    function sameTiles(a, b) {
        if (!a || !b || a.length !== b.length) return false
        for (let n = 0; n < a.length; n++) if (a[n].pid !== b[n].pid) return false
        return true
    }
    function tilesContentDiffer(a, b) {
        for (let n = 0; n < a.length; n++)
            if (a[n].thumbUrl !== b[n].thumbUrl || a[n].sent !== b[n].sent) return true
        return false
    }

    // Reconcile `rows` with the freshly computed rows, touching as few as possible.
    function syncRows() {
        const nr = buildRows()
        let i = 0
        // shared prefix: same header/row structure stays; a row whose tiles only changed
        // thumbUrl/sent is patched in place (one row's ≤cols tiles re-decode, not the grid).
        while (i < rows.count && i < nr.length) {
            const cur = rows.get(i)
            if (cur.kind !== nr[i].kind || cur.key !== nr[i].key) break
            if (cur.kind === "r") {
                if (!sameTiles(cur.tiles, nr[i].tiles)) break
                if (tilesContentDiffer(cur.tiles, nr[i].tiles)) rows.setProperty(i, "tiles", nr[i].tiles)
            }
            i++
        }
        while (rows.count > i) rows.remove(rows.count - 1)
        for (; i < nr.length; i++) rows.append(nr[i])
    }
    function rebuildRows() { rows.clear(); syncRows() }

    ListModel { id: rows; dynamicRoles: true }

    Rectangle { anchors.fill: parent; color: theme.bg }

    ListView {
        id: view
        anchors.fill: parent
        clip: true
        model: rows
        reuseItems: true
        maximumFlickVelocity: 9000
        flickDeceleration: 1100
        // keep one screenful of rows above and below live; the rest cost nothing
        cacheBuffer: Math.max(0, Math.round(height))

        // pinch the wall of photos to change density (2–6 columns)
        PinchHandler {
            target: null
            property int baseCols: 3
            onActiveChanged: if (active) baseCols = grid.cols
            onScaleChanged: if (active) grid.setDensity(Math.round(baseCols / activeScale))
        }
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { }

        // one tile — square crop, video badge, duration, "on the computer" check
        component Tile: Item {
            id: cell
            required property var modelData
            width: grid.cellSize
            height: grid.cellSize
            Rectangle { anchors.fill: parent; color: theme.panelAlt }
            Image {
                anchors.fill: parent
                source: cell.modelData.thumbUrl
                // paint only once decoded — a still-loading, missing or corrupt thumbnail
                // (common while offline) otherwise flashed as GPU noise; the panelAlt
                // rectangle behind stays as a clean placeholder until then.
                visible: status === Image.Ready
                asynchronous: true; cache: true
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 384; sourceSize.height: 384
                smooth: true
            }
            Rectangle {
                visible: cell.modelData.video
                anchors.centerIn: parent
                width: 38; height: 38; radius: 19
                color: Qt.rgba(0, 0, 0, 0.42)
                border.width: 1.5; border.color: Qt.rgba(1, 1, 1, 0.85)
                Image {
                    anchors.centerIn: parent; anchors.horizontalCenterOffset: 1
                    source: grid.playGlyph; sourceSize.width: 17; sourceSize.height: 17
                }
            }
            Rectangle {
                visible: cell.modelData.video && cell.modelData.duration > 0
                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 6
                width: vdur.implicitWidth + 8; height: 15; radius: 3
                color: Qt.rgba(0, 0, 0, 0.6)
                Text {
                    id: vdur; anchors.centerIn: parent
                    text: Math.floor(cell.modelData.duration / 60000) + ":" + ("0" + Math.floor(cell.modelData.duration / 1000) % 60).slice(-2)
                    color: "white"; font.pixelSize: 9
                }
            }
            // "on the computer" is the quiet default for nearly every tile, so show it as a
            // small ambient dot, not a selection-style checkmark stamped on every photo.
            Rectangle {
                visible: cell.modelData.sent
                anchors.right: parent.right; anchors.bottom: parent.bottom; anchors.margins: 6
                width: 7; height: 7; radius: 3.5
                color: Qt.rgba(1, 1, 1, 0.9)
                border.color: Qt.rgba(0, 0, 0, 0.3); border.width: 1
            }
            // selection: the photo steps back a little, a check sits on its corner
            Rectangle {
                anchors.fill: parent
                visible: grid.isSelected(cell.modelData.pid)
                color: Qt.rgba(0, 0, 0, 0.28)
                border.color: theme.accent; border.width: 3
            }
            Rectangle {
                visible: grid.selecting
                anchors.left: parent.left; anchors.top: parent.top; anchors.margins: 6
                width: 22; height: 22; radius: 11
                readonly property bool on: grid.isSelected(cell.modelData.pid)
                color: on ? theme.accent : Qt.rgba(0, 0, 0, 0.25)
                border.color: "#ffffff"; border.width: 1.5
                Image {
                    visible: parent.on
                    anchors.centerIn: parent
                    source: icons.tint(icons.check, "#ffffff")
                    sourceSize.width: 14; sourceSize.height: 14
                }
            }
            TapHandler {
                onTapped: grid.selecting ? grid.toggleSelected(cell.modelData) : grid.open(cell.modelData.pid)
                onLongPressed: grid.toggleSelected(cell.modelData)
            }
        }

        // a row: a day header, or up to `cols` tiles
        delegate: Item {
            id: rowItem
            required property string kind
            required property string key
            required property var tiles
            required property string label
            width: view.width
            height: kind === "h" ? 46 : grid.cellSize + grid.gap

            // ---- day header
            Label {
                visible: rowItem.kind === "h"
                anchors.left: parent.left; anchors.bottom: parent.bottom
                anchors.leftMargin: 4; anchors.bottomMargin: 8
                text: rowItem.kind === "h" ? rowItem.label : ""
                color: theme.text
                font.pixelSize: 15; font.weight: Font.DemiBold; font.letterSpacing: -0.2
            }
            // ---- tile row
            Row {
                visible: rowItem.kind === "r"
                spacing: grid.gap
                Repeater {
                    model: rowItem.kind === "r" ? rowItem.tiles : 0
                    delegate: Tile { }
                }
            }
        }

        footer: Item {
            width: view.width
            height: grid.hasMore ? 44 : 16
            BusyIndicator {
                anchors.centerIn: parent
                running: grid.requesting && grid.hasMore
                visible: running
                implicitWidth: 26; implicitHeight: 26
                Material.accent: grid.theme.accent
            }
        }

        onContentYChanged: if (atYEnd && grid.hasMore && count > 0) grid.requestMore()
        onAtYEndChanged: if (atYEnd && grid.hasMore && count > 0) grid.requestMore()
    }

    Label {
        anchors.centerIn: parent
        visible: rows.count === 0
        // before the phone core has answered, "no photos" would be a lie
        text: !grid.ready ? "Loading your photos…"
            : grid.page.total === 0 ? grid.emptyText : "Loading…"
        color: theme.muted; font.pixelSize: 15
        width: parent.width - 48; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap
    }

    // ---- fast-scroll date scrubber (right edge, Google-Photos style) --------------
    Timer { id: scrubHide; interval: 1100; onTriggered: grid._scrubActive = false }
    Connections {
        target: view
        function onMovingChanged() {
            if (view.moving) { grid._scrubActive = true; scrubHide.stop() }
            else if (!grid.scrubbing) scrubHide.restart()
        }
        function onContentYChanged() {
            if (view.moving || grid.scrubbing) grid._scrubActive = true
            grid.scrubText = grid.computeScrubDate()
        }
    }
    // the month + year of the row at the top of the viewport
    function computeScrubDate() {
        const idx = view.indexAt(4, view.contentY + 6)
        if (idx < 0 || idx >= rows.count) return grid.scrubText
        const r = rows.get(idx)
        if (!r || !r.key) return grid.scrubText
        const keyPart = ("" + r.key).split("#")[0]
        if (keyPart === "undated") return "Sem data"
        const p = keyPart.split("-")
        const d = new Date(Number(p[0]), Number(p[1]) - 1, Number(p[2]))
        const mo = ["January", "February", "March", "April", "May", "June",
                    "July", "August", "September", "October", "November", "December"][d.getMonth()]
        return mo + " " + d.getFullYear()
    }

    Item {
        id: scrubber
        anchors.right: parent.right; anchors.top: parent.top; anchors.bottom: parent.bottom
        width: 44
        visible: opacity > 0.01
        enabled: view.contentHeight > view.height * 1.6
        opacity: (scrubber.enabled && (grid._scrubActive || grid.scrubbing)) ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 180 } }

        readonly property real trackTop: 10
        readonly property real trackH: height - 20
        readonly property real frac: view.visibleArea.heightRatio < 1
                                     ? view.visibleArea.yPosition / (1 - view.visibleArea.heightRatio) : 0

        // date bubble, left of the handle, while actually dragging
        Rectangle {
            visible: grid.scrubbing
            anchors.verticalCenter: handle.verticalCenter
            anchors.right: handle.left; anchors.rightMargin: 8
            height: 34; width: bubbleText.implicitWidth + 24; radius: 17
            color: grid.theme.accent
            Label {
                id: bubbleText; anchors.centerIn: parent
                text: grid.scrubText; color: grid.theme.accentText
                font.pixelSize: 14; font.weight: Font.DemiBold
            }
        }

        Rectangle {
            id: handle
            width: 34; height: 46; radius: 8
            x: scrubber.width - width - 5
            y: scrubber.trackTop + scrubber.frac * (scrubber.trackH - height)
            color: grid.scrubbing ? grid.theme.accent : grid.theme.panel
            border.color: grid.theme.accent; border.width: 1.5
            Column {
                anchors.centerIn: parent; spacing: 3
                Repeater {
                    model: 3
                    delegate: Rectangle { width: 12; height: 1.5; radius: 1; color: grid.scrubbing ? grid.theme.accentText : grid.theme.accent }
                }
            }
            // target:null → never moves the handle (it tracks the scroll via `frac`); it only
            // reads the finger and drives contentY, so there is no binding fight.
            DragHandler {
                target: null
                xAxis.enabled: false; yAxis.enabled: true
                onActiveChanged: { grid.scrubbing = active; if (!active) scrubHide.restart() }
                onCentroidChanged: if (active) {
                    const topScene = scrubber.mapToItem(null, 0, scrubber.trackTop).y
                    const f = Math.max(0, Math.min(1, (centroid.scenePosition.y - topScene) / (scrubber.trackH - handle.height)))
                    view.contentY = f * Math.max(1, view.contentHeight - view.height)
                }
            }
        }
    }

    function requestMore() {
        if (requesting || !hasMore) return
        requesting = true
        loadMore()
    }
}
