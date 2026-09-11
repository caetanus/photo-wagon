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
        anchors.margins: 2
        clip: true
        // three across on a phone, more on a tablet; square cells
        cellWidth: Math.floor(width / Math.max(3, Math.floor(width / 150)))
        cellHeight: cellWidth
        model: grid.page.items
        cacheBuffer: cellHeight * 4

        ScrollBar.vertical: ScrollBar { }

        delegate: Item {
            width: view.cellWidth
            height: view.cellHeight
            Rectangle {
                anchors.fill: parent
                anchors.margins: 1.5
                color: theme.panelAlt
                radius: 3
                clip: true
                Image {
                    anchors.fill: parent
                    source: modelData.thumbUrl
                    asynchronous: true
                    cache: true
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 300
                    sourceSize.height: 300
                    smooth: true
                }
                // already on the computer: a small check in the corner
                Rectangle {
                    visible: modelData.sent === true
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.margins: 5
                    width: 18; height: 18; radius: 9
                    color: Qt.rgba(0, 0, 0, 0.45)
                    Image {
                        anchors.centerIn: parent
                        source: "data:image/svg+xml;utf8," + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="#ffffff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M5 12.5l4.5 4.5L19 7.5"/></svg>')
                        sourceSize.width: 11; sourceSize.height: 11
                    }
                }
                Rectangle {
                    anchors.fill: parent
                    color: "transparent"
                    border.color: hover.hovered ? theme.accent : "transparent"
                    border.width: 2
                    radius: 3
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
