import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
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

    // Material, following the phone's light / dark setting; one palette for both.
    Material.theme: Material.System
    Material.accent: theme.accent
    Material.primary: theme.panel
    Material.background: theme.bg
    Material.foreground: theme.text
    readonly property bool dark: Material.theme === Material.Dark

    readonly property QtObject theme: QtObject {
        readonly property color bg: root.dark ? "#121417" : "#f4f5f7"
        readonly property color panel: root.dark ? "#1b1e24" : "#ffffff"
        readonly property color panelAlt: root.dark ? "#242830" : "#eceef2"
        readonly property color border: root.dark ? "#2c313a" : "#dcdfe5"
        readonly property color text: root.dark ? "#eceef2" : "#1a1d23"
        readonly property color muted: root.dark ? "#8f97a6" : "#6b7280"
        readonly property color accent: "#3d8bff"
        readonly property color accentText: "#ffffff"
    }
    Icons { id: icons }

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

    // An icon button of the app bar: our SVG icons, tinted, no glyph fonts (Android's has none of them).
    component BarButton: ToolButton {
        required property string icon_
        property string tip: ""
        implicitWidth: 48
        implicitHeight: 48
        contentItem: Image {
            source: icons.tint(parent.icon_, parent.enabled ? theme.text : theme.muted)
            sourceSize.width: 22; sourceSize.height: 22
            fillMode: Image.Pad
            horizontalAlignment: Image.AlignHCenter
            verticalAlignment: Image.AlignVCenter
        }
        ToolTip.visible: tip.length > 0 && pressed
        ToolTip.text: tip
    }

    Item {
        id: shell
        anchors.fill: parent

        ToolBar {
            id: bar
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 60
            Material.elevation: 0
            background: Rectangle {
                color: theme.panel
                Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.border }
            }
            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 4
                anchors.rightMargin: 6
                spacing: 2
                BarButton { icon_: icons.sidebar; tip: "Dates and albums"; onClicked: dates.open() }
                ColumnLayout {
                    spacing: 1
                    Layout.fillWidth: true
                    Label {
                        text: filterData.albumId ? albumName(filterData.albumId)
                            : filterYear === 0 ? "Photo Wagon"
                            : (filterDay ? new Date(filterYear, filterMonth - 1, filterDay).toLocaleDateString(Qt.locale(), "d MMMM yyyy")
                               : filterMonth ? new Date(filterYear, filterMonth - 1, 1).toLocaleDateString(Qt.locale(), "MMMM yyyy") : String(filterYear))
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                        color: theme.text
                        elide: Text.ElideRight
                        Layout.fillWidth: true
                    }
                    RowLayout {
                        spacing: 6
                        Layout.fillWidth: true
                        Rectangle {   // the link to the computer, as a dot
                            width: 8; height: 8; radius: 4
                            color: library.computerConnected ? "#3ecf8e" : (library.endpoint.length ? "#e8a33d" : theme.border)
                        }
                        Label {
                            text: root.syncData.active
                                ? "Sending " + (root.syncData.done + 1) + " of " + root.syncData.total
                                : library.computerConnected
                                    ? (root.syncData.pending ? root.syncData.pending + " to send" : (root.syncData.enabled ? "Computer up to date" : "Computer connected"))
                                    : (library.endpoint.length ? "Computer offline" : "No computer paired")
                            color: theme.muted
                            font.pixelSize: 12
                            elide: Text.ElideRight
                            Layout.fillWidth: true
                        }
                    }
                }
                BusyIndicator {
                    running: status.indexing || root.syncData.active
                    visible: running
                    implicitWidth: 24
                    implicitHeight: 24
                    Material.accent: theme.accent
                }
                BarButton {
                    icon_: icons.phone
                    tip: "Send to the computer"
                    enabled: library.computerConnected && !root.syncData.active
                    onClicked: library.sendAll()
                }
                BarButton { icon_: icons.network; tip: "Computer"; onClicked: endpointDialog.open() }
            }
        }

        PhotoGrid {
            id: grid
            anchors.top: bar.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
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
        width: Math.min(320, root.width * 0.84)
        height: root.height
        Material.background: theme.panel
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
                Rectangle { width: parent.width; height: 1; color: theme.border }
                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: 6
                    spacing: 2
                    Label { text: "ALBUMS ON THE COMPUTER"; color: theme.muted; font.pixelSize: 11; font.letterSpacing: 0.8; font.bold: true; leftPadding: 10; topPadding: 6 }
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
