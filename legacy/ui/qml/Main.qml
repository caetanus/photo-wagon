import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

ApplicationWindow {
    id: root
    width: 1280
    height: 820
    visible: true
    title: "Photo Wagon"
    color: "#1d1d1f"

    property int focusedPhotoIndex: -1
    property string currentVisibleMonth: ""
    property bool isMobile: width < 600
    property var peopleFingerprints: []
    property var selectedFingerprint: null
    property bool statusBusy: (photosLoaded || 0) < (photosCount || 0)
    property real statusProgress: (photosCount || 0) > 0
        ? (photosLoaded || 0) / (photosCount || 1)
        : 0.0
    property string statusText: {
        if (statusBusy)
            return "Loading " + (photosLoaded || 0) + " / " + (photosCount || 0) + " photos…"
        if (faceRecognitionBridge.scanInProgress)
            return "Scanning faces… " + faceRecognitionBridge.scannedImages + " images • " + faceRecognitionBridge.unknownPeopleCount + " unknown"
        return "Library ready • " + (photosCount || 0) + " photos • " + faceRecognitionBridge.unknownPeopleCount + " unknown faces"
    }

    function expandedFaceRect(fp) {
        if (!fp) {
            return Qt.rect(0, 0, 1, 1)
        }

        var imageW = Math.max(1, fp.imageWidth)
        var imageH = Math.max(1, fp.imageHeight)
        var faceW = Math.max(1, fp.w)
        var faceH = Math.max(1, fp.h)
        var centerX = fp.x + faceW / 2
        var centerY = fp.y + faceH / 2

        var zoomOut = 1.8
        var cropW = Math.min(imageW, Math.max(faceW * zoomOut, 160))
        var cropH = Math.min(imageH, Math.max(faceH * zoomOut, 160))

        var left = Math.max(0, Math.min(imageW - cropW, centerX - cropW / 2))
        var top = Math.max(0, Math.min(imageH - cropH, centerY - cropH / 2))

        return Qt.rect(left, top, cropW, cropH)
    }

    function refreshPeopleFingerprints(scanNow) {
        if (scanNow) {
            faceRecognitionBridge.requestBackgroundFaceScan(photosLibraryPath)
        }
        peopleFingerprints = faceRecognitionBridge.listPeopleFingerprints()
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        RowLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            spacing: 0

            // Sidebar - hidden on mobile
            DateTreeSidebar {
                id: sidebar
                Layout.preferredWidth: 250
                Layout.fillHeight: true
                visible: !root.isMobile

                currentVisibleMonth: root.currentVisibleMonth
                dateTreeModel: dateTree
                photosFilesModel: photosFiles
                unknownPeopleCount: faceRecognitionBridge.unknownPeopleCount

                onScrollToMonth: function(monthTitle, sectionIndex) {
                    root.currentVisibleMonth = monthTitle
                    photoGrid.scrollTo(sectionIndex)
                }

                onOpenPeople: {
                    root.refreshPeopleFingerprints(false)
                    peopleDialog.open()
                }
            }

            // Main content area
            Rectangle {
                Layout.fillWidth: true
                Layout.fillHeight: true
                color: "#1d1d1f"

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: root.isMobile ? 8 : 18
                    spacing: root.isMobile ? 8 : 14

                // Header
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: root.isMobile ? 44 : 54
                    radius: 12
                    color: "#2c2c2e"

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 10

                        Label {
                            text: "Photos"
                            color: "#f2f2f7"
                            font.pixelSize: root.isMobile ? 18 : 22
                            font.bold: true
                        }

                        Item { Layout.fillWidth: true }

                        Button {
                            text: "Quit"
                            onClicked: Qt.quit()
                        }

                        Rectangle {
                            Layout.preferredWidth: root.isMobile ? 120 : 280
                            Layout.preferredHeight: 34
                            radius: 17
                            color: "#3a3a3c"
                            visible: !root.isMobile

                            Label {
                                anchors.centerIn: parent
                                text: "Search"
                                color: "#8e8e93"
                                font.pixelSize: 14
                            }
                        }
                    }
                }

                // Photo count label
                Label {
                    text: (photosCount || 0) + " photos" + (root.isMobile ? "" : "  •  " + photosLibraryPath)
                    color: "#8e8e93"
                    font.pixelSize: 13
                }

                // Photo grid and focus view container
                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    PhotoGrid {
                        id: photoGrid
                        anchors.fill: parent

                        photosFilesModel: photosFiles
                        totalPhotosCount: Number(photosCount) || 0
                        libraryPath: photosLibraryPath
                        isMobile: root.isMobile

                        onPhotoClicked: function(flatIndex) {
                            root.focusedPhotoIndex = flatIndex
                            focusView.showPhoto(flatIndex)
                        }

                        onVisibleMonthChanged: function(monthTitle) {
                            root.currentVisibleMonth = monthTitle
                        }
                    }

                    PhotoFocusView {
                        id: focusView
                        anchors.fill: parent
                        visible: root.focusedPhotoIndex >= 0
                        z: 50

                        photosFlatModel: photosFlat
                        currentIndex: root.focusedPhotoIndex

                        onClosed: {
                            root.focusedPhotoIndex = -1
                            photoGrid.takeFocus()
                        }

                        onIndexChanged: function(newIndex) {
                            root.focusedPhotoIndex = newIndex
                        }
                    }
                }
            }
        }

        }

        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 34
            color: "#2b2b2d"

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 12
                anchors.rightMargin: 12
                spacing: 10

                Label {
                    text: root.statusText
                    color: "#d1d1d6"
                    font.pixelSize: 12
                    Layout.preferredWidth: 260
                    elide: Text.ElideRight
                }

                ProgressBar {
                    Layout.fillWidth: true
                    from: 0
                    to: 1
                    value: root.statusProgress
                    indeterminate: root.statusBusy
                }
            }
        }
    }

    Dialog {
        id: peopleDialog
        title: "People"
        modal: true
        width: Math.min(root.width - 40, 860)
        height: Math.min(root.height - 40, 620)
        anchors.centerIn: parent

        footer: DialogButtonBox {
            standardButtons: DialogButtonBox.Close

            Button {
                text: "Rescan"
                DialogButtonBox.buttonRole: DialogButtonBox.ActionRole
                onClicked: root.refreshPeopleFingerprints(true)
            }
        }

        contentItem: Item {
            anchors.fill: parent

            Label {
                id: peopleCountLabel
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                text: root.peopleFingerprints.length + " fingerprints"
                color: "#d1d1d6"
                font.pixelSize: 13
            }

            ListView {
                id: peopleList
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: peopleCountLabel.bottom
                anchors.topMargin: 10
                anchors.bottom: parent.bottom
                clip: true
                spacing: 10
                model: root.peopleFingerprints

                delegate: Rectangle {
                    width: peopleList.width
                    height: 136
                    radius: 10
                    color: "#2c2c2e"

                    RowLayout {
                        anchors.fill: parent
                        anchors.margins: 10
                        spacing: 10

                        Rectangle {
                            Layout.preferredWidth: 160
                            Layout.preferredHeight: 116
                            color: "#1d1d1f"
                            radius: 8
                            clip: true

                            Image {
                                id: facePreviewImage
                                anchors.fill: parent
                                source: modelData.thumbUrl
                                asynchronous: true
                                cache: true
                                fillMode: Image.PreserveAspectFit
                            }

                            Rectangle {
                                color: "transparent"
                                border.width: 2
                                border.color: "#0a84ff"

                                x: (facePreviewImage.width * modelData.x) / Math.max(1, modelData.imageWidth)
                                y: (facePreviewImage.height * modelData.y) / Math.max(1, modelData.imageHeight)
                                width: (facePreviewImage.width * modelData.w) / Math.max(1, modelData.imageWidth)
                                height: (facePreviewImage.height * modelData.h) / Math.max(1, modelData.imageHeight)
                            }

                            MouseArea {
                                anchors.fill: parent
                                onClicked: {
                                    root.selectedFingerprint = modelData
                                    whoDialogName.text = modelData.personName ? modelData.personName : ""
                                    whoIsThisDialog.open()
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            spacing: 8

                            Label {
                                Layout.fillWidth: true
                                color: "#f2f2f7"
                                text: modelData.personName && modelData.personName.length > 0
                                    ? modelData.personName
                                    : "Unknown person"
                                font.bold: true
                                elide: Text.ElideRight
                            }

                            Label {
                                Layout.fillWidth: true
                                color: "#8e8e93"
                                text: "Fingerprint #" + modelData.fingerprintId + " • " + modelData.faceCount + " photos"
                                font.pixelSize: 12
                                elide: Text.ElideMiddle
                            }

                            Label {
                                Layout.fillWidth: true
                                color: "#8e8e93"
                                text: "Click photo to answer: Who is this?"
                                font.pixelSize: 12
                                elide: Text.ElideRight
                            }
                        }
                    }
                }
            }
        }
    }

    Dialog {
        id: whoIsThisDialog
        title: "Who is this?"
        modal: true
        width: 420

        footer: DialogButtonBox {
            standardButtons: DialogButtonBox.Cancel | DialogButtonBox.Save
            onAccepted: {
                if (!root.selectedFingerprint) {
                    return
                }
                var trimmed = whoDialogName.text.trim()
                if (trimmed.length === 0) {
                    return
                }
                if (faceRecognitionBridge.setFingerprintName(root.selectedFingerprint.fingerprintId, trimmed)) {
                    root.refreshPeopleFingerprints(false)
                    whoIsThisDialog.close()
                }
            }
        }

        contentItem: ColumnLayout {
            spacing: 10

            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 240
                Layout.preferredHeight: 240
                radius: 12
                color: "#2c2c2e"
                clip: true

                Image {
                    anchors.fill: parent
                    source: root.selectedFingerprint ? root.selectedFingerprint.sourceUrl : ""
                    fillMode: Image.PreserveAspectCrop
                    asynchronous: true
                    cache: true
                    sourceClipRect: root.expandedFaceRect(root.selectedFingerprint)
                }
            }

            Label {
                text: root.selectedFingerprint ? ("Fingerprint #" + root.selectedFingerprint.fingerprintId) : ""
                color: "#8e8e93"
                font.pixelSize: 12
            }

            TextField {
                id: whoDialogName
                Layout.fillWidth: true
                placeholderText: "Type person name"
            }
        }
    }

    Component.onCompleted: {
        faceRecognitionBridge.startUnknownPeopleMonitoring(photosLibraryPath)
    }

    Connections {
        target: faceRecognitionBridge
        function onPeopleListReady(fingerprints) {
            root.peopleFingerprints = fingerprints
        }
        function onScanInProgressChanged() {
            // When scan finishes, auto-refresh the people dialog if open
            if (!faceRecognitionBridge.scanInProgress && peopleDialog.visible) {
                root.refreshPeopleFingerprints(false)
            }
        }
    }
}
