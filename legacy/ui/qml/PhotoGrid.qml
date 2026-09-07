import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Item {
    id: gridRoot

    property var photosFilesModel: []
    property int totalPhotosCount: 0
    property string libraryPath: ""
    property string currentSectionTitle: ""
    property bool showDateLabel: false
    property bool isMobile: false

    signal photoClicked(int flatIndex)
    signal visibleMonthChanged(string monthTitle)

    ListView {
        id: photosList
        anchors.fill: parent
        spacing: 16
        clip: true
        focus: true
        model: photosFilesModel
        flickDeceleration: 2200
        maximumFlickVelocity: 18000

        ScrollBar.vertical: ScrollBar {
            policy: ScrollBar.AsNeeded
        }

        function scrollToSection(sectionIndex) {
            photosList.positionViewAtIndex(sectionIndex, ListView.Beginning)
        }

        Component.onCompleted: {
            if (photosFilesModel.length > 0) {
                gridRoot.currentSectionTitle = photosFilesModel[0].title
                gridRoot.visibleMonthChanged(photosFilesModel[0].title)
            }
        }

        onContentYChanged: {
            // Sample at 1/4 of viewport height for better section detection
            var sampleY = photosList.contentY + photosList.height * 0.25
            var idx = photosList.indexAt(10, sampleY)
            if (idx < 0) {
                // Try at exact contentY
                idx = photosList.indexAt(10, photosList.contentY + 1)
            }
            if (idx < 0) idx = 0
            if (idx >= 0 && idx < photosFilesModel.length) {
                gridRoot.currentSectionTitle = photosFilesModel[idx].title
                gridRoot.visibleMonthChanged(photosFilesModel[idx].title)
            }
            gridRoot.showDateLabel = true
            dateLabelTimer.restart()
        }

        Timer {
            id: dateLabelTimer
            interval: 1200
            onTriggered: gridRoot.showDateLabel = false
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_PageDown) {
                photosList.contentY = Math.min(photosList.contentY + photosList.height * 0.9, photosList.contentHeight - photosList.height)
                event.accepted = true
            } else if (event.key === Qt.Key_PageUp) {
                photosList.contentY = Math.max(photosList.contentY - photosList.height * 0.9, 0)
                event.accepted = true
            } else if (event.key === Qt.Key_Down) {
                photosList.contentY = Math.min(photosList.contentY + Math.max(120, photosList.height * 0.16), photosList.contentHeight - photosList.height)
                event.accepted = true
            } else if (event.key === Qt.Key_Up) {
                photosList.contentY = Math.max(photosList.contentY - Math.max(120, photosList.height * 0.16), 0)
                event.accepted = true
            }
        }

        WheelHandler {
            acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
            onWheel: function(event) {
                var deltaY = event.pixelDelta.y !== 0 ? event.pixelDelta.y : event.angleDelta.y
                if (deltaY === 0)
                    return

                photosList.flick(0, -deltaY * 26)
                event.accepted = true
            }
        }

        delegate: Column {
            width: photosList.width
            spacing: 10

            RowLayout {
                width: parent.width
                spacing: 10

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: "#3a3a3c"
                }

                Label {
                    text: modelData.title
                    color: "#d1d1d6"
                    font.pixelSize: 17
                    font.bold: true
                }

                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 1
                    color: "#3a3a3c"
                }
            }

            Flow {
                width: parent.width
                spacing: 10

                Repeater {
                    model: modelData.items

                    delegate: Rectangle {
                        property int tileSize: gridRoot.isMobile ? (gridRoot.width - 20) : 170
                        width: tileSize
                        height: tileSize
                        radius: 12
                        color: "#2c2c2e"
                        clip: true

                        Image {
                            anchors.fill: parent
                            source: modelData.thumbUrl
                            sourceSize.width: gridRoot.isMobile ? 512 : 256
                            sourceSize.height: gridRoot.isMobile ? 512 : 256
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                        }

                        // Bottom overlay: subtitle + people
                        Rectangle {
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.bottom: parent.bottom
                            height: peopleLabel.visible ? 46 : 30
                            color: "#99000000"

                            Column {
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                anchors.leftMargin: 8
                                anchors.rightMargin: 8
                                spacing: 1

                                Label {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: modelData.subtitle
                                    color: "#f2f2f7"
                                    font.pixelSize: 12
                                }

                                Label {
                                    id: peopleLabel
                                    width: parent.width
                                    elide: Text.ElideRight
                                    text: modelData.people || ""
                                    color: "#aaddeeff"
                                    font.pixelSize: 11
                                    visible: (modelData.people || "").length > 0
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: gridRoot.photoClicked(modelData.flatIndex)
                        }
                    }
                }
            }
        }
    }

    // Empty state
    Rectangle {
        anchors.fill: parent
        color: "transparent"
        visible: totalPhotosCount === 0

        Label {
            anchors.centerIn: parent
            horizontalAlignment: Text.AlignHCenter
            text: "No photos found in " + libraryPath + "\nAdd images there to start browsing."
            color: "#8e8e93"
            font.pixelSize: 16
        }
    }

    // Floating date label
    Rectangle {
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: 24
        width: dateLabelText.implicitWidth + 24
        height: dateLabelText.implicitHeight + 16
        radius: 8
        color: "#cc2c2c2e"
        visible: showDateLabel && currentSectionTitle !== ""
        z: 40

        Label {
            id: dateLabelText
            anchors.centerIn: parent
            text: currentSectionTitle
            color: "#f2f2f7"
            font.pixelSize: 14
            font.bold: true
        }

        Behavior on opacity {
            NumberAnimation { duration: 200 }
        }
    }

    function scrollTo(sectionIndex) {
        photosList.scrollToSection(sectionIndex)
    }

    function takeFocus() {
        photosList.forceActiveFocus()
    }
}
