import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 1.15

Rectangle {
    id: sidebar
    color: "#2b2b2d"

    property string currentVisibleMonth: ""
    property var dateTreeModel: []
    property var photosFilesModel: []
    property int unknownPeopleCount: 0

    signal scrollToMonth(string monthTitle, int sectionIndex)
    signal openPeople()

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: 16
        spacing: 8

        Label {
            text: "Library"
            color: "#f2f2f7"
            font.pixelSize: 24
            font.bold: true
        }

        Rectangle {
            Layout.fillWidth: true
            implicitHeight: 36
            radius: 8
            color: "#3a3a3c"

            Label {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: 10
                text: "All Photos"
                color: "#f2f2f7"
                font.pixelSize: 15
            }
        }

        Button {
            text: "Unknown people [" + sidebar.unknownPeopleCount + "]"
            Layout.fillWidth: true
            onClicked: sidebar.openPeople()
        }

        Item { Layout.preferredHeight: 8 }

        Label {
            text: "Dates"
            color: "#8e8e93"
            font.pixelSize: 13
            font.bold: true
        }

        ScrollView {
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true

            ListView {
                id: dateTreeList
                model: dateTreeModel
                spacing: 2

                delegate: Column {
                    id: yearDelegate
                    width: dateTreeList.width
                    property bool expanded: sidebar.currentVisibleMonth.indexOf(String(modelData.year)) >= 0
                    property int yearValue: modelData.year

                    Rectangle {
                        width: parent.width
                        height: 32
                        radius: 6
                        color: mouseAreaYear.containsMouse ? "#3a3a3c" : "transparent"

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 6
                            anchors.rightMargin: 10
                            spacing: 6

                            Label {
                                text: expanded ? "▼" : "▶"
                                color: "#8e8e93"
                                font.pixelSize: 10
                            }

                            Label {
                                text: modelData.year
                                color: "#f2f2f7"
                                font.pixelSize: 14
                                font.bold: true
                                Layout.fillWidth: true
                            }
                        }

                        MouseArea {
                            id: mouseAreaYear
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: expanded = !expanded
                        }
                    }

                    Column {
                        visible: expanded
                        width: parent.width
                        spacing: 1

                        Repeater {
                            model: modelData.months

                            Rectangle {
                                property string fullMonthName: modelData.month + " " + yearDelegate.yearValue
                                width: parent.width
                                height: 28
                                radius: 5
                                color: sidebar.currentVisibleMonth === fullMonthName ? "#0a84ff" : (monthMouse.containsMouse ? "#3a3a3c" : "transparent")

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 24
                                    anchors.rightMargin: 10
                                    spacing: 6

                                    Label {
                                        text: modelData.month
                                        color: "#e5e5ea"
                                        font.pixelSize: 13
                                        Layout.fillWidth: true
                                    }

                                    Label {
                                        text: modelData.count
                                        color: "#636366"
                                        font.pixelSize: 12
                                    }
                                }

                                MouseArea {
                                    id: monthMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        var targetMonth = modelData.month + " " + yearDelegate.yearValue
                                        for (var i = 0; i < photosFilesModel.length; i++) {
                                            if (photosFilesModel[i].title === targetMonth) {
                                                sidebar.scrollToMonth(targetMonth, i)
                                                break
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        Label {
            text: "Photo Wagon"
            color: "#8e8e93"
            font.pixelSize: 12
        }
    }
}
