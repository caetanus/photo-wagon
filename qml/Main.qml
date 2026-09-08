import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

ApplicationWindow {
    id: root
    width: 1280
    height: 820
    visible: true
    title: "Photo Wagon"
    color: theme.bg

    // Dark theme tokens shared by every component through `theme`.
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

    // Backend payloads parsed once, here, and handed down as objects.
    readonly property var status: JSON.parse(library.status)
    readonly property var pageData: JSON.parse(library.page)
    readonly property var datesData: JSON.parse(library.dates)
    readonly property var current: library.current.length ? JSON.parse(library.current) : null

    // Active date filter (0 = none).
    property int filterYear: 0
    property int filterMonth: 0
    property int filterDay: 0

    function applyFilter(y, m, d) {
        filterYear = y; filterMonth = m; filterDay = d
        library.loadPage(0, 120, y, m, d)
    }

    FolderDialog {
        id: folderDialog
        title: "Add a folder to the library"
        onAccepted: library.addRoot(selectedFolder.toString())
    }

    Item {
        id: shell
        anchors.fill: parent

    ToolBar {
        id: toolbar
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        height: 48
        background: Rectangle { color: theme.panel; border.color: theme.border }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 12
            anchors.rightMargin: 12
            spacing: 10
            Label {
                text: "Photo Wagon"
                font.pixelSize: 17
                font.bold: true
                color: theme.text
            }
            Label {
                text: filterYear === 0 ? "All photos"
                    : (filterDay ? filterYear + "-" + pad(filterMonth) + "-" + pad(filterDay)
                       : filterMonth ? filterYear + "-" + pad(filterMonth) : String(filterYear))
                color: theme.muted
                Layout.leftMargin: 8
            }
            Item { Layout.fillWidth: true }
            Label {
                text: status.text
                color: status.connected ? theme.muted : "#ff8a80"
                elide: Text.ElideRight
                Layout.maximumWidth: 420
            }
            BusyIndicator {
                running: status.indexing
                visible: running
                implicitWidth: 22
                implicitHeight: 22
            }
            ToolButton {
                text: "Add folder"
                enabled: status.connected
                onClicked: folderDialog.open()
            }
            ToolButton {
                text: "Phone"
                enabled: status.connected
                onClicked: phonePanel.open()
            }
            ToolButton {
                text: "Peers"
                onClicked: peersPanel.open()
            }
        }
    }

    SplitView {
        anchors.top: toolbar.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        orientation: Qt.Horizontal

        DateTreeSidebar {
            id: sidebar
            SplitView.preferredWidth: 240
            SplitView.minimumWidth: 160
            theme: root.theme
            dates: root.datesData
            selectedYear: root.filterYear
            selectedMonth: root.filterMonth
            selectedDay: root.filterDay
            onPicked: (y, m, d) => root.applyFilter(y, m, d)
        }

        PhotoGrid {
            id: grid
            SplitView.fillWidth: true
            theme: root.theme
            page: root.pageData
            onLoadMore: library.loadPage(root.pageData.offset, 120, root.filterYear, root.filterMonth, root.filterDay)
            onOpen: (id) => library.openPhoto(id)
        }
    }

    PhotoFocusView {
        id: focusView
        anchors.fill: parent
        theme: root.theme
        photo: root.current
        visible: root.current !== null
        onClosed: library.closePhoto()
    }
    } // shell

    PhonePanel {
        id: phonePanel
        theme: root.theme
        pairing: JSON.parse(library.pairing)
        anchors.centerIn: parent
        width: Math.min(460, root.width - 80)
    }

    PeersPanel {
        id: peersPanel
        theme: root.theme
        anchors.centerIn: parent
        width: Math.min(720, root.width - 80)
        height: Math.min(600, root.height - 80)
    }

    function pad(n) { return n < 10 ? "0" + n : String(n) }

    // Headless capture: PW_SHOT=/path.png → grab the window contents and quit.
    Timer {
        running: library.shotPath.length > 0 && library.shotOpenId > 0 && root.status.connected
        interval: 800
        onTriggered: library.openPhoto(library.shotOpenId)
    }
    Timer {
        running: library.shotPath.length > 0 && library.shotSend && root.status.connected
        interval: 600
        onTriggered: phonePanel.open()   // PW_SHOT_SEND=1 on the desktop: photograph the pairing panel
    }
    Timer {
        running: library.shotPath.length > 0
        interval: 3000
        onTriggered: (library.shotSend ? phonePanel.body : shell).grabToImage(function (r) {
            r.saveToFile(library.shotPath)
            console.log("shot saved to", library.shotPath, "items:", root.pageData.items.length)
            library.quit()
        })
    }

    Component.onCompleted: library.loadDates()
}
