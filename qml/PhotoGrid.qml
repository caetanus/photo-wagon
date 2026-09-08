import QtQuick
import QtQuick.Controls

// Thumbnail grid over one accumulated page. `page` is the parsed library.page
// object: {total, offset, items}. Asks for more when the viewport nears the end.
Item {
    id: grid
    required property QtObject theme
    property var page: ({ total: 0, offset: 0, items: [] })
    readonly property bool hasMore: page.offset < page.total
    property bool requesting: false

    signal loadMore()
    signal open(int id)

    onPageChanged: requesting = false

    Rectangle { anchors.fill: parent; color: theme.bg }

    GridView {
        id: view
        anchors.fill: parent
        anchors.margins: 8
        clip: true
        cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 184)))
        cellHeight: cellWidth
        model: grid.page.items
        cacheBuffer: cellHeight * 4

        ScrollBar.vertical: ScrollBar { }

        delegate: Item {
            width: view.cellWidth
            height: view.cellHeight
            Rectangle {
                anchors.fill: parent
                anchors.margins: 4
                color: theme.panel
                radius: 4
                clip: true
                Image {
                    anchors.fill: parent
                    source: modelData.thumbUrl
                    asynchronous: true
                    cache: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 360
                    sourceSize.height: 360
                    smooth: true
                }
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.color: hover.hovered ? theme.accent : "transparent"
                    border.width: 2
                    radius: 4
                }
                HoverHandler { id: hover }
                TapHandler { onTapped: grid.open(modelData.id) }
            }
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
        text: grid.page.total === 0 ? "No photos yet. Use “Add folder” to index a directory." : "Loading…"
        color: theme.muted
        font.pixelSize: 15
    }

    function requestMore() {
        if (requesting || !hasMore) return
        requesting = true
        loadMore()
    }
}
