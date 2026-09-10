import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// People: round portraits with names, the unnamed ones below with "+ Name".
// Double-click or the "Name" link renames; clicking a person opens their photos.
Item {
    id: view
    required property QtObject theme
    required property QtObject icons
    property var people: []

    signal open(int personId)
    signal rename(int personId, string name)
    signal notAPerson(int personId)

    /// Automatic groups this small stay behind "Show more" (mostly strangers and mistakes).
    property int minUnnamedFaces: 3
    property bool showAllUnnamed: false

    Rectangle { anchors.fill: parent; color: theme.content }

    readonly property var named: people.filter(p => p.name)
    readonly property var unnamedAll: people.filter(p => !p.name)
    readonly property var unnamed: showAllUnnamed ? unnamedAll : unnamedAll.filter(p => p.faces >= minUnnamedFaces)
    readonly property int hiddenUnnamed: unnamedAll.length - unnamed.length

    component Portrait: Item {
        id: portrait
        required property var person
        property int size: 148
        width: size + 20
        height: size + 46
        Item {
            id: circle
            width: portrait.size; height: portrait.size
            anchors.horizontalCenter: parent.horizontalCenter
            Image {
                anchors.fill: parent
                source: portrait.person.coverUrl || ""
                fillMode: Image.PreserveAspectCrop
                sourceSize.width: 300; sourceSize.height: 300
                asynchronous: true
                smooth: true
            }
            Image { // round mask in the background colour
                anchors.fill: parent
                source: icons.ringMask(theme.content)
                sourceSize.width: portrait.size
                sourceSize.height: portrait.size
                smooth: true
            }
            Rectangle {
                anchors.fill: parent
                radius: width / 2
                color: "transparent"
                border.color: hover.hovered ? theme.accent : theme.separator
                border.width: hover.hovered ? 2 : 1
            }
            HoverHandler { id: hover }
            TapHandler {
                onTapped: view.open(portrait.person.id)
                onDoubleTapped: portrait.edit()
            }
            // "not a person" for automatic groups
            Rectangle {
                visible: hover.hovered && !portrait.person.name
                anchors.top: parent.top
                anchors.right: parent.right
                width: 24; height: 24; radius: 12
                color: theme.panel
                border.color: theme.separator
                Image { anchors.centerIn: parent; source: icons.tint(icons.close, theme.text); sourceSize.width: 12; sourceSize.height: 12 }
                HoverHandler { id: closeHover }
                TapHandler { onTapped: view.notAPerson(portrait.person.id) }
                ToolTip.visible: closeHover.hovered
                ToolTip.text: "Not a person"
            }
        }
        Label {
            id: nameLabel
            anchors.top: circle.bottom
            anchors.topMargin: 8
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !editor.visible
            text: portrait.person.name || "+ Name"
            color: portrait.person.name ? theme.text : theme.accent
            font.pixelSize: 13
            font.bold: portrait.person.name ? true : false
            width: parent.width - 8
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
            TapHandler { onTapped: portrait.person.name ? view.open(portrait.person.id) : portrait.edit() }
        }
        Label {
            anchors.top: nameLabel.bottom
            anchors.topMargin: 1
            anchors.horizontalCenter: parent.horizontalCenter
            visible: !editor.visible
            text: portrait.person.faces + (portrait.person.faces === 1 ? " photo" : " photos")
            color: theme.muted
            font.pixelSize: 11
        }
        TextField {
            id: editor
            anchors.top: circle.bottom
            anchors.topMargin: 4
            anchors.horizontalCenter: parent.horizontalCenter
            width: parent.width - 8
            visible: false
            placeholderText: "Name"
            font.pixelSize: 13
            horizontalAlignment: Text.AlignHCenter
            onAccepted: { view.rename(portrait.person.id, text); visible = false }
            onActiveFocusChanged: if (!activeFocus) visible = false
            Keys.onEscapePressed: visible = false
        }
        function edit() { editor.text = portrait.person.name || ""; editor.visible = true; editor.forceActiveFocus() }
    }

    Flickable {
        anchors.fill: parent
        contentHeight: column.height + 40
        clip: true
        ScrollBar.vertical: ScrollBar { }
        Column {
            id: column
            x: 24
            y: 16
            width: parent.width - 48
            spacing: 8
            Label { text: "People"; color: theme.text; font.pixelSize: 26; font.bold: true; bottomPadding: 8 }
            Flow {
                width: parent.width
                spacing: 12
                Repeater {
                    model: view.named
                    delegate: Portrait { required property var modelData; person: modelData }
                }
            }
            Label {
                visible: view.unnamed.length > 0
                text: "Unnamed People"
                color: theme.text
                font.pixelSize: 17
                font.bold: true
                topPadding: 24
                bottomPadding: 4
            }
            Label {
                visible: view.unnamed.length > 0
                text: "Faces that appear in your photos. Add a name to keep track of someone."
                color: theme.muted
                font.pixelSize: 12
                bottomPadding: 8
            }
            Flow {
                width: parent.width
                spacing: 10
                Repeater {
                    model: view.unnamed
                    delegate: Portrait { required property var modelData; person: modelData; size: 96 }
                }
            }
            Label {
                visible: view.hiddenUnnamed > 0 || view.showAllUnnamed
                text: view.showAllUnnamed ? "Show fewer" : "Show " + view.hiddenUnnamed + " more (seen only once or twice)"
                color: theme.accent
                font.pixelSize: 13
                topPadding: 8
                TapHandler { onTapped: view.showAllUnnamed = !view.showAllUnnamed }
            }
            Label {
                visible: view.people.length === 0
                text: "No faces found yet. People appear here after the library is scanned."
                color: theme.muted
                font.pixelSize: 13
            }
        }
    }
}
