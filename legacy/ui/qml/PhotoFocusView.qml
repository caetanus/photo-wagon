import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: focusRoot
    color: "#e61a1a1c"

    property var photosFlatModel: []
    property int currentIndex: -1
    property int maxPreloadCache: 10
    property bool isLoading: false
    property real loadProgress: 0
    property bool photoFullscreen: false
    property real zoomFactor: 1.0
    property var currentFaces: []
    property string currentPhotoUrl: (currentIndex >= 0 && currentIndex < photosFlatModel.length) ? photosFlatModel[currentIndex].sourceUrl : ""

    // When current photo changes, request its faces from the daemon
    onCurrentPhotoUrlChanged: {
        currentFaces = []
        if (currentPhotoUrl.length > 0) {
            faceRecognitionBridge.requestFacesForPhoto(currentPhotoUrl)
        }
    }

    function preferredSource(item, viewportEdge) {
        if (viewportEdge <= 512 && item.thumbUrl) {
            return item.thumbUrl
        }
        if (viewportEdge <= 1920 && item.screenUrl) {
            return item.screenUrl
        }
        return item.sourceUrl
    }

    signal closed()
    signal indexChanged(int newIndex)

    // Context menu
    Menu {
        id: contextMenu
        
        MenuItem {
            text: "Copy Image"
            onTriggered: {
                if (clipboardHelper.copyImageToClipboard(focusRoot.currentPhotoUrl)) {
                    copiedToast.show("Image copied to clipboard")
                }
            }
        }
        
        MenuItem {
            text: "Copy Path"
            onTriggered: {
                if (clipboardHelper.copyPathToClipboard(focusRoot.currentPhotoUrl)) {
                    copiedToast.show("Path copied to clipboard")
                }
            }
        }
        
        MenuSeparator {}
        
        MenuItem {
            text: "Close"
            onTriggered: focusRoot.closed()
        }
    }

    // Toast notification
    Rectangle {
        id: copiedToast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 80
        width: toastLabel.implicitWidth + 32
        height: toastLabel.implicitHeight + 16
        radius: 8
        color: "#cc000000"
        opacity: 0
        z: 200

        function show(message) {
            toastLabel.text = message
            toastAnimation.start()
        }

        Label {
            id: toastLabel
            anchors.centerIn: parent
            color: "#ffffff"
            font.pixelSize: 14
        }

        SequentialAnimation {
            id: toastAnimation
            NumberAnimation { target: copiedToast; property: "opacity"; to: 1; duration: 150 }
            PauseAnimation { duration: 1500 }
            NumberAnimation { target: copiedToast; property: "opacity"; to: 0; duration: 300 }
        }
    }

    // Background click to close
    MouseArea {
        anchors.fill: parent
        onClicked: focusRoot.closed()
    }

    WheelHandler {
        acceptedDevices: PointerDevice.Mouse | PointerDevice.TouchPad
        onWheel: function(event) {
            if (!focusRoot.photoFullscreen || !(event.modifiers & Qt.ControlModifier)) {
                return
            }

            var delta = event.angleDelta.y !== 0 ? event.angleDelta.y : event.pixelDelta.y
            if (delta > 0) {
                focusRoot.zoomFactor = Math.min(6.0, focusRoot.zoomFactor + 0.12)
            } else if (delta < 0) {
                focusRoot.zoomFactor = Math.max(1.0, focusRoot.zoomFactor - 0.12)
            }
            event.accepted = true
        }
    }

    // Preloader - actual Image elements for buffering
    Repeater {
        id: preloader
        model: 11  // -5 to +5 around current

        Image {
            visible: false
            property int offset: index - 5
            property int targetIdx: focusRoot.currentIndex + offset
            source: (targetIdx >= 0 && targetIdx < photosFlatModel.length)
                ? focusRoot.preferredSource(photosFlatModel[targetIdx], Math.max(focusList.width, focusList.height))
                : ""
            asynchronous: true
            cache: true
        }
    }

    ListView {
        id: focusList
        anchors.fill: parent
        anchors.margins: focusRoot.photoFullscreen ? 0 : 20
        clip: true
        spacing: 0
        model: photosFlatModel
        highlightMoveDuration: 0
        snapMode: ListView.SnapOneItem
        orientation: ListView.Horizontal

        Component.onCompleted: {
            // Don't auto-set currentIndex on load
            focusList.currentIndex = -1
        }

        onCurrentIndexChanged: {
            // Only emit if we're actively showing a photo (not during init)
            if (currentIndex >= 0 && focusRoot.visible) {
                focusRoot.indexChanged(currentIndex)
            }
        }

        Keys.onPressed: function(event) {
            if (event.key === Qt.Key_Escape) {
                focusRoot.closed()
                event.accepted = true
            } else if (event.key === Qt.Key_C && (event.modifiers & Qt.ControlModifier)) {
                if (focusRoot.currentPhotoUrl !== "") {
                    if (clipboardHelper.copyImageToClipboard(focusRoot.currentPhotoUrl)) {
                        copiedToast.show("Image copied to clipboard")
                    }
                }
                event.accepted = true
            } else if (event.key === Qt.Key_F11 || event.key === Qt.Key_F) {
                focusRoot.photoFullscreen = !focusRoot.photoFullscreen
                if (!focusRoot.photoFullscreen) {
                    focusRoot.zoomFactor = 1.0
                }
                event.accepted = true
            } else if (event.key === Qt.Key_Right || event.key === Qt.Key_PageDown) {
                if (focusList.currentIndex < photosFlatModel.length - 1) {
                    focusList.currentIndex++
                    focusList.positionViewAtIndex(focusList.currentIndex, ListView.Center)
                }
                event.accepted = true
            } else if (event.key === Qt.Key_Left || event.key === Qt.Key_PageUp) {
                if (focusList.currentIndex > 0) {
                    focusList.currentIndex--
                    focusList.positionViewAtIndex(focusList.currentIndex, ListView.Center)
                }
                event.accepted = true
            }
        }

        delegate: Item {
            id: focusDelegate
            property bool isCurrent: ListView.isCurrentItem
            property bool isNearby: Math.abs(index - focusList.currentIndex) <= 5
            width: focusList.width
            height: isCurrent ? focusList.height : 0
            visible: isCurrent

            Rectangle {
                id: photoRect
                anchors.centerIn: parent
                property real margin: focusRoot.photoFullscreen ? 0 : 40
                property real maxW: focusDelegate.width - margin
                property real maxH: focusDelegate.height - margin - 44  // leave room for info bar
                property real iw: Math.max(1, modelData.sourceWidth)
                property real ih: Math.max(1, modelData.sourceHeight)
                property real fitScale: Math.min(maxW / iw, maxH / ih)
                property real boundedFitScale: focusRoot.photoFullscreen ? fitScale : Math.min(fitScale, 1.0)
                width: iw * boundedFitScale * (focusRoot.photoFullscreen ? focusRoot.zoomFactor : 1.0)
                height: ih * boundedFitScale * (focusRoot.photoFullscreen ? focusRoot.zoomFactor : 1.0)
                radius: focusRoot.photoFullscreen ? 0 : 12
                color: "#2c2c2e"
                clip: true

                Image {
                    id: focusImage
                    anchors.fill: parent
                    source: (focusDelegate.isCurrent || focusDelegate.isNearby)
                        ? focusRoot.preferredSource(modelData, Math.max(focusDelegate.maxW, focusDelegate.maxH))
                        : ""
                    fillMode: Image.PreserveAspectFit
                    asynchronous: true
                    cache: true

                    onStatusChanged: {
                        if (focusDelegate.isCurrent) {
                            focusRoot.isLoading = (status === Image.Loading)
                            focusRoot.loadProgress = focusImage.progress
                        }
                    }

                    onProgressChanged: {
                        if (focusDelegate.isCurrent) {
                            focusRoot.loadProgress = focusImage.progress
                        }
                    }
                }

                // Face overlay rectangles
                Repeater {
                    model: focusDelegate.isCurrent ? focusRoot.currentFaces : []

                    Rectangle {
                        id: faceOverlay
                        property real scaleX: photoRect.width / Math.max(1, modelData.imageWidth)
                        property real scaleY: photoRect.height / Math.max(1, modelData.imageHeight)
                        property bool isUnknown: !(modelData.personName) || modelData.personName.length === 0

                        x: modelData.x * scaleX
                        y: modelData.y * scaleY
                        width: modelData.w * scaleX
                        height: modelData.h * scaleY
                        color: "transparent"
                        border.width: faceHoverArea.containsMouse ? 2.5 : 1.5
                        border.color: isUnknown ? "#ff9500" : "#30d158"
                        radius: 4
                        opacity: faceHoverArea.containsMouse ? 1.0 : 0.5

                        Behavior on opacity { NumberAnimation { duration: 120 } }
                        Behavior on border.width { NumberAnimation { duration: 120 } }

                        MouseArea {
                            id: faceHoverArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: faceOverlay.isUnknown ? Qt.PointingHandCursor : Qt.ArrowCursor

                            onClicked: {
                                if (faceOverlay.isUnknown) {
                                    focusRoot.promptFaceName(modelData)
                                }
                            }
                        }

                        // Hover tooltip
                        Rectangle {
                            id: faceTooltip
                            visible: faceHoverArea.containsMouse
                            anchors.horizontalCenter: parent.horizontalCenter
                            anchors.bottom: parent.top
                            anchors.bottomMargin: 4
                            width: tooltipLabel.implicitWidth + 16
                            height: tooltipLabel.implicitHeight + 8
                            radius: 6
                            color: "#dd000000"
                            z: 200

                            Label {
                                id: tooltipLabel
                                anchors.centerIn: parent
                                text: faceOverlay.isUnknown ? "Who is this? (click)" : modelData.personName
                                color: faceOverlay.isUnknown ? "#ff9500" : "#f2f2f7"
                                font.pixelSize: 12
                                font.bold: true
                            }
                        }
                    }
                }

                // Right-click / long-press for context menu, left-click stops propagation
                MouseArea {
                    anchors.fill: parent
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    z: -1 // below face overlays
                    onClicked: function(mouse) {
                        if (mouse.button === Qt.RightButton) {
                            contextMenu.popup()
                        }
                    }
                }

                TapHandler {
                    acceptedButtons: Qt.LeftButton
                    longPressThreshold: 0.5
                    onLongPressed: contextMenu.popup()
                }
            }

            // Info bar below the photo
            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.top: photoRect.bottom
                anchors.topMargin: 6
                width: Math.min(photoRect.width, focusDelegate.width - 40)
                height: infoCol.implicitHeight + 10
                radius: 8
                color: "#cc2c2c2e"
                visible: !focusRoot.photoFullscreen

                Column {
                    id: infoCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    spacing: 2

                    Label {
                        width: parent.width
                        text: modelData.subtitle || ""
                        color: "#d1d1d6"
                        font.pixelSize: 13
                        elide: Text.ElideRight
                    }

                    Label {
                        width: parent.width
                        text: modelData.people || ""
                        color: "#aaddeeff"
                        font.pixelSize: 12
                        elide: Text.ElideRight
                        visible: (modelData.people || "").length > 0
                    }
                }
            }
        }
    }

    // Loading progress bar - outside ListView
    Rectangle {
        id: loadingBar
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        anchors.leftMargin: focusRoot.photoFullscreen ? 0 : 40
        anchors.rightMargin: focusRoot.photoFullscreen ? 0 : 40
        anchors.bottomMargin: focusRoot.photoFullscreen ? 0 : 40
        height: 6
        radius: 3
        color: "#3a3a3c"
        visible: focusRoot.isLoading
        z: 100

        Rectangle {
            width: parent.width * focusRoot.loadProgress
            height: parent.height
            radius: 3
            color: "#0a84ff"

            Behavior on width {
                NumberAnimation { duration: 50 }
            }
        }
    }

    // Close button
    Rectangle {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.margins: 16
        width: 38
        height: 38
        radius: 19
        color: "#3a3a3c"
        z: 110
        visible: !focusRoot.photoFullscreen

        Label {
            anchors.centerIn: parent
            text: "✕"
            color: "#f2f2f7"
            font.pixelSize: 16
        }

        MouseArea {
            anchors.fill: parent
            onClicked: focusRoot.closed()
        }
    }

    // Fullscreen button
    Rectangle {
        anchors.top: parent.top
        anchors.right: parent.right
        anchors.topMargin: 16
        anchors.rightMargin: 62
        width: 38
        height: 38
        radius: 19
        color: "#3a3a3c"
        z: 110
        visible: !focusRoot.photoFullscreen

        Label {
            anchors.centerIn: parent
            text: "⛶"
            color: "#f2f2f7"
            font.pixelSize: 18
        }

        MouseArea {
            anchors.fill: parent
            onClicked: {
                focusRoot.photoFullscreen = true
                focusRoot.zoomFactor = 1.0
            }
        }
    }

    function showPhoto(photoIndex) {
        focusRoot.photoFullscreen = false
        focusRoot.zoomFactor = 1.0
        focusList.currentIndex = photoIndex
        focusList.positionViewAtIndex(photoIndex, ListView.Center)
        focusList.forceActiveFocus()
    }

    // ── Face naming (inline) ────────────────────────────────────

    property var pendingFaceData: null

    function promptFaceName(faceData) {
        pendingFaceData = faceData
        faceNameField.text = ""
        faceNamePopup.open()
        faceNameField.forceActiveFocus()
    }

    Dialog {
        id: faceNamePopup
        title: "Who is this?"
        modal: true
        width: 340
        anchors.centerIn: parent
        z: 300

        footer: DialogButtonBox {
            standardButtons: DialogButtonBox.Cancel | DialogButtonBox.Save
            onAccepted: {
                var name = faceNameField.text.trim()
                if (name.length === 0 || !focusRoot.pendingFaceData)
                    return
                faceRecognitionBridge.setFaceName(focusRoot.pendingFaceData.faceId, name)
                faceNamePopup.close()
                // Re-fetch faces for current photo to show the updated name
                faceRecognitionBridge.requestFacesForPhoto(focusRoot.currentPhotoUrl)
            }
        }

        contentItem: Column {
            spacing: 10

            Label {
                text: "Enter this person's name:"
                color: "#d1d1d6"
                font.pixelSize: 14
            }

            TextField {
                id: faceNameField
                width: parent.width
                placeholderText: "Person name"
                Keys.onReturnPressed: faceNamePopup.accepted()
            }
        }
    }

    // ── Receive face data from the daemon ───────────────────────

    Connections {
        target: faceRecognitionBridge
        function onFacesForPhotoReady(sourceUrl, faces) {
            if (sourceUrl === focusRoot.currentPhotoUrl) {
                focusRoot.currentFaces = faces
            }
        }
    }
}
