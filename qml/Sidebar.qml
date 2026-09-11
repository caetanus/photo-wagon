import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The source list on the left, as in Photos: Library, Favorites, People,
// Imports, Places; then the years → months → days tree, the named people, the places, the media
// types, the albums and the devices. The connection / indexing status lives
// in the footer, always visible.
Rectangle {
    id: sidebar
    required property QtObject theme
    required property QtObject icons
    property var albums: []
    property var roots: []
    property var stats: ({ total: 0, kinds: {} })
    /// parsed library.dates: {years: [{year, count, months: [{month, count, days: [{day, count}]}]}]}
    property var dates: ({ years: [] })
    /// parsed library.filter
    property var filter: ({ year: 0, month: 0, day: 0, personId: 0 })
    /// parsed library.people.people; only the named ones are listed
    property var people: []
    /// parsed library.places.places: [{place, country, count, cover}]
    property var places: []
    /// parsed library.tags: {scene: [{tag, count, cover}], mood: […], weather: […], holiday: […]}
    property var tags: ({ scene: [], mood: [], weather: [], holiday: [] })
    /// parsed library.status
    property var status: ({ connected: false, indexing: false, text: "" })
    /// "all" | "favorites" | "people" | "person:<id>" | "places" | "place:<name>|<country>" | "scene:<name>" | "mood:<name>" | "weather:<name>" | "holiday:<name>" | "imports" | "album:<id>" | "kind:<k>" | "phone" | "peers"
    property string selected: "all"

    signal pick(string key)
    /// Right-click on a person row.
    signal personMenu(var person)
    /// A node of the date tree (0 = any); the same node again clears the date filter.
    signal pickDate(int year, int month, int day)

    color: theme.sidebar

    readonly property var importRoot: {
        for (const r of roots) if (r.path.endsWith("/imports")) return r
        return null
    }
    readonly property var namedPeople: people.filter(p => p.name)

    // the open branches of the tree follow the selection, and can be toggled by hand
    property int expandedYear: 0
    property int expandedMonth: 0
    onFilterChanged: {
        if (filter.year) { expandedYear = filter.year; expandedMonth = filter.month }
    }

    function dateActive(y, m, d) { return filter.year === y && filter.month === m && filter.day === d }
    function tapDate(y, m, d) {
        if (dateActive(y, m, d)) pickDate(0, 0, 0)
        else pickDate(y, m, d)
        if (y) { expandedYear = y; if (m) expandedMonth = m }
    }
    function monthName(m) { return new Date(2000, m - 1, 1).toLocaleDateString(Qt.locale(), "MMMM") }

    // Which sections are folded (the user's choice, kept for the session).
    property bool datesOpen: true
    property bool peopleOpen: true
    property bool placesOpen: true
    property var tagsOpen: ({ scene: true, mood: true, weather: true, holiday: true })
    function toggleTags(g) { const o = Object.assign({}, tagsOpen); o[g] = !o[g]; tagsOpen = o }
    property bool albumsOpen: true

    component SectionHeader: Item {
        required property string title
        property bool collapsible: false
        property bool open: true
        signal toggled()
        width: list.width
        height: 30
        Label {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 4
            text: parent.title
            color: theme.muted
            font.pixelSize: 11
            font.bold: true
        }
        Image {
            visible: parent.collapsible
            anchors.right: parent.right
            anchors.rightMargin: 14
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 6
            source: icons.tint(icons.chevronRight, theme.muted)
            sourceSize.width: 11; sourceSize.height: 11
            rotation: parent.open ? 90 : 0
            opacity: headerHover.hovered || !parent.open ? 1 : 0.5
            Behavior on rotation { NumberAnimation { duration: 120 } }
        }
        HoverHandler { id: headerHover }
        TapHandler { enabled: parent.collapsible; onTapped: parent.toggled() }
    }

    // One line of the list: a highlight, an icon or a portrait, a title and a detail.
    component Line: Item {
        id: line
        property bool active: false
        property string title: ""
        property string detail: ""
        property string icon: ""
        property string portrait: ""
        property int indent: 0
        property bool expandable: false
        property bool expanded: false
        signal tapped()
        signal toggled()
        width: list.width
        height: 28
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            radius: 6
            color: line.active ? theme.selection : (hover.hovered ? theme.hover : "transparent")
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 18 + line.indent
            anchors.rightMargin: 16
            spacing: 8
            // disclosure chevron for the tree
            Item {
                visible: line.expandable
                width: 12; height: 12
                Image {
                    anchors.centerIn: parent
                    source: icons.tint(icons.chevronRight, theme.muted)
                    sourceSize.width: 12; sourceSize.height: 12
                    rotation: line.expanded ? 90 : 0
                    Behavior on rotation { NumberAnimation { duration: 120 } }
                }
                TapHandler { onTapped: line.toggled() }
            }
            Image {
                visible: line.icon.length > 0
                source: line.icon.length ? icons.tint(line.icon, theme.accent) : ""
                sourceSize.width: 18; sourceSize.height: 18
                width: 18; height: 18
                smooth: true
            }
            Item {
                visible: line.portrait.length > 0
                width: 20; height: 20
                Image {
                    anchors.fill: parent
                    source: line.portrait
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 40; sourceSize.height: 40
                    asynchronous: true
                }
                Image {
                    anchors.fill: parent
                    source: icons.ringMask(line.active ? theme.selection : (hover.hovered ? theme.hover : theme.sidebar))
                    sourceSize.width: 20; sourceSize.height: 20
                }
            }
            Label {
                text: line.title
                color: theme.text
                font.pixelSize: 13
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Label {
                visible: line.detail.length > 0
                text: line.detail
                color: theme.muted
                font.pixelSize: 12
            }
        }
        HoverHandler { id: hover }
        TapHandler { onTapped: line.tapped() }
    }

    component Row: Line {
        required property string key
        active: sidebar.selected === key
        onTapped: sidebar.pick(key)
    }
    component PersonRow: Row {
        required property var modelData
        TapHandler { acceptedButtons: Qt.RightButton; onTapped: sidebar.personMenu(modelData) }
    }

    // A Column, not a ListView over an ObjectModel: the Repeaters of the tree
    // and the people need a positioner as their parent.
    Flickable {
        id: flick
        anchors.top: parent.top
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.topMargin: 8
        contentHeight: list.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        ScrollBar.vertical: ScrollBar { }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse
            onWheel: (ev) => { flick.contentY = Math.max(0, Math.min(Math.max(0, flick.contentHeight - flick.height), flick.contentY - ev.angleDelta.y * 2.5)); ev.accepted = true }
        }
        Column {
            id: list
            width: flick.width
            SectionHeader { title: "Library" }
            // the library timeline is photographs (screenshots and memes have their own rows below)
            Row { key: "all"; title: "Library"; icon: icons.photos; detail: sidebar.stats.kinds.photo ? String(sidebar.stats.kinds.photo) : (sidebar.stats.total ? String(sidebar.stats.total) : "") }
            Row { key: "favorites"; title: "Favorites"; icon: icons.heart }
            Row { key: "people"; title: "People"; icon: icons.people; detail: sidebar.namedPeople.length ? String(sidebar.namedPeople.length) : "" }
            Row { key: "places"; title: "Places"; icon: icons.pin; detail: sidebar.places.length ? String(sidebar.places.length) : "" }
            Row {
                key: "imports"; title: "Imports"; icon: icons.imports
                visible: sidebar.importRoot !== null
                detail: sidebar.importRoot ? String(sidebar.importRoot.photos) : ""
            }

            // ---- years → months → days ------------------------------------------------
            SectionHeader {
                title: "Dates"; visible: sidebar.dates.years.length > 0
                collapsible: true; open: sidebar.datesOpen
                onToggled: sidebar.datesOpen = !sidebar.datesOpen
            }
            Repeater {
                model: sidebar.datesOpen ? sidebar.dates.years : []
                delegate: Column {
                    id: yearNode
                    required property var modelData
                    readonly property int year: modelData.year
                    readonly property bool expanded: sidebar.expandedYear === year
                    width: list.width
                    Line {
                        title: String(yearNode.year)
                        detail: String(yearNode.modelData.count)
                        expandable: true
                        expanded: yearNode.expanded
                        active: sidebar.dateActive(yearNode.year, 0, 0)
                        onTapped: sidebar.tapDate(yearNode.year, 0, 0)
                        onToggled: sidebar.expandedYear = yearNode.expanded ? 0 : yearNode.year
                    }
                    Repeater {
                        model: yearNode.expanded ? yearNode.modelData.months : []
                        delegate: Column {
                            id: monthNode
                            required property var modelData
                            readonly property int month: modelData.month
                            readonly property bool expanded: yearNode.expanded && sidebar.expandedMonth === month
                            width: list.width
                            Line {
                                indent: 14
                                title: sidebar.monthName(monthNode.month)
                                detail: String(monthNode.modelData.count)
                                expandable: true
                                expanded: monthNode.expanded
                                active: sidebar.dateActive(yearNode.year, monthNode.month, 0)
                                onTapped: sidebar.tapDate(yearNode.year, monthNode.month, 0)
                                onToggled: sidebar.expandedMonth = monthNode.expanded ? 0 : monthNode.month
                            }
                            Flow {
                                visible: monthNode.expanded
                                width: parent.width
                                leftPadding: 44
                                rightPadding: 12
                                topPadding: 2
                                bottomPadding: 6
                                spacing: 3
                                Repeater {
                                    model: monthNode.expanded ? monthNode.modelData.days : []
                                    delegate: Rectangle {
                                        id: dayNode
                                        required property var modelData
                                        readonly property bool active: sidebar.dateActive(yearNode.year, monthNode.month, modelData.day)
                                        width: 26; height: 22; radius: 5
                                        color: active ? theme.accent : (dayHover.hovered ? theme.hover : "transparent")
                                        Label {
                                            anchors.centerIn: parent
                                            text: String(dayNode.modelData.day)
                                            font.pixelSize: 11
                                            color: dayNode.active ? "white" : theme.text
                                        }
                                        HoverHandler { id: dayHover }
                                        TapHandler { onTapped: sidebar.tapDate(yearNode.year, monthNode.month, dayNode.modelData.day) }
                                        ToolTip.visible: dayHover.hovered
                                        ToolTip.delay: 600
                                        ToolTip.text: dayNode.modelData.count + (dayNode.modelData.count === 1 ? " photo" : " photos")
                                    }
                                }
                            }
                        }
                    }
                }
            }

            // ---- named people ------------------------------------------------------------
            SectionHeader {
                title: "People"; visible: sidebar.namedPeople.length > 0
                collapsible: true; open: sidebar.peopleOpen
                onToggled: sidebar.peopleOpen = !sidebar.peopleOpen
            }
            Repeater {
                model: sidebar.peopleOpen ? sidebar.namedPeople : []
                delegate: PersonRow {
                    key: "person:" + modelData.id
                    title: modelData.name
                    portrait: modelData.coverUrl || ""
                    icon: modelData.coverUrl ? "" : icons.person
                    detail: String(modelData.faces)
                }
            }

            // ---- places ------------------------------------------------------------------
            SectionHeader {
                title: "Places"; visible: sidebar.places.length > 0
                collapsible: true; open: sidebar.placesOpen
                onToggled: sidebar.placesOpen = !sidebar.placesOpen
            }
            Repeater {
                model: sidebar.placesOpen ? sidebar.places : []
                delegate: Row {
                    required property var modelData
                    key: "place:" + modelData.place + "|" + (modelData.country || "")
                    title: modelData.place
                    icon: icons.pin
                    detail: String(modelData.count)
                }
            }

            // ---- scenes, moods, weather, holidays (CLIP zero-shot tags + the calendar) -----------
            Repeater {
                model: [ { group: "scene", title: "Scenes", icon: icons.tag }, { group: "mood", title: "Moods", icon: icons.mood },
                         { group: "weather", title: "Weather", icon: icons.weather }, { group: "holiday", title: "Holidays", icon: icons.holiday } ]
                delegate: Column {
                    id: tagSection
                    required property var modelData
                    width: list.width
                    readonly property var items: sidebar.tags[modelData.group] || []
                    readonly property bool open: sidebar.tagsOpen[modelData.group] !== false
                    SectionHeader {
                        title: tagSection.modelData.title; visible: tagSection.items.length > 0
                        collapsible: true; open: tagSection.open
                        onToggled: sidebar.toggleTags(tagSection.modelData.group)
                    }
                    Repeater {
                        model: tagSection.open ? tagSection.items : []
                        delegate: Row {
                            required property var modelData
                            key: tagSection.modelData.group + ":" + modelData.tag
                            title: modelData.tag
                            icon: tagSection.modelData.icon
                            detail: String(modelData.count)
                        }
                    }
                }
            }

            SectionHeader { title: "Media Types" }
            Row { key: "kind:photo"; title: "Photos"; icon: icons.photos; detail: String(sidebar.stats.kinds.photo || 0) }
            Row { key: "kind:screenshot"; title: "Screenshots"; icon: icons.screenshot; detail: String(sidebar.stats.kinds.screenshot || 0) }
            Row { key: "kind:meme"; title: "Memes"; icon: icons.meme; detail: String(sidebar.stats.kinds.meme || 0) }

            SectionHeader {
                title: "Albums"; visible: sidebar.albums.length > 0
                collapsible: true; open: sidebar.albumsOpen
                onToggled: sidebar.albumsOpen = !sidebar.albumsOpen
            }
            Repeater {
                model: sidebar.albumsOpen ? sidebar.albums : []
                delegate: Row {
                    required property var modelData
                    key: "album:" + modelData.id
                    title: modelData.name
                    icon: icons.album
                    detail: String(modelData.photos)
                }
            }

            SectionHeader { title: "Devices" }
            Row { key: "phone"; title: "Phone"; icon: icons.phone }
            Row { key: "peers"; title: "Peers"; icon: icons.network }
            Item { width: 1; height: 12 }
        }
    }

    // ---- status footer: connection, indexing, the last message ----------------------
    Rectangle {
        id: footer
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 30
        color: theme.sidebar
        Rectangle { anchors.top: parent.top; width: parent.width; height: 1; color: theme.separator }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 10
            spacing: 8
            Rectangle {
                width: 8; height: 8; radius: 4
                color: sidebar.status.connected ? "#34c759" : "#ff3b30"
            }
            Label {
                text: sidebar.status.connected ? (sidebar.status.text || "connected") : (sidebar.status.text || "not connected")
                color: theme.muted
                font.pixelSize: 11
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            BusyIndicator {
                running: sidebar.status.indexing
                visible: running
                implicitWidth: 16
                implicitHeight: 16
            }
        }
        HoverHandler { id: footerHover }
        ToolTip.visible: footerHover.hovered && sidebar.status.text.length > 0
        ToolTip.text: sidebar.status.text
    }

    Rectangle {
        anchors.right: parent.right
        width: 1
        height: parent.height
        color: theme.separator
    }
}
