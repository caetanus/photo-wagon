import QtQuick
import QtQuick.Controls

// Places: one card per city with its newest photo, the name, the country and
// the count. Clicking opens the photos taken there.
Item {
    id: view
    required property QtObject theme
    required property QtObject icons
    /// [{place, country, count, cover}]
    property var places: []

    signal open(string place, string country)
    property int mode: 0   // 0 = grid of cards, 1 = map

    Rectangle { anchors.fill: parent; color: theme.content }

    // grid / map toggle (top-right)
    Row {
        id: modeBar
        z: 3
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 10
        spacing: 6
        Repeater {
            model: [ { k: 0, t: "Grid" }, { k: 1, t: "Map" } ]
            delegate: Rectangle {
                required property var modelData
                width: tlbl.implicitWidth + 20; height: 28; radius: 6
                color: view.mode === modelData.k ? theme.accent : theme.panel
                border.color: theme.separator; border.width: 1
                Label { id: tlbl; anchors.centerIn: parent; text: modelData.t
                        color: view.mode === modelData.k ? "white" : theme.text; font.pixelSize: 12 }
                TapHandler { onTapped: view.mode = modelData.k }
            }
        }
    }

    GridView {
        id: grid
        anchors.fill: parent
        anchors.margins: 12
        anchors.topMargin: 46
        visible: view.mode === 0
        clip: true
        cellWidth: Math.floor(width / Math.max(1, Math.floor(width / 232)))
        cellHeight: 244
        model: view.places
        ScrollBar.vertical: ScrollBar { }
        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: (ev) => { const dy = ev.pixelDelta.y !== 0 ? ev.pixelDelta.y * 3 : ev.angleDelta.y / 120 * grid.cellHeight; grid.contentY = Math.max(0, Math.min(Math.max(0, grid.contentHeight - grid.height), grid.contentY - dy)); ev.accepted = true }
        }
        delegate: Item {
            id: card
            required property var modelData
            width: grid.cellWidth
            height: grid.cellHeight
            Rectangle {
                id: frame
                anchors.fill: parent
                anchors.margins: 6
                radius: 10
                color: theme.panel
                border.color: hover.hovered ? theme.accent : theme.separator
                border.width: hover.hovered ? 2 : 1
                clip: true
                Image {
                    id: cover
                    anchors.top: parent.top
                    anchors.left: parent.left
                    anchors.right: parent.right
                    height: parent.height - 58
                    source: card.modelData.cover || ""
                    fillMode: Image.PreserveAspectCrop
                    sourceSize.width: 460; sourceSize.height: 360
                    asynchronous: true
                    smooth: true
                }
                Image {   // a pin where there is no photo to show
                    visible: !card.modelData.cover
                    anchors.centerIn: cover
                    source: icons.tint(icons.pin, theme.muted)
                    sourceSize.width: 40; sourceSize.height: 40
                }
                Label {
                    id: name
                    anchors.top: cover.bottom
                    anchors.topMargin: 8
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 12; anchors.rightMargin: 12
                    text: card.modelData.place
                    color: theme.text
                    font.pixelSize: 14
                    font.bold: true
                    elide: Text.ElideRight
                }
                Label {
                    anchors.top: name.bottom
                    anchors.topMargin: 2
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 12; anchors.rightMargin: 12
                    text: (card.modelData.country ? card.modelData.country + "  ·  " : "")
                          + card.modelData.count + (card.modelData.count === 1 ? " photo" : " photos")
                    color: theme.muted
                    font.pixelSize: 12
                    elide: Text.ElideRight
                }
            }
            HoverHandler { id: hover }
            TapHandler { onTapped: view.open(card.modelData.place, card.modelData.country || "") }
        }
    }

    // Map mode: MapView.qml is loaded on demand so `import QtLocation` only
    // resolves when qt6-location is installed; setSource passes the required
    // properties at creation. If the module is absent, show an install hint.
    Loader {
        id: mapLoader
        anchors.fill: parent
        anchors.topMargin: 46
        active: view.mode === 1
        onActiveChanged: if (active) setSource("MapView.qml", { theme: view.theme, places: view.places })
        onLoaded: item.open.connect(view.open)
    }
    Connections {
        target: view
        function onPlacesChanged() { if (mapLoader.item) mapLoader.item.places = view.places }
    }
    Rectangle {
        anchors.fill: parent
        anchors.topMargin: 46
        visible: view.mode === 1 && mapLoader.status === Loader.Error
        color: theme.content
        Label {
            anchors.centerIn: parent
            width: Math.min(440, parent.width - 40)
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "The map needs the system QtLocation module.\nInstall it with:  sudo pacman -S qt6-location"
            color: theme.muted; font.pixelSize: 13
        }
    }

    // Nothing placed yet: say where places come from.
    Column {
        visible: view.places.length === 0 && view.mode === 0
        anchors.centerIn: parent
        spacing: 8
        width: Math.min(420, parent.width - 40)
        Image {
            anchors.horizontalCenter: parent.horizontalCenter
            source: icons.tint(icons.pin, theme.muted)
            sourceSize.width: 48; sourceSize.height: 48
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "No places yet"
            color: theme.text
            font.pixelSize: 16
            font.bold: true
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Photos with a GPS position are placed in the nearest city by themselves. For the others, select them and use “Set Place…” in the right-click menu."
            color: theme.muted
            font.pixelSize: 13
        }
    }
}
