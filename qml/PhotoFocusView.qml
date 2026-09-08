import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Full-size viewer over the grid. `photo` is the parsed library.current object
// (a Photo plus prev/next ids) or null.
Rectangle {
    id: viewer
    required property QtObject theme
    property var photo: null
    /// Phone: show "Send to computer" (enabled when a computer is reachable).
    property bool canSend: false
    property bool sendEnabled: false

    signal closed()
    signal send(int id)

    color: Qt.rgba(0, 0, 0, 0.94)
    focus: visible
    onVisibleChanged: if (visible) forceActiveFocus()

    Keys.onPressed: (event) => {
        if (event.key === Qt.Key_Escape) { viewer.closed(); event.accepted = true }
        else if (event.key === Qt.Key_Left) { library.prev(); event.accepted = true }
        else if (event.key === Qt.Key_Right || event.key === Qt.Key_Space) { library.next(); event.accepted = true }
    }

    // Swallow clicks so the grid underneath does not react.
    MouseArea { anchors.fill: parent; onClicked: viewer.closed() }

    Image {
        id: image
        anchors.fill: parent
        anchors.margins: 24
        anchors.bottomMargin: 72
        source: viewer.photo ? viewer.photo.fileUrl : ""
        asynchronous: true
        fillMode: Image.PreserveAspectFit
        autoTransform: true
        smooth: true
        mipmap: true
        MouseArea { anchors.fill: parent; onClicked: {} }
    }

    BusyIndicator {
        anchors.centerIn: image
        running: image.status === Image.Loading
        visible: running
    }

    RoundButton {
        text: "‹"
        font.pixelSize: 28
        width: 52; height: 52
        anchors.left: parent.left
        anchors.verticalCenter: image.verticalCenter
        anchors.leftMargin: 12
        enabled: viewer.photo && viewer.photo.prev !== null
        opacity: enabled ? 0.9 : 0.25
        onClicked: library.prev()
    }
    RoundButton {
        text: "›"
        font.pixelSize: 28
        width: 52; height: 52
        anchors.right: parent.right
        anchors.verticalCenter: image.verticalCenter
        anchors.rightMargin: 12
        enabled: viewer.photo && viewer.photo.next !== null
        opacity: enabled ? 0.9 : 0.25
        onClicked: library.next()
    }
    RoundButton {
        text: "✕"
        width: 40; height: 40
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 12
        onClicked: viewer.closed()
    }

    // Metadata strip.
    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        height: 56
        color: theme.panel
        border.color: theme.border
        RowLayout {
            anchors.fill: parent
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            spacing: 24
            Label {
                text: viewer.photo ? viewer.formatDate(viewer.photo.takenAt) : ""
                color: theme.text
                font.pixelSize: 14
            }
            Label {
                text: viewer.photo && viewer.photo.camera ? viewer.photo.camera : ""
                color: theme.muted
            }
            Label {
                text: viewer.photo ? viewer.photo.width + " × " + viewer.photo.height : ""
                color: theme.muted
            }
            Label {
                text: viewer.photo ? viewer.formatSize(viewer.photo.size) : ""
                color: theme.muted
            }
            Item { Layout.fillWidth: true }
            Button {
                visible: viewer.canSend
                enabled: viewer.sendEnabled && viewer.photo && !viewer.photo.sent
                text: viewer.photo && viewer.photo.sent ? "Sent" : "Send to computer"
                onClicked: viewer.send(viewer.photo.id)
            }
            Label {
                visible: !viewer.canSend
                text: viewer.photo ? viewer.photo.path : ""
                color: theme.muted
                elide: Text.ElideMiddle
                Layout.maximumWidth: 480
            }
        }
    }

    function formatDate(iso) {
        if (!iso) return "unknown date"
        const d = new Date(iso)
        return isNaN(d.getTime()) ? iso : d.toLocaleString(Qt.locale(), "yyyy-MM-dd  HH:mm")
    }

    function formatSize(bytes) {
        if (!bytes) return ""
        if (bytes > 1048576) return (bytes / 1048576).toFixed(1) + " MB"
        if (bytes > 1024) return Math.round(bytes / 1024) + " KB"
        return bytes + " B"
    }
}
