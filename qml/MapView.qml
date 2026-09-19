import QtQuick
import QtQuick.Controls
import QtLocation
import QtPositioning

// A map of the library's places. Loaded on demand (via a Loader in PlacesView),
// so `import QtLocation` only resolves when the system qt6-location package is
// present — the rest of the app is unaffected when it isn't.
//
// Pins are added imperatively: MapItemView.model requires a QAbstractItemModel,
// which the DSide binding has no path for, so we take the documented createObject
// + Map.addMapItem route on the `mapReady` signal (adding items before the map is
// ready silently drops them). Coordinates are built in QML from plain numbers via
// QtPositioning.coordinate(), so no geo type crosses into D. — see the DSide agent's
// notes (qt-dlang-gen), 2026-09-19.
Item {
    id: view
    required property QtObject theme
    property var places: []          // [{place, country, count, cover, lat, lon}]
    signal open(string place, string country)

    Rectangle { anchors.fill: parent; color: theme.content }

    Plugin {
        id: osm
        name: "osm"
        // Use OpenStreetMap's own free tile servers. Without this the plugin fetches a
        // provider list from maps.qt.io, which now points at key-requiring services — hence
        // the "API key" prompt. Disabling it falls back to the built-in free OSM providers.
        PluginParameter { name: "osm.mapping.providersrepository.disabled"; value: true }
        // OSM's tile policy wants a real User-Agent identifying the app.
        PluginParameter { name: "osm.useragent"; value: "photo-wagon (local-first photo manager)" }
    }

    Map {
        id: map
        anchors.fill: parent
        plugin: osm                              // write-once — set declaratively
        center: QtPositioning.coordinate(20, 0)
        zoomLevel: 2
        // Qt6 has no onMapReady signal; the map exposes a mapReady property instead.
        onMapReadyChanged: if (map.mapReady) view.rebuildPins()
    }

    Component {
        id: pinComponent
        MapQuickItem {
            id: pin
            property string place: ""
            property string country: ""
            property int count: 0
            anchorPoint.x: dot.width / 2
            anchorPoint.y: dot.height / 2
            sourceItem: Item {
                width: 18; height: 18
                Rectangle {
                    id: dot
                    anchors.centerIn: parent
                    width: 16; height: 16; radius: 8
                    color: theme.accent
                    border.color: "white"; border.width: 2
                    HoverHandler { id: ph }
                    TapHandler { onTapped: view.open(pin.place, pin.country) }
                }
                Rectangle {
                    visible: ph.hovered
                    anchors.bottom: dot.top
                    anchors.horizontalCenter: dot.horizontalCenter
                    anchors.bottomMargin: 4
                    color: theme.panel
                    border.color: theme.separator; border.width: 1
                    radius: 4
                    width: lbl.implicitWidth + 12; height: lbl.implicitHeight + 6
                    Label {
                        id: lbl
                        anchors.centerIn: parent
                        text: pin.place + (pin.count ? "  ·  " + pin.count : "")
                        color: theme.text
                        font.pixelSize: 11
                    }
                }
            }
        }
    }

    // Rebuild all pins and frame them. Called on mapReady and whenever places change.
    function rebuildPins() {
        if (!map.mapReady)
            return;
        map.clearMapItems();
        var n = 0, minLat = 90, maxLat = -90, minLon = 180, maxLon = -180;
        for (var i = 0; i < places.length; i++) {
            var p = places[i];
            if (p.lat === undefined || p.lon === undefined || p.lat === null || p.lon === null)
                continue;
            var o = pinComponent.createObject(map, {
                coordinate: QtPositioning.coordinate(p.lat, p.lon),
                place: p.place, country: p.country || "", count: p.count || 0
            });
            if (o) {
                map.addMapItem(o);
                n++;
                minLat = Math.min(minLat, p.lat); maxLat = Math.max(maxLat, p.lat);
                minLon = Math.min(minLon, p.lon); maxLon = Math.max(maxLon, p.lon);
            }
        }
        if (n === 1)
            { map.center = QtPositioning.coordinate(minLat, minLon); map.zoomLevel = 9; }
        else if (n > 1)
            { map.center = QtPositioning.coordinate((minLat + maxLat) / 2, (minLon + maxLon) / 2); map.zoomLevel = 3; }
    }

    onPlacesChanged: rebuildPins()

    // Empty state: no placed photos yet.
    Column {
        visible: view.places.length === 0
        anchors.centerIn: parent
        spacing: 8
        width: Math.min(420, parent.width - 40)
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: "No places to map yet"
            color: theme.text; font.pixelSize: 16; font.bold: true
        }
        Label {
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: "Photos with a GPS position appear here; for the rest, use “Set Place…” and the city is placed by name."
            color: theme.muted; font.pixelSize: 13
        }
    }
}
