pragma ComponentBehavior: Bound

// The panel Clock.qml opens under the bar: today in full and a month
// calendar with ISO week numbers, and beside it the events of a day, or of
// the 7 or 30 days from it, as the switch above them says. The arrows page
// through the months; a click on the month name, or reopening the panel,
// comes back to today. A dot under a day says it has events, and a click on
// the day lists from there. A click on an event with a call link — Teams,
// Meet, Zoom, a Slack huddle — opens it.
//
// All of it works from the keyboard as well, as keyPressed() says; the keys
// are listed along the bottom.
//
// The events are shell.qml's, from calendar-events.py, as calendar.mjs reads
// them.

import QtQuick
import "clock.mjs" as Clock
import "calendar.mjs" as Cal

Item {
    id: panel

    required property var theme
    required property date now
    // calendar.mjs's feed, with shell.qml's problems added.
    required property var calendar
    // Whether the panel is open. Each opening starts on the current month.
    property bool active: false

    // A click on an event opened its link; the panel can go.
    signal linkOpened

    property int year: panel.now.getFullYear()
    property int month: panel.now.getMonth()
    readonly property var grid: Clock.monthGrid(panel.year, panel.month, panel.now)
    readonly property bool onToday: panel.year === panel.now.getFullYear()
        && panel.month === panel.now.getMonth()

    // The day the events are listed from, and for how many days: 1, 7 or
    // 30. Reopening the panel goes back to today but keeps the number.
    property date selected: new Date(panel.now.getFullYear(), panel.now.getMonth(), panel.now.getDate())
    property int days: 1
    // The event Tab reached and Enter opens, as an index into `agenda`, or -1.
    property int cursor: -1
    readonly property string selectedKey: Cal.dayKey(panel.selected)
    readonly property var busy: Cal.busyDays(panel.calendar)
    readonly property var agenda: Cal.agenda(panel.calendar, panel.selected, panel.days, panel.now)
    readonly property string agendaNote: Cal.agendaNote(panel.calendar, panel.selected, panel.days, panel.agenda)

    readonly property int cell: 26

    implicitWidth: layout.implicitWidth
    implicitHeight: layout.implicitHeight

    function goToday() {
        panel.select(panel.now);
    }

    function page(delta) {
        const next = Clock.shiftMonth(panel.year, panel.month, delta);
        panel.year = next.year;
        panel.month = next.month;
    }

    // Lists the events from that day, and turns the calendar to its month.
    function select(day) {
        panel.selected = new Date(day.getFullYear(), day.getMonth(), day.getDate());
        panel.year = day.getFullYear();
        panel.month = day.getMonth();
        panel.cursor = -1;
        panel.scrollToUpcoming();
    }

    function showDays(days) {
        panel.days = days;
        panel.cursor = -1;
        panel.scrollToUpcoming();
    }

    // Moves the cursor to the next event, `n` 1, or the one before, -1.
    function step(n) {
        panel.cursor = Cal.stepEvent(panel.agenda, panel.cursor, n);
        if (panel.cursor >= 0)
            events.positionViewAtIndex(panel.cursor, ListView.Contain);
    }

    // Opens the link of the event under the cursor. With none there yet, it
    // only puts the cursor on the next meeting, so that a second Enter is
    // the one that joins it.
    function open() {
        const item = panel.agenda[panel.cursor];
        if (!item || item.kind !== "event") {
            panel.step(1);
        } else if (item.link) {
            Qt.openUrlExternally(item.link);
            panel.linkOpened();
        }
    }

    // A key pressed while the panel is open, from Clock.qml. The arrows, or
    // H J K L, move the day by a day or a week, Page Up and Page Down by a
    // month, and T or Home come back to today; D, W and M list 1, 7 or 30
    // days; Tab and Shift+Tab go through the events listed, and Enter or
    // Space opens the link of the one reached. Answers whether it was one of
    // those.
    function keyPressed(event) {
        // A chord with Ctrl, Alt or Super is not the panel's.
        if (event.modifiers & (Qt.ControlModifier | Qt.AltModifier | Qt.MetaModifier))
            return false;
        const day = panel.selected;
        const by = n => new Date(day.getFullYear(), day.getMonth(), day.getDate() + n);
        switch (event.key) {
        case Qt.Key_Left:
        case Qt.Key_H:
            panel.select(by(-1));
            break;
        case Qt.Key_Right:
        case Qt.Key_L:
            panel.select(by(1));
            break;
        case Qt.Key_Up:
        case Qt.Key_K:
            panel.select(by(-7));
            break;
        case Qt.Key_Down:
        case Qt.Key_J:
            panel.select(by(7));
            break;
        case Qt.Key_PageUp:
            panel.select(Clock.shiftMonthDay(day, -1));
            break;
        case Qt.Key_PageDown:
            panel.select(Clock.shiftMonthDay(day, 1));
            break;
        case Qt.Key_Home:
        case Qt.Key_T:
            panel.goToday();
            break;
        case Qt.Key_D:
            panel.showDays(1);
            break;
        case Qt.Key_W:
            panel.showDays(7);
            break;
        case Qt.Key_M:
            panel.showDays(30);
            break;
        // Shift+Tab is Backtab from a keyboard's layout, but Tab with Shift
        // held from one that does not map it, as wtype's.
        case Qt.Key_Tab:
            panel.step(event.modifiers & Qt.ShiftModifier ? -1 : 1);
            break;
        case Qt.Key_Backtab:
            panel.step(-1);
            break;
        case Qt.Key_Return:
        case Qt.Key_Enter:
        case Qt.Key_Space:
            panel.open();
            break;
        default:
            return false;
        }
        return true;
    }

    // Past the meetings already over, once the list has its new rows.
    function scrollToUpcoming() {
        Qt.callLater(() => events.positionViewAtIndex(Cal.firstUpcoming(panel.agenda), ListView.Beginning));
    }

    onActiveChanged: {
        if (panel.active)
            panel.goToday();
    }

    component Arrow: Text {
        id: arrow
        signal clicked

        width: panel.cell
        height: 22
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        color: arrowMouse.containsMouse ? panel.theme.fgColor : panel.theme.dimColor
        font.pixelSize: 14

        Rectangle {
            z: -1
            anchors.fill: parent
            radius: 4
            color: arrowMouse.containsMouse ? panel.theme.hoverColor : "transparent"
        }
        MouseArea {
            id: arrowMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: arrow.clicked()
        }
    }

    Column {
        id: layout
        spacing: 10

        Row {
            id: content
            spacing: 14

            Column {
                id: monthView
                spacing: 4

                Text {
                    text: Qt.formatDateTime(panel.now, "dddd d MMMM yyyy")
                    color: panel.theme.fgColor
                    font.pixelSize: 12
                    font.bold: true
                }

                Text {
                    readonly property var week: Clock.isoWeek(panel.now)
                    bottomPadding: 4
                    text: "Week " + week.week + (week.year !== panel.now.getFullYear() ? " of " + week.year : "")
                    color: panel.theme.dimColor
                    font.pixelSize: 11
                }

                // Month name between the arrows.
                Item {
                    width: header.width
                    height: 22

                    Arrow {
                        anchors.left: parent.left
                        text: "‹"
                        onClicked: panel.page(-1)
                    }
                    Text {
                        anchors.centerIn: parent
                        text: Qt.formatDate(new Date(panel.year, panel.month, 1), "MMMM yyyy")
                        color: panel.onToday ? panel.theme.fgColor : panel.theme.accentColor
                        font.pixelSize: 12
                        font.bold: true

                        MouseArea {
                            anchors.fill: parent
                            anchors.margins: -4
                            enabled: !panel.onToday
                            cursorShape: panel.onToday ? Qt.ArrowCursor : Qt.PointingHandCursor
                            onClicked: panel.goToday()
                        }
                    }
                    Arrow {
                        anchors.right: parent.right
                        text: "›"
                        onClicked: panel.page(1)
                    }
                }

                // Week-number column, then Monday to Sunday.
                Row {
                    id: header

                    Text {
                        width: panel.cell
                        horizontalAlignment: Text.AlignHCenter
                        text: "W"
                        color: panel.theme.lineColor
                        font.pixelSize: 10
                    }
                    Repeater {
                        model: ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]

                        Text {
                            required property string modelData
                            required property int index
                            width: panel.cell
                            horizontalAlignment: Text.AlignHCenter
                            text: modelData
                            color: index >= 5 ? panel.theme.dimColor : panel.theme.fgColor
                            font.pixelSize: 10
                        }
                    }
                }

                Repeater {
                    model: panel.grid

                    Row {
                        id: weekRow
                        required property var modelData

                        Text {
                            width: panel.cell
                            height: 22
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            text: weekRow.modelData.week
                            color: panel.theme.dimColor
                            font.pixelSize: 10
                            font.features: { "tnum": 1 }
                        }
                        Repeater {
                            model: weekRow.modelData.days

                            Rectangle {
                                id: dayCell
                                required property var modelData
                                readonly property bool isSelected: Cal.dayKey(dayCell.modelData.date) === panel.selectedKey

                                width: panel.cell
                                height: 22
                                radius: 4
                                color: dayCell.modelData.today ? panel.theme.accentColor
                                    : dayMouse.containsMouse ? panel.theme.hoverColor
                                    : "transparent"
                                border.width: dayCell.isSelected && !dayCell.modelData.today ? 1 : 0
                                border.color: panel.theme.accentColor

                                Text {
                                    anchors.centerIn: parent
                                    text: dayCell.modelData.day
                                    color: dayCell.modelData.today ? panel.theme.bgColor
                                        : !dayCell.modelData.inMonth ? panel.theme.lineColor
                                        : dayCell.modelData.weekend ? panel.theme.dimColor
                                        : panel.theme.fgColor
                                    font.pixelSize: 11
                                    font.bold: dayCell.modelData.today
                                    font.features: { "tnum": 1 }
                                }

                                // The day has events.
                                Rectangle {
                                    visible: !!panel.busy[Cal.dayKey(dayCell.modelData.date)]
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    y: parent.height - 5
                                    width: 3
                                    height: 3
                                    radius: 1.5
                                    color: dayCell.modelData.today ? panel.theme.bgColor
                                        : dayCell.modelData.inMonth ? panel.theme.dimColor
                                        : panel.theme.lineColor
                                }

                                MouseArea {
                                    id: dayMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: panel.select(dayCell.modelData.date)
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: 1
                height: monthView.height
                color: panel.theme.lineColor
            }

            // The events listed, in the month view's height so that the panel
            // keeps its size whatever they are; a busy stretch scrolls.
            Item {
                width: 260
                height: monthView.height

                Text {
                    id: listTitle
                    anchors.left: parent.left
                    anchors.right: range.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: range.verticalCenter
                    elide: Text.ElideRight
                    text: {
                        const relative = Cal.relativeDay(panel.selected, panel.now);
                        // The switch beside it says how many days.
                        if (panel.days > 1)
                            return relative === "Today" ? `Next ${panel.days} days`
                                : "From " + Qt.formatDate(panel.selected, "ddd d MMM");
                        return relative ? relative + " · " + Qt.formatDate(panel.selected, "ddd d MMM")
                            : Qt.formatDate(panel.selected, "ddd d MMMM yyyy");
                    }
                    color: panel.theme.fgColor
                    font.pixelSize: 12
                    font.bold: true
                }

                // How many days to list.
                Row {
                    id: range
                    anchors.right: parent.right
                    spacing: 2

                    Repeater {
                        model: [{ days: 1, label: "Day" }, { days: 7, label: "7 days" }, { days: 30, label: "30 days" }]

                        Text {
                            id: choice
                            required property var modelData
                            readonly property bool chosen: panel.days === choice.modelData.days

                            height: 18
                            leftPadding: 6
                            rightPadding: 6
                            verticalAlignment: Text.AlignVCenter
                            text: choice.modelData.label
                            color: choice.chosen || choiceMouse.containsMouse ? panel.theme.fgColor : panel.theme.dimColor
                            font.pixelSize: 10

                            Rectangle {
                                z: -1
                                anchors.fill: parent
                                radius: 4
                                color: choice.chosen ? panel.theme.lineColor
                                    : choiceMouse.containsMouse ? panel.theme.hoverColor
                                    : "transparent"
                            }
                            MouseArea {
                                id: choiceMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: panel.showDays(choice.modelData.days)
                            }
                        }
                    }
                }

                // In place of the events, when there are none.
                Text {
                    anchors.top: range.bottom
                    anchors.topMargin: 8
                    width: parent.width
                    visible: panel.agenda.length === 0 && panel.agendaNote !== ""
                    wrapMode: Text.WordWrap
                    text: panel.agendaNote
                    color: panel.theme.dimColor
                    font.pixelSize: 11
                }

                ListView {
                    id: events
                    anchors.top: range.bottom
                    anchors.topMargin: 6
                    anchors.bottom: problems.visible ? problems.top : parent.bottom
                    anchors.bottomMargin: problems.visible ? 6 : 0
                    width: parent.width
                    clip: true
                    spacing: 2
                    boundsBehavior: Flickable.StopAtBounds
                    model: panel.agenda

                    // Below the events, when some of the days listed were not read.
                    footer: Text {
                        width: events.width
                        topPadding: 6
                        visible: panel.agenda.length > 0 && panel.agendaNote !== ""
                        height: visible ? implicitHeight : 0
                        wrapMode: Text.WordWrap
                        text: panel.agendaNote
                        color: panel.theme.dimColor
                        font.pixelSize: 10
                    }

                    // A day's heading, or one of its events.
                    delegate: Item {
                        id: item
                        required property var modelData
                        required property int index
                        readonly property bool heading: item.modelData.kind === "day"
                        readonly property bool current: item.index === panel.cursor

                        width: events.width
                        height: item.heading ? 22 : 34

                        Text {
                            visible: item.heading
                            x: 4
                            anchors.bottom: parent.bottom
                            bottomPadding: 2
                            text: item.heading ? item.modelData.label : ""
                            color: panel.theme.fgColor
                            font.pixelSize: 11
                            font.bold: true
                        }

                        Rectangle {
                            id: row
                            visible: !item.heading
                            anchors.fill: parent
                            radius: 4
                            color: rowMouse.containsMouse || item.current ? panel.theme.hoverColor : "transparent"
                            border.width: item.current ? 1 : 0
                            border.color: panel.theme.accentColor

                            // The calendar's colour.
                            Rectangle {
                                x: 4
                                y: 6
                                width: 3
                                height: parent.height - 12
                                radius: 1.5
                                color: item.modelData.color || panel.theme.dimColor
                                opacity: item.modelData.past ? 0.4 : 1
                            }

                            Column {
                                x: 14
                                anchors.verticalCenter: parent.verticalCenter
                                width: parent.width - x - (linkMark.visible ? linkMark.width + 4 : 6)
                                spacing: 1

                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    // Event titles come from whoever sent the invite.
                                    textFormat: Text.PlainText
                                    text: item.modelData.title || "(no title)"
                                    color: item.modelData.past ? panel.theme.dimColor : panel.theme.fgColor
                                    font.pixelSize: 12
                                    // Not accepted yet, or only tentatively.
                                    font.italic: !!item.modelData.tentative
                                }
                                Text {
                                    width: parent.width
                                    elide: Text.ElideRight
                                    textFormat: Text.PlainText
                                    text: (item.modelData.time ?? "") + (item.modelData.location ? " · " + item.modelData.location : "")
                                    color: item.modelData.ongoing ? panel.theme.accentColor : panel.theme.dimColor
                                    font.pixelSize: 10
                                    font.features: { "tnum": 1 }
                                }
                            }

                            Text {
                                id: linkMark
                                visible: !!item.modelData.link
                                anchors.right: parent.right
                                anchors.rightMargin: 6
                                anchors.verticalCenter: parent.verticalCenter
                                text: "↗"
                                color: rowMouse.containsMouse ? panel.theme.fgColor : panel.theme.dimColor
                                font.pixelSize: 12
                            }

                            MouseArea {
                                id: rowMouse
                                anchors.fill: parent
                                enabled: !item.heading && !!item.modelData.link
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    Qt.openUrlExternally(item.modelData.link);
                                    panel.linkOpened();
                                }
                            }
                        }
                    }
                }

                Text {
                    id: problems
                    anchors.bottom: parent.bottom
                    width: parent.width
                    visible: panel.calendar.problems.length > 0
                    wrapMode: Text.WordWrap
                    maximumLineCount: 4
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: panel.calendar.problems.join("\n")
                    color: panel.theme.warnColor
                    font.pixelSize: 11
                }
            }
        }

        // The keys keyPressed() takes.
        Flow {
            width: content.width
            spacing: 12

            Repeater {
                model: [
                    { keys: "←→↑↓", does: "day" },
                    { keys: "PgUp/PgDn", does: "month" },
                    { keys: "T", does: "today" },
                    { keys: "D/W/M", does: "1, 7, 30 days" },
                    { keys: "Tab", does: "event" },
                    { keys: "⏎", does: "open" },
                ]

                Row {
                    id: hint
                    required property var modelData
                    spacing: 4

                    Rectangle {
                        width: Math.max(16, capText.implicitWidth + 8)
                        height: 16
                        radius: 4
                        color: panel.theme.trackColor
                        border.color: panel.theme.lineColor

                        Text {
                            id: capText
                            anchors.centerIn: parent
                            text: hint.modelData.keys
                            color: panel.theme.fgColor
                            font.pixelSize: 10
                        }
                    }
                    Text {
                        anchors.verticalCenter: parent.verticalCenter
                        text: hint.modelData.does
                        color: panel.theme.dimColor
                        font.pixelSize: 10
                    }
                }
            }
        }
    }
}
