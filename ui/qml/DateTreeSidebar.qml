import QtQuick
import QtQuick.Controls

// Years → months → days from the parsed library.dates payload.
// Clicking a node filters the grid; clicking the selected node again clears it.
Rectangle {
    id: sidebar
    required property QtObject theme
    property var dates: ({ years: [] })
    property int selectedYear: 0
    property int selectedMonth: 0
    property int selectedDay: 0

    signal picked(int year, int month, int day)

    color: theme.panel
    border.color: theme.border

    readonly property var monthNames: ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    function toggle(y, m, d) {
        if (y === selectedYear && m === selectedMonth && d === selectedDay)
            picked(0, 0, 0)
        else
            picked(y, m, d)
    }

    ListView {
        id: years
        anchors.fill: parent
        anchors.margins: 6
        clip: true
        spacing: 2
        model: sidebar.dates.years
        ScrollBar.vertical: ScrollBar { }

        header: ItemDelegate {
            width: years.width
            text: "All photos"
            highlighted: sidebar.selectedYear === 0
            onClicked: sidebar.picked(0, 0, 0)
        }

        delegate: Column {
            id: yearNode
            width: years.width
            required property var modelData
            readonly property int year: modelData.year
            readonly property bool expanded: sidebar.selectedYear === year

            ItemDelegate {
                width: parent.width
                text: yearNode.year + "  ·  " + yearNode.modelData.count
                font.bold: true
                highlighted: yearNode.expanded && sidebar.selectedMonth === 0
                onClicked: sidebar.toggle(yearNode.year, 0, 0)
            }

            Column {
                width: parent.width
                visible: yearNode.expanded
                Repeater {
                    model: yearNode.expanded ? yearNode.modelData.months : []
                    delegate: Column {
                        id: monthNode
                        width: parent.width
                        required property var modelData
                        readonly property int month: modelData.month
                        readonly property bool expanded: sidebar.selectedMonth === month

                        ItemDelegate {
                            width: parent.width
                            leftPadding: 24
                            text: sidebar.monthNames[monthNode.month - 1] + "  ·  " + monthNode.modelData.count
                            highlighted: monthNode.expanded && sidebar.selectedDay === 0
                            onClicked: sidebar.toggle(yearNode.year, monthNode.month, 0)
                        }

                        Flow {
                            width: parent.width
                            visible: monthNode.expanded
                            leftPadding: 24
                            spacing: 2
                            Repeater {
                                model: monthNode.expanded ? monthNode.modelData.days : []
                                delegate: Button {
                                    required property var modelData
                                    text: String(modelData.day)
                                    flat: true
                                    implicitWidth: 34
                                    implicitHeight: 28
                                    highlighted: sidebar.selectedDay === modelData.day
                                    onClicked: sidebar.toggle(yearNode.year, monthNode.month, modelData.day)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
