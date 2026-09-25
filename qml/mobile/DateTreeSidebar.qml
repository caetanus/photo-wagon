import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// Years → months → days from the parsed library.dates payload.
// Tapping a year or a month only opens it (nothing is filtered yet); the explicit
// "All of 2024" / "All of March 2024" rows and the day chips filter the grid. Tapping the
// selected one again clears it. Every target is at least 48 units tall.
Rectangle {
    id: sidebar
    required property QtObject theme
    property var dates: ({ years: [] })
    property int selectedYear: 0
    property int selectedMonth: 0
    property int selectedDay: 0
    // inside an album / a person the reset keeps that scope; the tree's counts are the whole
    // library's, so they are not shown there
    property string scopeName: ""
    property bool searching: false   // a search is showing: it is not "all photos"

    signal picked(int year, int month, int day)

    color: theme.panel

    // what is open, apart from what is applied (follows the selection when it changes)
    property int openYear: selectedYear
    property int openMonth: selectedMonth
    onSelectedYearChanged: { openYear = selectedYear; openMonth = selectedMonth }
    onSelectedMonthChanged: openMonth = selectedMonth

    function monthName(m) { return Qt.locale().standaloneMonthName(m - 1, Locale.LongFormat) }
    function toggle(y, m, d) {
        if (y === selectedYear && m === selectedMonth && d === selectedDay)
            picked(0, 0, 0)
        else
            picked(y, m, d)
    }
    function counted(label, n) { return scopeName.length || n === undefined ? label : label + "  ·  " + n }

    // one row of the tree: a label, an optional count, an optional open/closed chevron
    component Row_: ItemDelegate {
        id: row
        property string label: ""
        property int indent: 0
        property bool expandable: false
        property bool expanded: false
        property bool selected: false
        property bool strong: false
        width: parent ? parent.width : 0
        implicitHeight: 48
        leftPadding: 16 + indent
        rightPadding: 12
        background: Rectangle {
            radius: 10
            color: row.selected ? Qt.rgba(sidebar.theme.accent.r, sidebar.theme.accent.g, sidebar.theme.accent.b, 0.16)
                 : row.pressed ? sidebar.theme.panelAlt : "transparent"
        }
        contentItem: RowLayout {
            spacing: 8
            Label {
                Layout.fillWidth: true
                text: row.label
                elide: Text.ElideRight
                color: row.selected ? sidebar.theme.accent : sidebar.theme.text
                font.pixelSize: 15
                font.weight: row.strong || row.selected ? Font.DemiBold : Font.Normal
            }
            Label {
                visible: row.expandable
                text: "›"
                color: sidebar.theme.muted
                font.pixelSize: 20
                rotation: row.expanded ? 90 : 0
                Behavior on rotation { NumberAnimation { duration: 120 } }
            }
        }
    }

    ListView {
        id: years
        anchors.fill: parent
        anchors.margins: 6
        clip: true
        spacing: 2
        model: sidebar.dates.years
        ScrollBar.vertical: ScrollBar { }

        header: Column {
            width: years.width
            Label {
                text: "Dates"
                color: sidebar.theme.muted
                font.pixelSize: 12; font.weight: Font.DemiBold; font.letterSpacing: 0.6
                leftPadding: 16; topPadding: 10; bottomPadding: 6
            }
            Row_ {
                width: years.width
                label: sidebar.scopeName.length ? "All dates in " + sidebar.scopeName : "All photos"
                strong: true
                selected: sidebar.selectedYear === 0 && !sidebar.searching
                onClicked: sidebar.picked(0, 0, 0)
            }
        }

        delegate: Column {
            id: yearNode
            width: years.width
            required property var modelData
            readonly property int year: modelData.year
            readonly property bool open: sidebar.openYear === year

            Row_ {
                width: parent.width
                label: sidebar.counted(String(yearNode.year), yearNode.modelData.count)
                strong: true
                expandable: true
                expanded: yearNode.open
                onClicked: { sidebar.openYear = yearNode.open ? 0 : yearNode.year; sidebar.openMonth = 0 }
            }

            Column {
                width: parent.width
                visible: yearNode.open
                Row_ {
                    width: parent.width
                    indent: 16
                    label: "All of " + yearNode.year
                    selected: sidebar.selectedYear === yearNode.year && sidebar.selectedMonth === 0
                    onClicked: sidebar.toggle(yearNode.year, 0, 0)
                }
                Repeater {
                    model: yearNode.open ? yearNode.modelData.months : []
                    delegate: Column {
                        id: monthNode
                        width: parent.width
                        required property var modelData
                        readonly property int month: modelData.month
                        readonly property bool open: sidebar.openMonth === month

                        Row_ {
                            width: parent.width
                            indent: 16
                            label: sidebar.counted(sidebar.monthName(monthNode.month), monthNode.modelData.count)
                            expandable: true
                            expanded: monthNode.open
                            onClicked: sidebar.openMonth = monthNode.open ? 0 : monthNode.month
                        }

                        Column {
                            width: parent.width
                            visible: monthNode.open
                            Row_ {
                                width: parent.width
                                indent: 32
                                label: "All of " + sidebar.monthName(monthNode.month) + " " + yearNode.year
                                selected: sidebar.selectedYear === yearNode.year
                                          && sidebar.selectedMonth === monthNode.month && sidebar.selectedDay === 0
                                onClicked: sidebar.toggle(yearNode.year, monthNode.month, 0)
                            }
                            Flow {
                                width: parent.width
                                leftPadding: 40
                                rightPadding: 8
                                bottomPadding: 6
                                spacing: 4
                                Repeater {
                                    model: monthNode.open ? monthNode.modelData.days : []
                                    delegate: ItemDelegate {
                                        id: dayChip
                                        required property var modelData
                                        readonly property bool selected: sidebar.selectedYear === yearNode.year
                                            && sidebar.selectedMonth === monthNode.month
                                            && sidebar.selectedDay === modelData.day
                                        implicitWidth: 48
                                        implicitHeight: 48
                                        padding: 0
                                        background: Rectangle {
                                            radius: 24
                                            color: dayChip.selected ? sidebar.theme.accent
                                                 : dayChip.pressed ? sidebar.theme.panelAlt : "transparent"
                                            border.color: dayChip.selected ? "transparent" : sidebar.theme.border
                                            border.width: 1
                                        }
                                        contentItem: Label {
                                            text: String(dayChip.modelData.day)
                                            horizontalAlignment: Text.AlignHCenter
                                            verticalAlignment: Text.AlignVCenter
                                            color: dayChip.selected ? "#ffffff" : sidebar.theme.text
                                            font.pixelSize: 14
                                        }
                                        onClicked: sidebar.toggle(yearNode.year, monthNode.month, dayChip.modelData.day)
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
