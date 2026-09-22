import QtQuick
import QtQuick.Controls
import QtQuick.Controls.Material
import QtQuick.Layouts

// Phone layout: a top bar, a bottom navigation (Photos / Albums / Computer), the
// grid, and the viewer on top. Same backend payloads as the desktop Main.qml;
// thumbnails and photos arrive as data: URLs because the library is on another machine.
ApplicationWindow {
    id: root
    // Android's Back: close what is open (viewer, dialog, drawer), then step back
    // through the tabs, before the app.
    onClosing: (close) => {
        if (root.current !== null) { close.accepted = false; library.closePhoto() }
        else if (dates.opened) { close.accepted = false; dates.close() }
        else if (root.tab !== 0) { close.accepted = false; root.tab = 0 }
    }
    width: 412
    height: 915
    visible: true
    title: "Photo Wagon"
    color: theme.bg

    // The phone's light / dark setting, read from the platform colour scheme.
    // (Material.theme is a MODE, so styleHints.colorScheme is the resolved scheme.)
    readonly property bool dark: Qt.styleHints.colorScheme === Qt.Dark
    Material.theme: root.dark ? Material.Dark : Material.Light
    Material.accent: theme.accent
    Material.primary: theme.panel
    Material.background: theme.bg
    Material.foreground: theme.text

    // Wagon — bold local-first brand: terracotta + ink on cream, with a deep-green
    // "your photos live at home" link chip as the signature element.
    readonly property QtObject theme: QtObject {
        readonly property color bg: root.dark ? "#17120f" : "#faf5ee"
        readonly property color panel: root.dark ? "#201813" : "#fffefb"
        readonly property color panelAlt: root.dark ? "#2a201a" : "#f1e8dc"
        readonly property color border: root.dark ? "#33271f" : "#ece2d5"
        readonly property color text: root.dark ? "#f4ece2" : "#1b1613"
        readonly property color muted: root.dark ? "#a2917f" : "#8a7d70"
        readonly property color accent: root.dark ? "#e2623a" : "#d24e2a"
        readonly property color accentText: "#ffffff"
        readonly property color ok: root.dark ? "#4bbd82" : "#2f7d53"
        readonly property color warn: "#e08a2c"
        // the link-state chip: a signature green pill ("mora em casa")
        readonly property color home: root.dark ? "#0f5a4d" : "#124b40"
        readonly property color homeText: "#eafff6"
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
    readonly property var pageData: JSON.parse(library.page)
    readonly property var datesData: JSON.parse(library.dates)
    readonly property var current: library.current.length ? JSON.parse(library.current) : null
    readonly property var albumsData: JSON.parse(library.albums).albums
    readonly property var filterData: JSON.parse(library.filter)
    readonly property var peopleData: JSON.parse(library.people).people
    readonly property var facesData: JSON.parse(library.faces).faces

    property int tab: 0                 // 0 Photos · 1 Albums · 2 Computer
    property int filterYear: 0
    property int filterMonth: 0
    property int filterDay: 0
    readonly property int pageSize: 60

    // UI-thread watchdog: a 250 ms timer that arrives late means the thread was busy.
    Timer {
        property double last: 0
        interval: 250; repeat: true; running: true
        onTriggered: {
            const now = Date.now()
            if (last > 0 && now - last > 700) console.log("ui stalled " + (now - last) + " ms")
            last = now
        }
    }

    function applyFilter(y, m, d) {
        filterYear = y; filterMonth = m; filterDay = d
        library.loadPage(0, pageSize, y, m, d)
        dates.close()
        tab = 0
    }
    function openAlbum(id) {
        filterYear = 0; filterMonth = 0; filterDay = 0
        library.filterAlbum(id)
        tab = 0
    }
    function albumName(id) {
        for (const a of albumsData) if (a.id === id) return a.name
        return "Album"
    }
    function photosTitle() {
        if (filterData.albumId) return albumName(filterData.albumId)
        if (filterYear === 0) return "Photos"
        if (filterDay) return new Date(filterYear, filterMonth - 1, filterDay).toLocaleDateString(Qt.locale(), "d MMMM yyyy")
        if (filterMonth) return new Date(filterYear, filterMonth - 1, 1).toLocaleDateString(Qt.locale(), "MMMM yyyy")
        return String(filterYear)
    }
    readonly property bool filtered: filterData.albumId || filterYear !== 0

    // An icon button of the app bar: our SVG icons, tinted (Android has no glyph fonts).
    component BarButton: ToolButton {
        id: bb
        required property string icon_
        property color tint: theme.text
        implicitWidth: 44
        implicitHeight: 44
        background: Rectangle {
            radius: 10; anchors.margins: 3; anchors.fill: parent
            color: bb.pressed ? theme.panelAlt : "transparent"
        }
        contentItem: Image {
            source: icons.tint(bb.icon_, bb.enabled ? bb.tint : theme.muted)
            sourceSize.width: 22; sourceSize.height: 22
            fillMode: Image.Pad
            horizontalAlignment: Image.AlignHCenter; verticalAlignment: Image.AlignVCenter
        }
    }

    // ---- top bar: contextual to the tab ------------------------------------------
    header: ToolBar {
        id: bar
        height: 58
        Material.elevation: 0
        background: Rectangle {
            color: theme.panel
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.border }
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 6; anchors.rightMargin: 14
            spacing: 6
            // menu / jump-to-a-date, top-LEFT; the date drawer slides in from the left to match
            BarButton {
                visible: root.tab === 0
                icon_: icons.sidebar
                onClicked: dates.open()
            }
            // "back" out of a date/album filter, on the Photos tab
            BarButton {
                visible: root.tab === 0 && root.filtered
                icon_: icons.chevronLeft
                onClicked: { root.filterYear = 0; root.filterMonth = 0; root.filterDay = 0; library.loadPage(0, root.pageSize, 0, 0, 0) }
            }
            Label {
                text: root.tab === 0 ? root.photosTitle() : root.tab === 1 ? "Search" : "Library"
                font.pixelSize: 21; font.weight: Font.Bold; font.letterSpacing: -0.3
                color: theme.accent; elide: Text.ElideRight
                Layout.fillWidth: true
            }
            BusyIndicator {
                running: root.status.indexing || root.syncData.active
                visible: running; implicitWidth: 22; implicitHeight: 22
                Material.accent: theme.accent
            }
        }
    }

    // ---- content: one page per tab -----------------------------------------------
    StackLayout {
        id: pages
        anchors.fill: parent
        currentIndex: root.tab

        // 0 — Photos: the desktop link chip (Wagon signature) sits above the grid
        ColumnLayout {
            spacing: 0
            // "your photos live at home" — connection + how many are still on their way
            Rectangle {
                id: linkChip
                readonly property int remaining: root.syncData.pending || 0
                readonly property bool up: library.computerConnected
                // Google-Photos style: when everything is home and quiet, the banner steps
                // out of the way so the grid runs full height; it returns the moment there is
                // something to say (offline, or photos still on their way).
                visible: !(linkChip.up && linkChip.remaining === 0)
                Layout.fillWidth: true
                Layout.leftMargin: 10; Layout.rightMargin: 10
                Layout.topMargin: 8; Layout.bottomMargin: 4
                radius: height / 2
                implicitHeight: 42
                color: up ? theme.home : theme.panelAlt
                border.color: up ? "transparent" : theme.border
                border.width: up ? 0 : 1
                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 14; anchors.rightMargin: 12
                    spacing: 9
                    Rectangle {
                        implicitWidth: 9; implicitHeight: 9; radius: 4.5
                        color: linkChip.up ? "#5fe0b0" : theme.warn
                    }
                    Label {
                        Layout.fillWidth: true
                        color: linkChip.up ? theme.homeText : theme.text
                        font.pixelSize: 13; font.weight: Font.DemiBold
                        elide: Text.ElideRight
                        text: linkChip.up
                              ? (linkChip.remaining > 0 ? "Desktop reachable · " + linkChip.remaining + " left" : "Desktop reachable · all sent")
                              : (linkChip.remaining > 0 ? "Desktop offline · " + linkChip.remaining + " will resume" : "Desktop offline · tap to connect")
                    }
                    Label {
                        text: "›"
                        font.pixelSize: 18
                        color: linkChip.up ? theme.homeText : theme.muted
                        opacity: 0.7
                    }
                }
                TapHandler { onTapped: root.tab = 2 }
            }
            PhotoGrid {
                id: grid
                Layout.fillWidth: true
                Layout.fillHeight: true
                theme: root.theme
                page: root.pageData
                onLoadMore: library.loadPage(root.pageData.offset, root.pageSize, root.filterYear, root.filterMonth, root.filterDay)
                onOpen: (id) => library.openPhoto(id)
            }
        }

        // 1 — Search (first-class find surface)
        SearchPage {
            theme: root.theme
            people: root.peopleData
            connected: library.computerConnected
            onSearch: (q) => { library.filterSearch(q); root.tab = 0 }
            onOpenPerson: (id) => { library.filterPerson(id); root.tab = 0 }
            onBrowseDates: dates.open()
        }

        // 2 — Library (hub: Albums + Computer/sync)
        LibraryPage {
            theme: root.theme
            icons: icons
            albums: root.albumsData
            connected: library.computerConnected
            sync: root.syncData
            endpoint: library.endpoint
            onOpenAlbum: (id) => root.openAlbum(id)
            onChangeEndpoint: endpointDialog.open()
            onSendAll: library.sendAll()
            onAutoSync: (on) => library.setAutoSync(on)
            onRescan: library.rescanPhotos()
        }
    }

    // ---- bottom navigation -------------------------------------------------------
    footer: TabBar {
        id: nav
        currentIndex: root.tab
        onCurrentIndexChanged: root.tab = currentIndex
        Material.elevation: 0
        background: Rectangle {
            color: theme.panel
            Rectangle { width: parent.width; height: 1; color: theme.border }
        }
        component NavTab: TabButton {
            id: nt
            required property string icon_
            required property string label
            property bool alert: false
            height: 56
            contentItem: ColumnLayout {
                spacing: 2
                Item {
                    Layout.alignment: Qt.AlignHCenter
                    implicitWidth: 24; implicitHeight: 24
                    Image {
                        anchors.centerIn: parent
                        source: icons.tint(nt.icon_, nt.checked ? theme.accent : theme.muted)
                        sourceSize.width: 24; sourceSize.height: 24
                    }
                    Rectangle {
                        visible: nt.alert
                        anchors.right: parent.right; anchors.top: parent.top
                        anchors.rightMargin: -2; anchors.topMargin: -1
                        width: 8; height: 8; radius: 4; color: theme.warn
                        border.width: 1.5; border.color: theme.panel
                    }
                }
                Label {
                    text: nt.label; Layout.alignment: Qt.AlignHCenter
                    font.pixelSize: 11
                    color: nt.checked ? theme.accent : theme.muted
                }
            }
            background: Rectangle { color: "transparent" }
        }
        NavTab { icon_: icons.photos; label: "Photos" }
        NavTab { icon_: icons.search; label: "Search" }
        NavTab {
            icon_: icons.album; label: "Library"
            alert: !library.computerConnected || root.syncData.pending > 0
        }
    }

    // ---- overlays ----------------------------------------------------------------
    PhotoFocusView {
        id: focusView
        parent: Overlay.overlay
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
        onEdit: editView.open(root.current)
        onSend: (id) => library.sendToComputer(id)
        onNameFace: (faceId, personId, name) => library.setFacePerson(faceId, personId, name)
    }

    EditView {
        id: editView
        parent: Overlay.overlay
        anchors.fill: parent
        z: 50
        theme: root.theme
        icons: icons
        photo: null
        visible: photo !== null
        function open(p) { photo = p }
        onCancelled: photo = null
        onSaved: (path) => photo = null
    }

    Drawer {
        id: dates
        width: Math.min(320, root.width * 0.84)
        height: root.height
        Material.background: theme.panel
        DateTreeSidebar {
            anchors.fill: parent
            theme: root.theme
            dates: root.datesData
            selectedYear: root.filterYear
            selectedMonth: root.filterMonth
            selectedDay: root.filterDay
            onPicked: (y, m, d) => root.applyFilter(y, m, d)
        }
    }

    // First pairing: show the 4-digit code to type on the computer.
    Popup {
        id: pairingCodePopup
        readonly property var pd: { try { return JSON.parse(library.pairingCode) } catch (e) { return ({}) } }
        property string dismissed: ""
        parent: Overlay.overlay
        anchors.centerIn: parent
        modal: true
        closePolicy: Popup.NoAutoClose
        visible: pd.code !== undefined && pd.code !== dismissed
        padding: 24
        background: Rectangle { color: theme.panel; border.color: theme.border; radius: 14 }
        contentItem: ColumnLayout {
            spacing: 14
            Label { text: "Confirm on the computer"; font.pixelSize: 18; font.weight: Font.DemiBold; color: theme.text }
            Label {
                text: "Type this code in Photo Wagon on the computer to allow this phone. You can keep browsing your own photos meanwhile."
                color: theme.muted; wrapMode: Text.WordWrap; Layout.preferredWidth: 260
            }
            Label {
                text: pairingCodePopup.pd.code || ""
                font.pixelSize: 44; font.bold: true; font.letterSpacing: 10
                color: theme.accent; Layout.alignment: Qt.AlignHCenter
            }
            RowLayout {
                Layout.fillWidth: true
                BusyIndicator { running: true; implicitWidth: 26; implicitHeight: 26 }
                Item { Layout.fillWidth: true }
                Button { text: "Later"; flat: true; onClicked: pairingCodePopup.dismissed = pairingCodePopup.pd.code }
            }
        }
    }

    EndpointDialog {
        id: endpointDialog
        theme: root.theme
        current: library.endpoint
        parent: Overlay.overlay
        anchors.centerIn: parent
        width: Math.min(360, root.width - 32)
        onChosen: (host, port) => library.setEndpoint(host, port)
    }

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
        onTriggered: root.grabToImage(function (r) {
            r.saveToFile(library.shotPath)
            console.log("shot saved to", library.shotPath, "items:", root.pageData.items.length)
            library.quit()
        })
    }

    Component.onCompleted: library.loadDates()
}
