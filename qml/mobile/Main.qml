import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Phone layout: header, the grid, a drawer with the date tree, the viewer on
// top. Same backend payloads as the desktop Main.qml; thumbnails and photos
// arrive as data: URLs because the library is on another machine.
ApplicationWindow {
    id: root
    // Android's Back: close what is open (viewer, dialog, drawer) before the app.
    onClosing: (close) => {
        if (root.current !== null) { close.accepted = false; library.closePhoto() }
        else if (dates.opened) { close.accepted = false; dates.close() }
    }
    width: 412
    height: 915
    visible: true
    title: "Photo Wagon"
    color: theme.bg

    readonly property QtObject theme: QtObject {
        readonly property color bg: "#16181d"
        readonly property color panel: "#1e2128"
        readonly property color panelAlt: "#262a33"
        readonly property color border: "#31363f"
        readonly property color text: "#e6e8ec"
        readonly property color muted: "#8b93a3"
        readonly property color accent: "#5aa2ff"
    }

    palette {
        window: theme.bg
        windowText: theme.text
        base: theme.panel
        alternateBase: theme.panelAlt
        text: theme.text
        button: theme.panelAlt
        buttonText: theme.text
        highlight: theme.accent
        highlightedText: "#ffffff"
        placeholderText: theme.muted
        mid: theme.border
        dark: theme.border
        light: theme.panelAlt
    }

    readonly property var status: JSON.parse(library.status)
    readonly property var syncData: JSON.parse(library.sync)

    // UI-thread watchdog: a 250 ms timer that arrives late means the thread was busy.
    Timer {
        property double last: 0
        property int ticks: 0
        interval: 250; repeat: true; running: true
        onTriggered: {
            const now = Date.now()
            if (last > 0 && now - last > 700) console.log("ui stalled " + (now - last) + " ms")
            last = now
            if (++ticks % 40 === 0) console.log("ui alive #" + (ticks / 40) + ", page items " + root.pageData.items.length + " window " + root.width + "x" + root.height)
        }
    }
    readonly property var pageData: JSON.parse(library.page)
    readonly property var datesData: JSON.parse(library.dates)
    readonly property var current: library.current.length ? JSON.parse(library.current) : null
    readonly property var albumsData: JSON.parse(library.albums).albums
    readonly property var filterData: JSON.parse(library.filter)
    readonly property var peopleData: JSON.parse(library.people).people
    readonly property var facesData: JSON.parse(library.faces).faces

    property int filterYear: 0
    property int filterMonth: 0
    property int filterDay: 0
    readonly property int pageSize: 60

    function applyFilter(y, m, d) {
        filterYear = y; filterMonth = m; filterDay = d
        library.loadPage(0, pageSize, y, m, d)
        dates.close()
    }
    function albumName(id) {
        for (const a of albumsData) if (a.id === id) return a.name
        return "Album"
    }

    header: ToolBar {
        height: 52
        background: Rectangle { color: theme.panel; border.color: theme.border }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 4
            anchors.rightMargin: 4
            spacing: 4
            ToolButton {
                onClicked: dates.open()
                implicitWidth: 44
                // drawn, not a glyph: Android's default font has no U+2630
                contentItem: Column {
                    anchors.centerIn: parent
                    spacing: 4
                    Repeater {
                        model: 3
                        Rectangle { width: 20; height: 2; radius: 1; color: theme.text }
                    }
                }
            }
            ColumnLayout {
                spacing: 0
                Layout.fillWidth: true
                Label {
                    text: filterData.albumId ? albumName(filterData.albumId)
                        : filterYear === 0 ? "Photo Wagon"
                        : (filterDay ? filterYear + "-" + pad(filterMonth) + "-" + pad(filterDay)
                           : filterMonth ? filterYear + "-" + pad(filterMonth) : String(filterYear))
                    font.pixelSize: 17
                    font.bold: true
                    color: theme.text
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
                Label {
                    text: status.text + (library.endpoint.length
                        ? " · " + (library.computerConnected ? "computer: " + library.endpoint : "computer offline")
                        : " · no computer set")
                    color: theme.muted
                    font.pixelSize: 12
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }
            BusyIndicator {
                running: status.indexing
                visible: running
                implicitWidth: 22
                implicitHeight: 22
            }
            ToolButton {
                text: root.syncData.active ? "Sending…" : "Sync"
                enabled: library.computerConnected && !root.syncData.active
                onClicked: library.sendAll()
            }
            ToolButton { text: "⚙"; font.pixelSize: 22; onClicked: endpointDialog.open() }
        }
    }

    Item {
        id: shell
        anchors.fill: parent

        PhotoGrid {
            id: grid
            anchors.fill: parent
            theme: root.theme
            page: root.pageData
            onLoadMore: library.loadPage(root.pageData.offset, root.pageSize, root.filterYear, root.filterMonth, root.filterDay)
            onOpen: (id) => library.openPhoto(id)
        }

        PhotoFocusView {
            id: focusView
            anchors.fill: parent
            theme: root.theme
            photo: root.current
            visible: root.current !== null
            canSend: true
            facesOnHover: false
            sendEnabled: library.computerConnected
            faces: root.facesData
            people: root.peopleData
            onClosed: library.closePhoto()
            onSend: (id) => library.sendToComputer(id)
            onNameFace: (faceId, personId, name) => library.setFacePerson(faceId, personId, name)
        }
    }

    Drawer {
        id: dates
        width: Math.min(300, root.width * 0.8)
        height: root.height
        ColumnLayout {
            anchors.fill: parent
            spacing: 0
            DateTreeSidebar {
                Layout.fillWidth: true
                Layout.fillHeight: true
                theme: root.theme
                dates: root.datesData
                selectedYear: root.filterYear
                selectedMonth: root.filterMonth
                selectedDay: root.filterDay
                onPicked: (y, m, d) => root.applyFilter(y, m, d)
            }
            // the computer's albums (empty when no computer is paired)
            Rectangle {
                visible: root.albumsData.length > 0
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(260, 36 + root.albumsData.length * 44)
                color: theme.panel
                border.color: theme.border
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 2
                    Label { text: "Albums on the computer"; color: theme.muted; font.pixelSize: 12; font.bold: true; leftPadding: 6 }
                    ListView {
                        Layout.fillWidth: true
                        Layout.fillHeight: true
                        clip: true
                        model: root.albumsData
                        delegate: ItemDelegate {
                            required property var modelData
                            width: ListView.view.width
                            height: 42
                            text: modelData.name + "  ·  " + modelData.photos
                            highlighted: root.filterData.albumId === modelData.id
                            onClicked: { root.filterYear = 0; root.filterMonth = 0; root.filterDay = 0; library.filterAlbum(modelData.id); dates.close() }
                        }
                    }
                }
            }
        }
    }

    EndpointDialog {
        id: endpointDialog
        theme: root.theme
        current: library.endpoint
        anchors.centerIn: parent
        width: Math.min(360, root.width - 32)
        onChosen: (host, port) => library.setEndpoint(host, port)
    }

    function pad(n) { return n < 10 ? "0" + n : String(n) }

    // Headless capture, same hooks as the desktop: PW_SHOT=/path.png (+ PW_SHOT_OPEN=<id>).
    Timer {
        running: library.shotPath.length > 0 && library.shotOpenId > 0 && root.status.connected
        interval: 1500
        onTriggered: library.openPhoto(library.shotOpenId)
    }
    Timer {
        running: library.shotPath.length > 0 && library.shotSend && library.computerConnected
        interval: 2500
        onTriggered: library.sendAll()
    }
    Timer {
        running: library.shotPath.length > 0
        interval: library.shotSend ? 12000 : 5000
        onTriggered: shell.grabToImage(function (r) {
            r.saveToFile(library.shotPath)
            console.log("shot saved to", library.shotPath, "items:", root.pageData.items.length)
            library.quit()
        })
    }

    Component.onCompleted: library.loadDates()
}
