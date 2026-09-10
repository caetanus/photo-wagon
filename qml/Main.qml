import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Dialogs

// Photo Wagon — desktop. A Photos-style window: source list on the left, a
// toolbar with Years / Months / Days / All Photos and a zoom slider, the grid,
// the viewer in place of the grid, People, and the Info panel.
ApplicationWindow {
    id: root
    width: 1280
    height: 820
    visible: true
    title: "Photo Wagon"
    color: theme.window
    font.family: "Noto Sans"
    font.pixelSize: 13

    // ---- theme: follows the system; light by default --------------------------------
    readonly property bool dark: Application.styleHints.colorScheme === Qt.ColorScheme.Dark
    readonly property QtObject theme: QtObject {
        readonly property color window: root.dark ? "#1e1e1e" : "#ffffff"
        readonly property color content: root.dark ? "#1e1e1e" : "#ffffff"
        readonly property color sidebar: root.dark ? "#262628" : "#f2f2f7"
        readonly property color panel: root.dark ? "#242426" : "#f7f7f9"
        readonly property color toolbar: root.dark ? "#1e1e1e" : "#ffffff"
        readonly property color viewerBg: root.dark ? "#161616" : "#f5f5f7"
        readonly property color tile: root.dark ? "#2a2a2c" : "#ebebef"
        readonly property color separator: root.dark ? "#3a3a3c" : "#e5e5ea"
        readonly property color selection: root.dark ? "#3a3a3d" : "#dcdce1"
        readonly property color hover: root.dark ? "#2e2e30" : "#e8e8ed"
        readonly property color text: root.dark ? "#f5f5f7" : "#1d1d1f"
        readonly property color muted: root.dark ? "#98989d" : "#86868b"
        readonly property color accent: "#0a7aff"
        readonly property color field: root.dark ? "#2c2c2e" : "#ececf0"
    }
    readonly property QtObject icons: Icons { }

    palette {
        window: theme.window
        windowText: theme.text
        base: theme.field
        alternateBase: theme.panel
        text: theme.text
        button: theme.panel
        buttonText: theme.text
        highlight: theme.accent
        highlightedText: "#ffffff"
        placeholderText: theme.muted
        mid: theme.separator
        dark: theme.separator
        light: theme.panel
        toolTipBase: theme.panel
        toolTipText: theme.text
    }

    // ---- backend payloads ----------------------------------------------------------------
    readonly property var status: JSON.parse(library.status)
    readonly property var pageData: JSON.parse(library.page)
    readonly property var datesData: JSON.parse(library.dates)
    readonly property var current: library.current.length ? JSON.parse(library.current) : null
    readonly property var peopleData: JSON.parse(library.people).people
    readonly property var facesData: JSON.parse(library.faces).faces
    readonly property var albumsData: JSON.parse(library.albums).albums
    readonly property var rootsData: JSON.parse(library.roots).roots
    readonly property var filterData: JSON.parse(library.filter)
    readonly property var suggestionData: JSON.parse(library.suggestion)
    readonly property var statsData: JSON.parse(library.stats)
    readonly property var candidatesData: JSON.parse(library.candidates)
    property var notSame: ({})   // "a:b" pairs the user said are different

    // ---- navigation state -----------------------------------------------------------------
    property string source: "all"          // sidebar key
    property string mode: "all"            // "years" | "months" | "days" | "all"
    readonly property bool viewing: current !== null
    property int zoom: 176
    // the viewer alone, over the whole screen (F / F11 / the toolbar button; Escape leaves)
    property bool fullscreen: false
    // Set the window state directly: a binding on `visibility` is overwritten the
    // moment the window manager reports the change, and then nothing leaves.
    onFullscreenChanged: {
        if (fullscreen) root.showFullScreen()
        else root.showNormal()
    }
    onVisibilityChanged: if (visibility !== Window.FullScreen && fullscreen) fullscreen = false
    onViewingChanged: if (!viewing) fullscreen = false
    // Escape / F / F11 leave full screen whatever has the focus.
    Shortcut { sequences: ["Escape", "F11"]; context: Qt.ApplicationShortcut; enabled: root.fullscreen && viewer.zoom === 1 && !viewer.infoOpen; onActivated: root.fullscreen = false }
    Shortcut { sequence: "F"; context: Qt.ApplicationShortcut; enabled: root.viewing; onActivated: root.fullscreen = !root.fullscreen }

    function pathsOf(ids) {
        const out = []
        for (const id of ids) {
            for (const it of pageData.items) if (it.id === id && it.path) { out.push(it.path); break }
            if (current && current.id === id && current.path && !out.includes(current.path)) out.push(current.path)
        }
        return out
    }
    function folderUrl(path) { return "file://" + path.substring(0, path.lastIndexOf("/")) }

    function pickSource(key) {
        source = key
        grid.clearSelection()
        library.closePhoto()
        if (key === "all") library.showAll()
        else if (key === "favorites") library.filterFavorites()
        else if (key === "imports") { const r = sidebar.importRoot; if (r) library.filterRoot(r.id) }
        else if (key.startsWith("album:")) library.filterAlbum(parseInt(key.substring(6)))
        else if (key.startsWith("kind:")) library.filterKind(key.substring(5))
        else if (key === "phone") { phonePanel.open(); source = "all" }
        else if (key === "peers") { peersPanel.open(); source = "all" }
        else if (key === "people") library.loadPeople()
        else if (key.startsWith("person:")) {
            const id = parseInt(key.substring(7))
            if (filterData.personId === id) pickSource("all")   // the same person again: back to the library
            else openPerson(id)
        }
    }

    function openPerson(id) { source = "person"; library.filterPerson(id); grid.clearSelection() }

    // A node of the date tree: keeps the person / album / favourites view, shows the photos.
    function pickDate(y, m, d) {
        library.closePhoto()
        grid.clearSelection()
        if (source === "people") source = "all"
        if (mode === "years" || mode === "months") mode = "days"
        library.filterDate(y, m, d)
    }

    function personName(id) {
        for (const p of peopleData) if (p.id === id) return p.name || "Unnamed Person"
        return "Person"
    }
    function albumName(id) {
        for (const a of albumsData) if (a.id === id) return a.name
        return "Album"
    }
    readonly property string headerTitle: {
        if (viewing) return "";
        if (source === "people") return "People"
        if (filterData.text) return "Results for “" + filterData.text + "”"
        if (source === "person") return personName(filterData.personId)
        if (filterData.favorites) return "Favorites"
        if (filterData.kind === "photo") return "Photos"
        if (filterData.kind === "screenshot") return "Screenshots"
        if (filterData.kind === "meme") return "Memes"
        if (filterData.albumId) return albumName(filterData.albumId)
        if (filterData.rootId) return "Imports"
        if (filterData.year) {
            if (filterData.day) return new Date(filterData.year, filterData.month - 1, filterData.day).toLocaleDateString(Qt.locale(), "d MMMM yyyy")
            if (filterData.month) return new Date(filterData.year, filterData.month - 1, 1).toLocaleDateString(Qt.locale(), "MMMM yyyy")
            return String(filterData.year)
        }
        return "Library"
    }

    // Years / Months tiles from the dates tree (+ the active date filter).
    readonly property var yearTiles: datesData.years.map(y => ({
        label: String(y.year), sublabel: y.count + (y.count === 1 ? " photo" : " photos"),
        cover: y.cover, year: y.year, month: 0 }))
    readonly property var monthTiles: {
        const out = []
        for (const y of datesData.years) {
            if (filterData.year && y.year !== filterData.year) continue
            for (const m of y.months)
                out.push({ label: new Date(y.year, m.month - 1, 1).toLocaleDateString(Qt.locale(), "MMMM"),
                           sublabel: y.year + "  ·  " + m.count + (m.count === 1 ? " photo" : " photos"),
                           cover: m.cover, year: y.year, month: m.month })
        }
        return out
    }

    FolderDialog {
        id: folderDialog
        title: "Add a folder to the library"
        onAccepted: library.addRoot(selectedFolder.toString())
    }

    // ---- layout -------------------------------------------------------------------------
    Item {
        id: shell
        anchors.fill: parent

        Sidebar {
            id: sidebar
            visible: !root.fullscreen
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.left: parent.left
            width: 236
            theme: root.theme
            icons: root.icons
            albums: root.albumsData
            roots: root.rootsData
            stats: root.statsData
            dates: root.datesData
            filter: root.filterData
            people: root.peopleData
            status: root.status
            selected: root.source === "person" ? "person:" + root.filterData.personId : root.source
            onPick: (key) => root.pickSource(key)
            onPickDate: (y, m, d) => root.pickDate(y, m, d)
        }

        // toolbar
        Rectangle {
            id: toolbar
            visible: !root.fullscreen
            anchors.top: parent.top
            anchors.left: sidebar.right
            anchors.right: parent.right
            height: 52
            color: theme.toolbar
            Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: theme.separator }

            component ToolIcon: ToolButton {
                property string icon_
                property bool active: false
                icon.source: icons.tint(icon_, active ? theme.accent : theme.text)
                icon.width: 18; icon.height: 18
                flat: true
                implicitWidth: 34; implicitHeight: 30
                background: Rectangle { radius: 6; color: parent.down || parent.active ? theme.hover : (parent.hovered ? theme.hover : "transparent") }
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 8

                // viewer: back + counter
                ToolIcon { visible: root.viewing; icon_: icons.chevronLeft; onClicked: library.closePhoto() }
                Label {
                    visible: root.viewing
                    text: root.viewing && viewer.currentIndex >= 0 ? (viewer.currentIndex + 1) + " of " + root.pageData.total : ""
                    color: theme.muted
                    font.pixelSize: 12
                }

                Label {
                    visible: !root.viewing
                    text: root.headerTitle
                    color: theme.text
                    font.pixelSize: 15
                    font.bold: true
                    elide: Text.ElideRight
                    Layout.maximumWidth: 260
                }
                Label {
                    visible: !root.viewing && root.source !== "people" && root.pageData.total > 0
                    text: root.pageData.total + (root.pageData.total === 1 ? " photo" : " photos")
                    color: theme.muted
                    font.pixelSize: 12
                }

                Item { Layout.fillWidth: true }

                // Years / Months / Days / All Photos
                Rectangle {
                    visible: !root.viewing && root.source !== "people"
                    height: 28
                    width: segRow.implicitWidth + 6
                    radius: 7
                    color: theme.field
                    Row {
                        id: segRow
                        anchors.centerIn: parent
                        spacing: 2
                        Repeater {
                            model: [["years", "Years"], ["months", "Months"], ["days", "Days"], ["all", "All Photos"]]
                            delegate: Rectangle {
                                required property var modelData
                                width: segLabel.implicitWidth + 22
                                height: 24
                                radius: 6
                                color: root.mode === modelData[0] ? theme.window : "transparent"
                                border.color: root.mode === modelData[0] ? theme.separator : "transparent"
                                Label { id: segLabel; anchors.centerIn: parent; text: modelData[1]; font.pixelSize: 12; color: theme.text }
                                TapHandler { onTapped: root.mode = modelData[0] }
                            }
                        }
                    }
                }

                Item { Layout.fillWidth: true }

                // zoom
                Image { visible: !root.viewing && root.source !== "people"; source: icons.tint(icons.zoomOut, theme.muted); sourceSize.width: 14; sourceSize.height: 14 }
                Slider {
                    visible: !root.viewing && root.source !== "people"
                    from: 72; to: 320; value: root.zoom
                    implicitWidth: 120
                    onMoved: root.zoom = value
                }
                Image { visible: !root.viewing && root.source !== "people"; source: icons.tint(icons.zoomIn, theme.muted); sourceSize.width: 14; sourceSize.height: 14 }

                // viewer actions
                ToolIcon {
                    visible: root.viewing
                    icon_: root.current && root.current.favorite ? icons.heartFill : icons.heart
                    active: root.current ? root.current.favorite === true : false
                    onClicked: if (root.current) library.toggleFavorite(root.current.id)
                }
                ToolIcon { visible: root.viewing; icon_: icons.info; active: viewer.infoOpen; onClicked: viewer.infoOpen = !viewer.infoOpen }
                ToolIcon { visible: root.viewing; icon_: icons.fullscreen; ToolTip.text: "Full screen (F)"; ToolTip.visible: hovered; onClicked: root.fullscreen = true }

                // grid actions
                ToolIcon {
                    visible: !root.viewing && grid.selectedIds().length > 0
                    icon_: icons.folderPlus
                    ToolTip.text: "Add to Album"; ToolTip.visible: hovered
                    onClicked: { albumDialog.photoIds = grid.selectedIds(); albumDialog.open() }
                }
                ToolIcon {
                    visible: !root.viewing && grid.selectedIds().length > 0
                    icon_: icons.heart
                    ToolTip.text: "Favorite"; ToolTip.visible: hovered
                    onClicked: { for (const id of grid.selectedIds()) library.toggleFavorite(id) }
                }
                ToolIcon {
                    visible: !root.viewing
                    icon_: icons.plus
                    ToolTip.text: "Add folder to the library"; ToolTip.visible: hovered
                    onClicked: folderDialog.open()
                }

                // search
                Rectangle {
                    visible: !root.viewing
                    width: 190; height: 28; radius: 7
                    color: theme.field
                    Image { x: 8; anchors.verticalCenter: parent.verticalCenter; source: icons.tint(icons.search, theme.muted); sourceSize.width: 14; sourceSize.height: 14 }
                    TextField {
                        id: searchField
                        anchors.fill: parent
                        anchors.leftMargin: 26
                        background: null
                        placeholderText: "Search"
                        font.pixelSize: 12
                        color: theme.text
                        onTextEdited: searchDebounce.restart()
                        onAccepted: { searchDebounce.stop(); root.search(text) }
                        Keys.onEscapePressed: { text = ""; searchDebounce.stop(); root.search("") }
                    }
                }
            }
        }

        // ---- content ---------------------------------------------------------------------
        Item {
            id: content
            anchors.top: root.fullscreen ? parent.top : toolbar.bottom
            anchors.left: root.fullscreen ? parent.left : sidebar.right
            anchors.right: parent.right
            anchors.bottom: parent.bottom

            TileGrid {
                anchors.fill: parent
                visible: !root.viewing && root.source !== "people" && root.mode === "years"
                theme: root.theme
                model: root.yearTiles
                tileWidth: 420; tileHeight: 280
                onPick: (y, m) => { library.filterDate(y, 0, 0); root.mode = "months" }
            }
            TileGrid {
                anchors.fill: parent
                visible: !root.viewing && root.source !== "people" && root.mode === "months"
                theme: root.theme
                model: root.monthTiles
                tileWidth: 300; tileHeight: 210
                onPick: (y, m) => { library.filterDate(y, m, 0); root.mode = "days" }
            }
            PhotoGrid {
                id: grid
                anchors.fill: parent
                visible: !root.viewing && root.source !== "people" && (root.mode === "days" || root.mode === "all")
                theme: root.theme
                icons: root.icons
                page: root.pageData
                mode: root.mode === "days" ? "days" : "all"
                cellSize: root.zoom
                onLoadMore: library.loadMore()
                onOpen: (id) => library.openPhoto(id)
                onFavorite: (id) => library.toggleFavorite(id)
                onContextMenu: (ids, path, fav) => { photoMenu.ids = ids; photoMenu.path = path; photoMenu.favorite = fav; photoMenu.popup() }
            }
            PeopleView {
                anchors.fill: parent
                visible: !root.viewing && root.source === "people"
                theme: root.theme
                icons: root.icons
                people: root.peopleData
                onOpen: (id) => root.openPerson(id)
                onRename: (id, name) => library.renamePerson(id, name)
                onNotAPerson: (id) => library.deletePerson(id)
                onRemovePerson: (id) => library.removePerson(id)
            }
            // a way out of full screen for the mouse, shown while the pointer is near the top
            Rectangle {
                z: 20
                visible: root.fullscreen
                anchors.top: parent.top
                anchors.right: parent.right
                anchors.margins: 12
                width: 36; height: 36; radius: 18
                color: Qt.rgba(0, 0, 0, exitHover.hovered ? 0.7 : 0.35)
                Image { anchors.centerIn: parent; source: icons.tint(icons.fullscreenExit, "white"); sourceSize.width: 18; sourceSize.height: 18 }
                HoverHandler { id: exitHover }
                TapHandler { onTapped: root.fullscreen = false }
                ToolTip.visible: exitHover.hovered
                ToolTip.text: "Leave full screen (Esc)"
            }
            PhotoViewer {
                id: viewer
                anchors.fill: parent
                visible: root.viewing
                theme: root.theme
                icons: root.icons
                photo: root.current
                items: root.pageData.items
                faces: root.facesData
                people: root.peopleData
                candidates: root.candidatesData
                region: JSON.parse(library.region)
                onLoadRegion: (id, x, y, w, h, px) => library.loadRegion(id, x, y, w, h, px)
                fullscreen: root.fullscreen
                onFullscreenToggle: root.fullscreen = !root.fullscreen
                onSetCover: (personId, faceId) => library.setPersonCover(personId, faceId)
                onContextMenu: (id, path, fav) => { photoMenu.ids = [id]; photoMenu.path = path; photoMenu.favorite = fav; photoMenu.popup() }
                onClosed: library.closePhoto()
                onOpenIndex: (i) => {
                    if (i < root.pageData.items.length) library.openPhoto(root.pageData.items[i].id)
                    if (i >= root.pageData.items.length - 8 && root.pageData.offset < root.pageData.total) library.loadMore()
                }
                onNameFace: (faceId, personId, name) => library.setFacePerson(faceId, personId, name)
                onNotAFace: (faceId) => library.deleteFace(faceId)
                onSetKind: (id, kind) => library.setKind(id, kind)
                onFavorite: (id) => library.toggleFavorite(id)
            }
        }
    } // shell

    PhotoMenu {
        id: photoMenu
        theme: root.theme
        onCopy: (ids) => library.copyPhotos(JSON.stringify(ids))
        onCopyPath: (ids) => library.copyText(root.pathsOf(ids).join("\n"))
        onOpenFolder: (path) => Qt.openUrlExternally(root.folderUrl(path))
        onToggleFavorite: (ids) => { for (const id of ids) library.toggleFavorite(id) }
        onAddToAlbum: (ids) => { albumDialog.photoIds = ids; albumDialog.open() }
        onSetKind: (ids, kind) => library.setKinds(JSON.stringify(ids), kind)
    }

    MergeSuggestion {
        id: mergeCard
        theme: root.theme
        icons: root.icons
        x: parent.width - width - 24
        y: 64
        onMerge: (from, into) => { library.mergePeople(from, into); library.dismissSuggestion() }
        onDifferent: (a, b) => { root.notSame[Math.min(a, b) + ":" + Math.max(a, b)] = true }
        onClosed: library.dismissSuggestion()
    }
    onSuggestionDataChanged: {
        const d = root.suggestionData
        if (!d.person || !d.candidates) { if (mergeCard.opened) mergeCard.close(); return }
        const left = d.candidates.filter(c => !root.notSame[Math.min(c.id, d.person.id) + ":" + Math.max(c.id, d.person.id)])
        if (!left.length) return
        mergeCard.data = { person: d.person, candidates: left }
        mergeCard.open()
    }

    AlbumDialog {
        id: albumDialog
        theme: root.theme
        albums: root.albumsData
        anchors.centerIn: parent
        width: 380
        onAddTo: (albumId, ids) => library.addToAlbum(albumId, JSON.stringify(ids))
        onCreateNew: (name, ids) => library.createAlbum(name, JSON.stringify(ids))
    }

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

    // Search, as you type: a person, an album, a year, "month year", "favorites",
    // "screenshots" / "memes" / "photos"; anything else looks for the words in the
    // file names and folders (the core's `q` filter).
    property string searchText: ""
    function search(text) {
        const q = text.trim().toLowerCase()
        searchText = q
        if (!q) { pickSource("all"); return }
        library.closePhoto()
        grid.clearSelection()
        for (const p of peopleData)
            if (p.name && p.name.toLowerCase().split(/\s+/).some(w => w.startsWith(q))) { openPerson(p.id); return }
        for (const a of albumsData)
            if (a.name.toLowerCase().startsWith(q)) { pickSource("album:" + a.id); return }
        if (["favorites", "favoritos", "favoritas"].includes(q)) { pickSource("favorites"); return }
        if (["screenshots", "screenshot", "prints", "capturas"].includes(q)) { pickSource("kind:screenshot"); return }
        if (["memes", "meme"].includes(q)) { pickSource("kind:meme"); return }
        if (["photos", "fotos", "photographs"].includes(q)) { pickSource("kind:photo"); return }
        const y = q.match(/^(\d{4})$/)
        if (y) { source = "all"; library.filterDate(parseInt(y[1]), 0, 0); if (mode === "years") mode = "months"; return }
        for (let m = 1; m <= 12; m++) {
            const name = new Date(2000, m - 1, 1).toLocaleDateString(Qt.locale(), "MMMM").toLowerCase()
            const hit = q.match(new RegExp("^" + name + "\\s+(\\d{4})$"))
            if (hit) { source = "all"; library.filterDate(parseInt(hit[1]), m, 0); if (mode === "years" || mode === "months") mode = "days"; return }
        }
        source = "search"
        if (mode === "years" || mode === "months") mode = "all"
        library.filterSearch(q)
    }
    Timer {   // a pause in typing runs the search
        id: searchDebounce
        interval: 300
        onTriggered: root.search(searchField.text)
    }

    // Headless capture: PW_SHOT=/path.png (+ PW_SHOT_OPEN=<id>, PW_SHOT_SEND=1 for the pairing
    // panel, PW_SHOT_VIEW=people|days|months|years).
    Timer {
        running: library.shotPath.length > 0 && library.shotOpenId > 0 && root.status.connected
        interval: 800
        onTriggered: { library.openPhoto(library.shotOpenId); viewer.infoOpen = true }
    }
    Timer {
        running: library.shotPath.length > 0 && library.shotSend && root.status.connected
        interval: 600
        onTriggered: phonePanel.open()
    }
    Timer {
        running: library.shotPath.length > 0 && library.shotView.length > 0
        interval: 400
        // one shot: the `running` binding re-arms the timer on every status change
        property bool applied: false
        onTriggered: {
            if (applied) return
            applied = true
            if (library.shotView === "people") root.pickSource("people")
            else if (library.shotView.startsWith("date:")) {          // date:YYYY[-M[-D]]
                const p = library.shotView.substring(5).split("-")
                root.pickDate(parseInt(p[0]), parseInt(p[1] || "0"), parseInt(p[2] || "0"))
            }
            else if (library.shotView.startsWith("person:")) root.pickSource(library.shotView)
            else if (library.shotView.startsWith("search:")) { searchField.text = library.shotView.substring(7); root.search(searchField.text) }
            else if (library.shotView.startsWith("name:")) {}
            else if (library.shotView === "fullscreen" || library.shotView === "fullscreen-exit") {}
            else if (library.shotView === "menu") {}
            else root.mode = library.shotView
        }
    }
    Timer {   // PW_SHOT_VIEW=name:<text> with PW_SHOT_OPEN: the naming popup with <text> typed
        running: library.shotPath.length > 0 && library.shotView.startsWith("name:") && root.viewing
        interval: 1500
        onTriggered: viewer.openNamer(library.shotView.substring(5))
    }
    Timer {   // PW_SHOT_VIEW=fullscreen with PW_SHOT_OPEN: the viewer over the whole window, zoomed in a bit
        running: library.shotPath.length > 0 && (library.shotView === "fullscreen" || library.shotView === "fullscreen-exit") && root.viewing
        interval: 1200
        property bool applied: false   // the running binding re-arms this timer on every status change
        onTriggered: { if (applied) return; applied = true; root.fullscreen = true; viewer.setZoom(1.6) }
    }
    Timer {   // PW_SHOT_VIEW=fullscreen-exit: …and out again, the way Escape does it
        running: library.shotPath.length > 0 && library.shotView === "fullscreen-exit" && root.fullscreen
        interval: 1000
        property bool applied: false
        onTriggered: { if (applied) return; applied = true; viewer.resetZoom(); root.fullscreen = false; console.log("shot: left full screen, visibility", root.visibility, "sidebar", sidebar.visible) }
    }
    Timer {   // PW_SHOT_VIEW=menu: the context menu over the first photo
        running: library.shotPath.length > 0 && library.shotView === "menu" && root.pageData.items.length > 0
        interval: 1500
        onTriggered: { const it = root.pageData.items[0]; grid.selectOnly(it.id); photoMenu.ids = [it.id]; photoMenu.path = it.path || ""; photoMenu.popup(grid, 120, 120) }
    }
    Timer {
        running: library.shotPath.length > 0
        interval: 3500
        onTriggered: (library.shotSend ? phonePanel.body : library.shotView.startsWith("name:") ? viewer.namerBody : shell).grabToImage(function (r) {
            r.saveToFile(library.shotPath)
            console.log("shot saved to", library.shotPath, "items:", root.pageData.items.length, "source", root.source, "filter", library.filter)
            library.quit()
        })
    }

    Component.onCompleted: library.loadDates()
}
