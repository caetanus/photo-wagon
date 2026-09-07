import QtQuick 2.15
import QtQuick.Window 2.15
Window {
    visible: true
    //width: 400
    //height: 400
    title: "QML Example"
    Rectangle {
        border.color: "black"
        border.width: 2
        anchors.centerIn: parent
        width: parent.width - 100;

        height: 200
        color: "lightblue"
        Text {
            anchors.centerIn: parent
            text: "Hello, QML!!!!"
            font.pointSize: 20
        }

    }}