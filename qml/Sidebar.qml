import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// The source list on the left, as in Photos: Library, Favorites, People,
// Imports, then the albums, then the devices.
Rectangle {
    id: sidebar
    required property QtObject theme
    required property QtObject icons
    property var albums: []
    property var roots: []
    /// "all" | "favorites" | "people" | "imports" | "album:<id>" | "phone" | "peers"
    property string selected: "all"

    signal pick(string key)

    color: theme.sidebar

    readonly property var importRoot: {
        for (const r of roots) if (r.path.endsWith("/imports")) return r
        return null
    }

    component SectionHeader: Label {
        required property string title
        text: title
        color: theme.muted
        font.pixelSize: 11
        font.bold: true
        leftPadding: 16
        topPadding: 14
        bottomPadding: 4
    }

    component Row: Item {
        id: row
        required property string key
        required property string title
        required property string icon
        property string detail: ""
        width: list.width
        height: 30
        readonly property bool active: sidebar.selected === key
        Rectangle {
            anchors.fill: parent
            anchors.leftMargin: 8
            anchors.rightMargin: 8
            radius: 6
            color: row.active ? theme.selection : (hover.hovered ? theme.hover : "transparent")
        }
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 18
            anchors.rightMargin: 16
            spacing: 8
            Image {
                source: icons.tint(row.icon, row.active ? theme.accent : theme.accent)
                sourceSize.width: 18
                sourceSize.height: 18
                width: 18
                height: 18
                smooth: true
            }
            Label {
                text: row.title
                color: theme.text
                font.pixelSize: 13
                elide: Text.ElideRight
                Layout.fillWidth: true
            }
            Label {
                visible: row.detail.length > 0
                text: row.detail
                color: theme.muted
                font.pixelSize: 12
            }
        }
        HoverHandler { id: hover }
        TapHandler { onTapped: sidebar.pick(row.key) }
    }

    ListView {
        id: list
        anchors.fill: parent
        anchors.topMargin: 8
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: ObjectModel {
            SectionHeader { title: "Library" }
            Row { key: "all"; title: "Library"; icon: icons.photos }
            Row { key: "favorites"; title: "Favorites"; icon: icons.heart }
            Row { key: "people"; title: "People"; icon: icons.people }
            Row {
                key: "imports"; title: "Imports"; icon: icons.imports
                visible: sidebar.importRoot !== null
                height: visible ? 30 : 0
                detail: sidebar.importRoot ? String(sidebar.importRoot.photos) : ""
            }
            SectionHeader { title: "Albums"; visible: sidebar.albums.length > 0; height: visible ? implicitHeight : 0 }
            Repeater {
                model: sidebar.albums
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
        }
    }

    Rectangle {
        anchors.right: parent.right
        width: 1
        height: parent.height
        color: theme.separator
    }
}
