import QtQuick
import QtQuick.Controls

// Thumbnail grid over one accumulated page. `page` is the parsed library.page
// object: {total, offset, items}. Asks for more when the viewport nears the end.
//
// The grid is driven by a ListModel that is RECONCILED against each new page,
// never replaced. Binding GridView.model straight to `page.items` rebuilt every
// delegate — and re-decoded every thumbnail — each time the library published a
// page, which during a scan is every few seconds ("atualizar a biblioteca
// re-renderiza os models, deixa o app instável"). Here an unchanged prefix keeps
// its delegates: only new rows are appended, a flipped `sent` is patched in
// place, and the tail is rebuilt only from the first row that actually differs.
Item {
    id: grid
    required property QtObject theme
    property var page: ({ total: 0, offset: 0, items: [] })
    readonly property bool hasMore: page.offset < page.total
    property bool requesting: false
    // the "already on the computer" check mark, built once and shared by every cell
    readonly property string checkIcon: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>')

    signal loadMore()
    signal open(int id)

    onPageChanged: { requesting = false; syncModel() }

    // Reconcile `model` with page.items, touching as few rows as possible.
    function syncModel() {
        const items = (page && page.items) ? page.items : []
        const m = items.length
        let i = 0
        // shared prefix: same id in the same slot — keep the delegate, patch `sent`
        while (i < model.count && i < m && model.get(i).pid === items[i].id) {
            if (model.get(i).sent !== (items[i].sent === true))
                model.setProperty(i, "sent", items[i].sent === true)
            i++
        }
        // drop whatever no longer matches from the first divergence on
        while (model.count > i)
            model.remove(model.count - 1)
        // append the rest (new photos, or the rebuilt tail)
        for (; i < m; i++)
            model.append({ pid: items[i].id,
                           thumbUrl: items[i].thumbUrl || "",
                           sent: items[i].sent === true,
                           video: items[i].video === true,
                           duration: items[i].duration || 0 })
    }

    ListModel { id: model }

    Rectangle { anchors.fill: parent; color: theme.bg }

    GridView {
        id: view
        anchors.fill: parent
        anchors.margins: 2
        clip: true
        // three across on a phone, more on a tablet; square cells
        cellWidth: Math.floor(width / Math.max(3, Math.floor(width / 150)))
        cellHeight: cellWidth
        model: model
        // Flyweight: keep in memory only what is on screen plus one screenful of buffer
        // above and below ("as visíveis mais 100% de view em offscreen"). GridView only
        // instantiates delegates within cacheBuffer of the viewport, so bounding it to the
        // view's own height caps how many thumbnails are decoded at once — on a 4000-photo
        // library the rest cost nothing until they scroll near.
        cacheBuffer: Math.max(0, Math.round(height))

        ScrollBar.vertical: ScrollBar { }

        delegate: Item {
            id: cell
            required property int pid
            required property string thumbUrl
            required property bool sent
            required property bool video
            required property int duration
            width: view.cellWidth
            height: view.cellHeight
            // A plain (un-clipped, un-rounded) background so a loading cell is not jarring.
            // No rounded corners and NO clip here on purpose: clip:true forces each cell into
            // its own draw call, which breaks Qt Quick's batching of the thumbnails and is the
            // main thing that made the grid scroll like glue. Square thumbnails, like most
            // photo apps, let the whole grid draw in a few batches.
            Rectangle {
                anchors.fill: parent
                anchors.margins: 1.5
                color: theme.panelAlt
            }
            Image {
                anchors.fill: parent
                anchors.margins: 1.5
                source: cell.thumbUrl
                asynchronous: true
                cache: true
                // PreserveAspectCrop already crops within the item's own bounds — no clip needed.
                // Decode near the on-screen size (~360 px on a 1080-wide 3-across grid), not 512.
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 384
                sourceSize.height: 384
                smooth: true
            }
            // video: a play glyph (the frame thumbnail arrives once the computer has it)
            Rectangle {
                visible: cell.video
                anchors.centerIn: parent
                width: 34; height: 34; radius: 17
                color: Qt.rgba(0, 0, 0, 0.42)
                Text { anchors.centerIn: parent; text: "▶"; color: "white"; font.pixelSize: 15 }
            }
            Rectangle {
                visible: cell.video && cell.duration > 0
                anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 6
                width: vdur.implicitWidth + 8; height: 15; radius: 3
                color: Qt.rgba(0, 0, 0, 0.6)
                Text {
                    id: vdur
                    anchors.centerIn: parent
                    text: Math.floor(cell.duration / 60000) + ":" + ("0" + Math.floor(cell.duration / 1000) % 60).slice(-2)
                    color: "white"; font.pixelSize: 9
                }
            }
            // already on the computer: a small check in the corner
            Rectangle {
                visible: cell.sent
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: 6.5
                width: 18; height: 18; radius: 9
                color: Qt.rgba(0, 0, 0, 0.45)
                Image {
                    anchors.centerIn: parent
                    source: grid.checkIcon   // one shared, pre-built data URL, not rebuilt per cell
                    sourceSize.width: 11; sourceSize.height: 11
                }
            }
            TapHandler { onTapped: grid.open(cell.pid) }
        }

        footer: Item {
            width: view.width
            height: grid.hasMore ? 56 : 24
            Button {
                anchors.centerIn: parent
                visible: grid.hasMore
                text: grid.requesting ? "Loading…" : "Load more (" + (grid.page.total - grid.page.offset) + " left)"
                enabled: !grid.requesting
                onClicked: grid.requestMore()
            }
        }

        onAtYEndChanged: if (atYEnd && grid.hasMore && count > 0) grid.requestMore()
    }

    Label {
        anchors.centerIn: parent
        visible: view.count === 0
        text: grid.page.total === 0 ? "No photos yet — allow access to your photos, or wait for the scan." : "Loading…"
        color: theme.muted
        font.pixelSize: 15
    }

    function requestMore() {
        if (requesting || !hasMore) return
        requesting = true
        loadMore()
    }
}
