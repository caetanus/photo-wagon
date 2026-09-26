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
        // the topmost first: the editor sits over the viewer
        if (editView.photo !== null) { close.accepted = false; editView.requestClose() }
        else if (albumPicker.opened) { close.accepted = false; albumPicker.close() }
        else if (root.current === null && root.tab === 0 && grid.selecting) { close.accepted = false; grid.clearSelection() }
        else if (root.current !== null) { close.accepted = false; library.closePhoto() }
        else if (dates.opened) { close.accepted = false; dates.close() }
        else if (root.tab !== 0) { close.accepted = false; root.tab = 0 }
        // the top of the app: to the background, like any Android app — closing the Qt window
        // here left a blank screen when the app was opened again (the process lives on)
        else if (Qt.platform.os === "android") { close.accepted = false; Qt.openUrlExternally("pwback://") }
    }
    width: 412
    height: 915
    visible: true
    // A phone app keeps the status and navigation bars: maximized, not full screen. Where
    // Android still draws us edge to edge, the safe-area margins keep content off the bars.
    visibility: Qt.platform.os === "android" ? Window.Maximized : Window.AutomaticVisibility
    readonly property real safeTop: SafeArea.margins.top
    readonly property real safeBottom: SafeArea.margins.bottom
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

    // Neutral, photo-first palette: near-black / white grounds and neutral greys so the
    // pictures carry the colour, with a cool indigo accent (distinct from the generic
    // system blue) and a teal "your photos live at home" link chip. Amber stays only for
    // interruptions.
    readonly property QtObject theme: QtObject {
        readonly property color bg: root.dark ? "#0c0c0e" : "#ffffff"
        readonly property color panel: root.dark ? "#161619" : "#ffffff"
        readonly property color panelAlt: root.dark ? "#1f1f24" : "#eeeef1"
        readonly property color border: root.dark ? "#2a2a30" : "#e3e3e8"
        readonly property color text: root.dark ? "#f3f3f6" : "#17171b"
        readonly property color muted: root.dark ? "#8b8b95" : "#8a8a91"
        readonly property color accent: root.dark ? "#6f6cf7" : "#5451d6"
        readonly property color accentText: "#ffffff"
        readonly property color ok: root.dark ? "#37d29b" : "#12a06a"
        readonly property color warn: "#e0a12c"
        // the link-state chip: a cool teal pill when the desktop is reachable
        readonly property color home: root.dark ? "#0e7c8c" : "#0e7490"
        readonly property color homeText: "#eafcff"
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
    readonly property var castDevicesData: { try { return JSON.parse(library.castDevices).devices } catch (e) { return [] } }
    readonly property var filterData: JSON.parse(library.filter)
    readonly property var peopleData: JSON.parse(library.people).people
    readonly property var facesData: JSON.parse(library.faces).faces

    property int tab: 0                 // 0 Photos · 1 Albums · 2 Computer
    // a selection belongs to the view it was made in
    onTabChanged: grid.clearSelection()
    onFilterDataChanged: grid.clearSelection()
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
    // every "connect" action lands on the computer's page itself, not on Library's first tab
    function openComputer() {
        tab = 2
        libraryPage.showComputer()
    }
    // a true reset: date, album, person and search filters all go
    function showAllPhotos() {
        filterYear = 0; filterMonth = 0; filterDay = 0
        library.showAll()
    }
    readonly property bool paired: library.computerPaired
    function showToast(text) {
        toast.text = text
        toast.opacity = 1
        toastTimer.restart()
    }
    // "your photos live at home": the computer link and how many photos are still on their
    // way — shown as the computer icon at the top right (its dot and count); tapping it
    // opens the computer's page, a long press says it in words
    QtObject {
        id: link
        readonly property int remaining: root.syncData.pending || 0
        // failed in this run, or given up after their retries (waiting for Send all now)
        readonly property int failed: root.syncData.failedPhotos || 0
        readonly property bool active: root.syncData.active === true
        readonly property bool auto: root.syncData.enabled === true
        readonly property bool up: library.computerConnected
        // unpaired is a choice, not a fault: an invitation, never the amber warning
        readonly property bool invite: !root.paired
        readonly property bool alarm: !up && !invite && remaining > 0 || failed > 0
        readonly property color dot: failed > 0 ? theme.warn : up ? "#5fe0b0"
                                   : invite ? theme.accent : alarm ? theme.warn : theme.muted
        // the number on the icon: what still has to go (failures first)
        readonly property int badge: failed > 0 ? failed : remaining
        readonly property string held: root.syncData.held || ""
        readonly property string summary: held === "paused" ? "Sending paused" + (remaining > 0 ? " · " + remaining + " waiting" : "")
            : held === "metered" ? "Waiting for Wi-Fi (data saver)" + (remaining > 0 ? " · " + remaining + " waiting" : "")
            : failed > 0
              ? failed + (failed === 1 ? " photo couldn't be sent" : " photos couldn't be sent")
              : up
                ? (remaining === 0 ? "Connected to your computer — everything is there"
                   : active ? remaining + (remaining === 1 ? " photo" : " photos") + " going to the computer"
                   : auto ? remaining + " waiting to go to the computer"
                   : remaining + (remaining === 1 ? " photo" : " photos") + " not on the computer")
                : invite ? "Not connected to a computer yet — tap to connect"
                : remaining > 0 ? "Computer offline · " + remaining + (auto ? " waiting" : " not sent")
                : "Computer offline"
    }
    function personName(id) {
        for (const p of peopleData) if (p.id === id) return p.name || "Person"
        return "Person"
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
        if (filterData.search) return "“" + filterData.search + "”"
        if (filterData.personId) return personName(filterData.personId)
        if (filterData.albumId) return albumName(filterData.albumId)
        // a collection keeps its name, with the date narrowing it
        const coll = collectionName()
        if (coll.length) return filterYear === 0 ? coll : coll + " · " + dateTitle()
        if (filterYear === 0) return "Photos"
        return dateTitle()
    }
    function collectionName() {
        if (filterData.favorites) return "Favorites"
        if (filterData.kind === "screenshot") return "Screenshots"
        if (filterData.kind === "video") return "Videos"
        return ""
    }
    function dateTitle() {
        if (filterDay) return new Date(filterYear, filterMonth - 1, filterDay).toLocaleDateString(Qt.locale(), "d MMMM yyyy")
        if (filterMonth) return new Date(filterYear, filterMonth - 1, 1).toLocaleDateString(Qt.locale(), "MMMM yyyy")
        return String(filterYear)
    }
    readonly property bool filtered: filterData.albumId || filterData.personId || !!filterData.search || filterYear !== 0
                                     || filterData.favorites === true || !!filterData.kind
    // the collections (Search's categories, Library's cards) open in Photos
    function openKind(kind) { filterYear = 0; filterMonth = 0; filterDay = 0; library.filterKind(kind); tab = 0 }
    function openFavorites() { filterYear = 0; filterMonth = 0; filterDay = 0; library.filterFavorites(); tab = 0 }

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
        height: 58 + root.safeTop
        Material.elevation: 0
        background: Rectangle {
            color: theme.panel
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.border }
        }
        // a selection on the grid: how many, and what can be done with them
        RowLayout {
            id: selectionBar
            visible: root.tab === 0 && grid.selecting
            anchors.fill: parent
            anchors.topMargin: root.safeTop
            anchors.leftMargin: 6; anchors.rightMargin: 8
            spacing: 2
            readonly property var items: { grid.selVersion; return grid.selectedItems() }
            // the phone's own photos not on the computer yet
            readonly property var unsent: items.filter(it => !it.remote && !it.sent)
            BarButton { icon_: icons.close; onClicked: grid.clearSelection() }
            Label {
                text: grid.selectedCount === 0 ? "Select photos" : grid.selectedCount + " selected"
                font.pixelSize: 19; font.weight: Font.Bold
                color: theme.text; elide: Text.ElideRight
                Layout.fillWidth: true
            }
        }
        RowLayout {
            visible: !selectionBar.visible
            anchors.fill: parent
            anchors.topMargin: root.safeTop
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
                onClicked: root.showAllPhotos()
            }
            Label {
                text: root.tab === 0 ? root.photosTitle() : root.tab === 1 ? "Search" : "Library"
                font.pixelSize: 21; font.weight: Font.Bold; font.letterSpacing: -0.3
                color: theme.text; elide: Text.ElideRight
                Layout.fillWidth: true
            }
            BusyIndicator {
                running: root.status.indexing || root.syncData.active
                visible: running; implicitWidth: 22; implicitHeight: 22
                Material.accent: theme.accent
            }
            // pick several photos (a long press on one does the same)
            BarButton {
                visible: root.tab === 0 && (root.pageData.items || []).length > 0
                icon_: icons.check
                onClicked: grid.selectMode = true
            }
            // the computer link, top right (nothing until the phone core has told us its state)
            ToolButton {
                id: computerButton
                visible: root.status.connected
                implicitWidth: 48; implicitHeight: 44
                background: Rectangle {
                    radius: 10; anchors.margins: 3; anchors.fill: parent
                    color: computerButton.pressed ? theme.panelAlt : "transparent"
                }
                contentItem: Item {
                    Image {
                        anchors.centerIn: parent
                        anchors.horizontalCenterOffset: -3   // room on the right for the count
                        source: icons.tint(icons.computer, theme.text)
                        sourceSize.width: 22; sourceSize.height: 22
                    }
                    // state: a dot, or the count still to go
                    Rectangle {
                        anchors.right: parent.right; anchors.top: parent.top
                        // on the icon's corner, spilling outward — never over the screen
                        anchors.rightMargin: link.badge > 0 ? -2 : 7; anchors.topMargin: link.badge > 0 ? 1 : 8
                        height: link.badge > 0 ? 15 : 9
                        width: link.badge > 0 ? Math.max(15, badgeText.implicitWidth + 6) : 9
                        radius: height / 2
                        color: link.dot
                        border.color: theme.panel; border.width: 1.5
                        Label {
                            id: badgeText
                            visible: link.badge > 0
                            anchors.centerIn: parent
                            text: link.badge > 99 ? "99+" : String(link.badge)
                            // dark on the bright green / amber, white on the indigo / grey
                            color: link.failed > 0 || link.alarm || link.up ? "#16181d" : "#ffffff"
                            font.pixelSize: 9; font.weight: Font.Bold
                        }
                    }
                }
                Accessible.name: link.summary
                onClicked: root.openComputer()
                onPressAndHold: root.showToast(link.summary)
            }
        }
    }

    // ---- content: one page per tab -----------------------------------------------
    StackLayout {
        id: pages
        anchors.fill: parent
        currentIndex: root.tab

        // 0 — Photos
        ColumnLayout {
            spacing: 0
            // a search says where it looked: offline, only this phone's file names
            Rectangle {
                visible: !!root.filterData.search && (root.pageData.scope === "phone" || !!root.pageData.error)
                Layout.fillWidth: true
                Layout.leftMargin: 10; Layout.rightMargin: 10
                Layout.topMargin: 6; Layout.bottomMargin: 4
                radius: 10
                color: theme.panelAlt
                border.color: theme.border; border.width: 1
                implicitHeight: searchNote.implicitHeight + 16
                Label {
                    id: searchNote
                    anchors.fill: parent; anchors.margins: 8; anchors.leftMargin: 12
                    wrapMode: Text.WordWrap
                    font.pixelSize: 12; color: theme.muted
                    text: root.pageData.error
                          ? "The search didn't work: " + root.pageData.error
                          : root.pageData.reason === "timeout" || root.pageData.reason === "failed"
                            ? "The computer didn't answer this search" + (root.pageData.reason === "timeout" ? " in time" : "") + " — only this phone's file and folder names were searched."
                          : root.paired
                            ? "Computer offline — only this phone's file and folder names were searched. What's in the photos is searched on the computer."
                            : "Only this phone's file and folder names were searched. Connect your computer to search by what's in the photos."
                }
                TapHandler { enabled: !root.paired; onTapped: root.openComputer() }
            }
            PhotoGrid {
                id: grid
                Layout.fillWidth: true
                Layout.fillHeight: true
                theme: root.theme
                page: root.pageData
                ready: root.status.connected
                emptyText: root.pageData.searching ? "Searching…"
                           : root.filterData.search
                           ? "Nothing matches “" + root.filterData.search + "”."
                           : root.filterData.favorites === true && !library.computerConnected
                             ? "Favorites live on your computer — connect it to see them."
                           : root.filterData.kind === "video" ? "No videos here."
                           : root.filterData.kind === "screenshot" ? "No screenshots here."
                           : root.filterData.albumId || root.filterData.personId || root.filterYear !== 0
                             || root.filterData.favorites === true || !!root.filterData.kind
                             ? "No photos here."
                             : "No photos yet — allow access to your photos, or wait for the scan."
                onLoadMore: library.loadPage(root.pageData.offset, root.pageSize, root.filterYear, root.filterMonth, root.filterDay)
                onOpen: (id) => library.openPhoto(id)
            }
            // selecting: what can be done with the chosen photos, in reach of the thumb
            Rectangle {
                id: selectionPanel
                visible: grid.selecting
                Layout.fillWidth: true
                implicitHeight: selCol.implicitHeight + 16 + root.safeBottom
                color: theme.panel
                topLeftRadius: 18; topRightRadius: 18
                Rectangle { width: parent.width; height: 1; color: theme.border; opacity: 0.6 }
                component SelAction: ItemDelegate {
                    id: sa
                    required property string icon_
                    property string label: ""
                    Layout.fillWidth: true
                    implicitHeight: 68
                    opacity: enabled ? 1 : 0.4
                    background: Rectangle { color: sa.pressed ? theme.panelAlt : "transparent"; radius: 12 }
                    contentItem: ColumnLayout {
                        spacing: 5
                        Rectangle {
                            Layout.alignment: Qt.AlignHCenter
                            implicitWidth: 44; implicitHeight: 32; radius: 16
                            color: theme.panelAlt
                            Image {
                                anchors.centerIn: parent
                                source: icons.tint(sa.icon_, theme.text)
                                sourceSize.width: 20; sourceSize.height: 20
                            }
                        }
                        Label {
                            Layout.alignment: Qt.AlignHCenter
                            text: sa.label; color: theme.text; font.pixelSize: 12
                        }
                    }
                }
                ColumnLayout {
                    id: selCol
                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top
                    anchors.margins: 8; anchors.topMargin: 10
                    spacing: 2
                    Label {
                        Layout.fillWidth: true; Layout.leftMargin: 8
                        text: grid.selectedCount === 0 ? "Tap photos to select them, or a day's circle for the whole day"
                              : root.paired && selectionBar.unsent.length > 0
                                ? selectionBar.unsent.length + (selectionBar.unsent.length === 1 ? " of them isn't" : " of them aren't") + " on the computer yet"
                                : ""
                        visible: text.length > 0
                        color: theme.muted; font.pixelSize: 12
                        wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 4
                        SelAction {
                            icon_: icons.share; label: "Share"
                            enabled: grid.selectedCount > 0
                            onClicked: library.sharePhotos(JSON.stringify(grid.selectedIds()))
                        }
                        SelAction {
                            icon_: icons.album; label: "Add to album"
                            enabled: grid.selectedCount > 0
                            onClicked: albumPicker.openFor(grid.selectedIds())
                        }
                        SelAction {
                            visible: root.paired
                            icon_: icons.upload; label: "Send"
                            enabled: library.computerConnected && selectionBar.unsent.length > 0
                            onClicked: {
                                library.sendPhotosToComputer(JSON.stringify(selectionBar.unsent.map(it => it.id)))
                                grid.clearSelection()
                            }
                        }
                    }
                }
            }
        }

        // 1 — Search (first-class find surface)
        SearchPage {
            theme: root.theme
            people: root.peopleData
            connected: library.computerConnected
            onSearch: (q) => { root.filterYear = 0; root.filterMonth = 0; root.filterDay = 0; library.filterSearch(q); root.tab = 0 }
            onOpenPerson: (id) => { library.filterPerson(id); root.tab = 0 }
            onBrowseDates: dates.open()
            onOpenKind: (kind) => root.openKind(kind)
            onOpenFavorites: root.openFavorites()
        }

        // 2 — Library (hub: Albums + Computer/sync)
        LibraryPage {
            id: libraryPage
            theme: root.theme
            icons: icons
            albums: root.albumsData
            connected: library.computerConnected
            sync: root.syncData
            endpoint: library.endpoint
            paired: root.paired
            onOpenAlbum: (id) => root.openAlbum(id)
            onCreateAlbum: (name) => library.createAlbum(name, "[]")
            onRenameAlbum: (id, name) => library.renameAlbum(id, name)
            onDeleteAlbum: (id) => library.deleteAlbum(id)
            onChangeEndpoint: endpointDialog.open()
            onSendAll: library.sendAll()
            onAutoSync: (on) => library.setAutoSync(on)
            onPauseSync: (paused) => library.pauseSync(paused)
            onDataSaver: (on) => library.setDataSaver(on)
            onRescan: library.rescanPhotos()
            onOpenKind: (kind) => root.openKind(kind)
            onOpenFavorites: root.openFavorites()
        }
    }

    // ---- bottom navigation -------------------------------------------------------
    footer: TabBar {
        id: nav
        // selecting on the grid: the actions panel takes its place (as in a gallery)
        visible: !(root.tab === 0 && grid.selecting)
        currentIndex: root.tab
        onCurrentIndexChanged: root.tab = currentIndex
        bottomPadding: root.safeBottom   // clear of the gesture / navigation bar
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
            // something to act on — not merely "no computer set up yet"
            alert: (root.syncData.failedPhotos || 0) > 0 || (root.paired && !library.computerConnected && (root.syncData.pending || 0) > 0)
        }
    }

    // ---- overlays ----------------------------------------------------------------
    AlbumPickerDialog {
        id: albumPicker
        theme: root.theme
        albums: root.albumsData
        connected: library.computerConnected
        onAboutToShow: if (library.computerConnected) library.refreshAlbums()
        onPickAlbum: (albumId, ids) => { library.addToAlbum(albumId, JSON.stringify(ids)); grid.clearSelection() }
        onNewAlbum: (name, ids) => { library.createAlbum(name, JSON.stringify(ids)); grid.clearSelection() }
        onConnectComputer: { library.closePhoto(); root.openComputer() }
    }

    // the outcome of an action (added to an album, sent, shared): a short line at the bottom
    Rectangle {
        id: toast
        parent: Overlay.overlay
        z: 300
        property string text: ""
        visible: opacity > 0
        opacity: 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 96
        width: Math.min(toastLabel.implicitWidth + 32, parent.width - 32)
        height: toastLabel.implicitHeight + 20
        radius: 12
        color: root.dark ? "#2b2d35" : "#2a2c33"
        Label {
            id: toastLabel
            anchors.centerIn: parent
            width: Math.min(implicitWidth, toast.parent ? toast.parent.width - 64 : 300)
            text: toast.text
            color: "#ffffff"; font.pixelSize: 13
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
        }
        Timer { id: toastTimer; interval: 3500; onTriggered: toast.opacity = 0 }
        Connections {
            target: library
            function onNoticeChanged() { if (library.notice.length) root.showToast(library.notice) }
        }
    }

    PhotoFocusView {
        id: focusView
        parent: Overlay.overlay
        anchors.fill: parent
        theme: root.theme
        photo: root.current
        strip: root.current !== null ? JSON.parse(library.strip) : []
        castDevices: root.castDevicesData
        visible: root.current !== null
        canSend: true
        facesOnHover: false
        sendEnabled: library.computerConnected
        onAddToAlbum: (id) => albumPicker.openFor([id])
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
            scopeName: root.filterData.albumId ? "“" + root.albumName(root.filterData.albumId) + "”"
                     : root.filterData.personId ? root.personName(root.filterData.personId) + "'s photos"
                     : root.collectionName()
            searching: !!root.filterData.search
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
        Overlay.modal: Rectangle { color: Qt.rgba(0, 0, 0, 0.62) }
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
        paired: library.computerPaired
        connected: library.computerConnected
        approving: pairingCodePopup.pd.code !== undefined
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
