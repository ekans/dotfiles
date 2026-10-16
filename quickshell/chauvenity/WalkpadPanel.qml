pragma ComponentBehavior: Bound

// The walkpad's panel, under its bar item: four pages, as walkpad-ios's tabs.
//
//   Live      the link line, the speed large, the open walk's distance, time
//             and calories, its speed trace, Finish walk
//   Walks     newest first, the open one marked Now. A click opens its detail:
//             trace, distance, time, calories, top speed, start, last
//             movement, Delete (twice to confirm)
//   Days      distance per day over the last 30 days as bars, then the days
//             with walks: distance, time, calories, walks
//   Settings  Connect to the pad, the remembered pad, Forget this pad
//
// Reads `service.model` (walkpad.mjs) and asks `service` for changes. It
// holds only what is its own: the page, the walk whose detail shows, the
// pending delete.
//
// The lists are keyed by walk id (or day) and read their rows live: the
// status line replaces `model.walks` every second while a walk is open, and
// a ListView given a new array would drop its scroll position each time.

import QtQuick
import QtQuick.Shapes
import "walkpad.mjs" as Pad

Item {
    id: panel

    required property var theme
    required property var service
    required property var now
    // The popup is open. Opening it while Waiting tries the pad at once.
    property bool active: false

    readonly property var model: panel.service.model
    readonly property bool up: panel.model.service === "up"
    readonly property bool waiting: panel.up && panel.model.link.state === "waiting"
    readonly property var link: Pad.linkLine(panel.model)

    // "live" | "walks" | "days" | "settings". Kept across openings.
    property string page: "live"
    // The walk whose detail shows on the Walks page, or -1 for the list.
    property int detailWalk: -1
    // The walk Delete was pressed once for, or -1.
    property int confirmDelete: -1
    // The row of the Walks list the arrow keys are on, once they have been used.
    property int pickedRow: 0
    property bool picking: false
    // The retry countdown's clock: the bar's `now` only moves by the minute.
    property real tick: Date.now()

    implicitWidth: 360
    implicitHeight: column.implicitHeight

    function walkOf(id: int): var {
        return panel.model.walks.find(w => w.id === id) ?? null;
    }

    function toneColor(tone: string): color {
        return tone === "good" ? panel.theme.goodColor
            : tone === "warn" ? panel.theme.warnColor
            : panel.theme.dimColor;
    }

    function setPage(page: string) {
        panel.page = page;
        panel.picking = false;
        panel.closeDetail();
    }

    function openDetail(id: int) {
        panel.confirmDelete = -1;
        panel.detailWalk = id;
    }

    function closeDetail() {
        panel.confirmDelete = -1;
        panel.detailWalk = -1;
    }

    onActiveChanged: {
        if (panel.active && panel.waiting)
            panel.service.retry();
        if (!panel.active)
            panel.confirmDelete = -1;
    }
    onDetailWalkChanged: {
        if (panel.detailWalk >= 0)
            panel.service.fetchSamples(panel.detailWalk);
    }
    // A walk deleted from elsewhere takes its detail with it.
    onModelChanged: {
        if (panel.detailWalk >= 0 && panel.walkOf(panel.detailWalk) === null)
            panel.closeDetail();
    }

    // Keys while open: Left and Right change page. On Walks, Up and Down pick
    // a walk, Return opens it and Backspace goes back to the list. Escape is
    // Walkpad.qml's.
    function keyPressed(event): bool {
        const walks = panel.model.walks;
        if (event.key === Qt.Key_Left || event.key === Qt.Key_Right) {
            panel.setPage(Pad.stepPage(panel.page, event.key === Qt.Key_Left ? -1 : 1));
            return true;
        }
        if (panel.page !== "walks")
            return false;
        if (event.key === Qt.Key_Backspace) {
            panel.closeDetail();
        } else if (panel.detailWalk >= 0 || walks.length === 0) {
            return false;
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Down) {
            const step = event.key === Qt.Key_Up ? -1 : 1;
            panel.pickedRow = Math.min(walks.length - 1, Math.max(0, panel.pickedRow + step));
            panel.picking = true;
        } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            panel.openDetail(walks[Math.min(walks.length - 1, panel.pickedRow)].id);
        } else {
            return false;
        }
        return true;
    }

    Timer {
        interval: 1000
        running: panel.active && panel.waiting
        repeat: true
        triggeredOnStart: true
        onTriggered: panel.tick = Date.now()
    }

    // A small text button, as in NotificationsPanel.
    component Button: Rectangle {
        id: button
        required property var theme
        required property string label
        property bool primary: false
        property color accent: button.theme.accentColor
        signal clicked()

        implicitWidth: buttonText.implicitWidth + 16
        implicitHeight: 22
        radius: 11
        opacity: button.enabled ? 1 : 0.4
        color: button.primary
            ? (buttonMouse.containsMouse ? Qt.lighter(button.accent, 1.1) : button.accent)
            : (buttonMouse.containsMouse ? button.theme.lineColor : button.theme.trackColor)

        Text {
            id: buttonText
            anchors.centerIn: parent
            text: button.label
            color: button.primary ? button.theme.bgColor : button.theme.fgColor
            font.pixelSize: 11
            font.bold: button.primary
        }
        MouseArea {
            id: buttonMouse
            anchors.fill: parent
            hoverEnabled: true
            onClicked: button.clicked()
        }
    }

    // A figure and what it is, in a box of three across.
    component Stat: Rectangle {
        id: stat
        required property var theme
        required property string title
        required property string value

        implicitHeight: 44
        radius: 8
        color: stat.theme.trackColor

        Column {
            anchors.centerIn: parent
            spacing: 2
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: stat.value
                color: stat.theme.fgColor
                font.pixelSize: 14
                font.bold: true
                font.features: { "tnum": 1 }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: stat.title
                color: stat.theme.dimColor
                font.pixelSize: 10
            }
        }
    }

    // A label on the left and its value on the right.
    component Field: Item {
        id: field
        required property var theme
        required property string label
        required property string value

        implicitHeight: 18

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: field.label
            color: field.theme.dimColor
            font.pixelSize: 11
        }
        Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: field.value
            color: field.theme.fgColor
            font.pixelSize: 11
            font.features: { "tnum": 1 }
        }
    }

    component Heading: Text {
        topPadding: 4
        font.pixelSize: 11
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.4
    }

    // A speed trace: Pad.plotTrace over an 84 px Item, BatteryPanel's chart
    // recipe. 0 km/h is the bottom, and the top is named at the right.
    component SpeedTrace: Item {
        id: trace
        required property var theme
        property var points: []
        property real from: 0
        property real to: 0

        readonly property real ceiling: Pad.traceTop(trace.points)
        readonly property var line: Pad.plotTrace(trace.points, {
            from: trace.from,
            to: trace.to,
            top: trace.ceiling,
            width: trace.width,
            height: trace.height
        }).map(p => Qt.point(p.x, p.y))

        implicitHeight: 84

        Repeater {
            model: [0, 0.5, 1]

            Rectangle {
                required property real modelData
                y: Math.round((trace.height - 1) * (1 - modelData))
                width: trace.width
                height: 1
                color: trace.theme.lineColor
            }
        }
        Text {
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: 2
            text: `${trace.ceiling} km/h`
            color: trace.theme.dimColor
            font.pixelSize: 9
        }

        Shape {
            anchors.fill: parent
            visible: trace.line.length > 1
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: "transparent"
                fillColor: Qt.alpha(trace.theme.accentColor, 0.15)
                PathPolyline {
                    path: trace.line.length > 1 ? trace.line.concat([
                        Qt.point(trace.line[trace.line.length - 1].x, trace.height),
                        Qt.point(trace.line[0].x, trace.height)
                    ]) : []
                }
            }
            ShapePath {
                strokeColor: trace.theme.accentColor
                strokeWidth: 1.5
                fillColor: "transparent"
                joinStyle: ShapePath.RoundJoin
                capStyle: ShapePath.RoundCap
                PathPolyline {
                    path: trace.line
                }
            }
        }
    }

    Column {
        id: column
        width: panel.implicitWidth
        spacing: 10

        // Page tabs: Live, Walks, Days, Settings.
        Row {
            spacing: 2

            Repeater {
                model: [["live", "Live"], ["walks", "Walks"], ["days", "Days"], ["settings", "Settings"]]

                Rectangle {
                    id: tab
                    required property var modelData
                    readonly property bool current: tab.modelData[0] === panel.page

                    width: tabLabel.implicitWidth + 16
                    height: 22
                    radius: 4
                    color: tab.current ? panel.theme.trackColor
                        : tabMouse.containsMouse ? panel.theme.hoverColor
                        : "transparent"

                    Text {
                        id: tabLabel
                        anchors.centerIn: parent
                        text: tab.modelData[1]
                        color: tab.current ? panel.theme.fgColor : panel.theme.dimColor
                        font.pixelSize: 12
                    }
                    MouseArea {
                        id: tabMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: panel.setPage(tab.modelData[0])
                    }
                }
            }
        }

        // The link, on every page: its words in their tone, and the countdown
        // to the next try with a way to skip it while waiting.
        Column {
            width: parent.width
            spacing: 4

            Text {
                width: parent.width
                wrapMode: Text.Wrap
                textFormat: Text.PlainText   // carries BlueZ's error and the pad's name
                text: panel.link.text
                color: panel.toneColor(panel.link.tone)
                font.pixelSize: 11
            }

            Row {
                visible: panel.waiting
                spacing: 8

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: Pad.retryLine(panel.model, panel.tick)
                    color: panel.theme.dimColor
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                }
                Button {
                    theme: panel.theme
                    label: "Try now"
                    onClicked: panel.service.retry()
                }
            }
        }

        Loader {
            width: parent.width
            sourceComponent: panel.page === "live" ? livePage
                : panel.page === "walks" ? (panel.detailWalk >= 0 ? detailPage : walksPage)
                : panel.page === "days" ? daysPage
                : settingsPage
        }

        // The last command's error, then the helper's problems.
        Text {
            readonly property string said: [panel.model.commandError].concat(panel.model.problems)
                .filter(s => s !== "").join("\n")

            visible: said !== ""
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: said
            color: panel.theme.warnColor
            font.pixelSize: 11
        }
    }

    // --- pages --------------------------------------------------------------------

    Component {
        id: livePage

        Column {
            id: live
            readonly property var open: panel.model.open
            spacing: 10

            Column {
                anchors.horizontalCenter: parent.horizontalCenter

                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: Pad.speed(panel.model.speedKmh === null ? 0 : panel.model.speedKmh)
                    color: panel.theme.fgColor
                    font.pixelSize: 44
                    font.bold: true
                    font.features: { "tnum": 1 }
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "km/h"
                    color: panel.theme.dimColor
                    font.pixelSize: 11
                }
            }

            // Zeros without an open walk, as walkpad-ios.
            Row {
                width: parent.width
                spacing: 8
                readonly property real cell: (width - 2 * spacing) / 3

                Stat {
                    width: parent.cell
                    theme: panel.theme
                    title: "Distance"
                    value: Pad.km(live.open ? live.open.distanceKm : 0)
                }
                Stat {
                    width: parent.cell
                    theme: panel.theme
                    title: "Time"
                    value: Pad.clock(live.open ? live.open.elapsedS : 0)
                }
                Stat {
                    width: parent.cell
                    theme: panel.theme
                    title: "Calories"
                    value: `${live.open ? live.open.calories : 0} kcal`
                }
            }

            SpeedTrace {
                visible: live.open !== null
                width: parent.width
                theme: panel.theme
                points: live.open && panel.model.trace.walk === live.open.id ? panel.model.trace.points : []
                from: live.open ? live.open.startedAt : 0
                to: live.open ? live.open.endedAt : 0
            }

            Button {
                visible: live.open !== null
                anchors.horizontalCenter: parent.horizontalCenter
                enabled: panel.up
                theme: panel.theme
                label: "Finish walk"
                primary: true
                onClicked: panel.service.finish()
            }
        }
    }

    Component {
        id: walksPage

        Column {
            id: walks
            spacing: 6

            // The walks' ids, replaced only when the list changes shape.
            property var ids: []

            function sync() {
                const next = panel.model.walks.map(w => w.id);
                if (next.join() !== walks.ids.join())
                    walks.ids = next;
            }

            Component.onCompleted: walks.sync()

            Connections {
                target: panel
                function onModelChanged() { walks.sync(); }
            }

            Text {
                visible: walks.ids.length === 0
                width: parent.width
                wrapMode: Text.Wrap
                text: "No walks yet. Start the belt and your walk shows up here."
                color: panel.theme.dimColor
                font.pixelSize: 11
            }

            ListView {
                id: list
                visible: walks.ids.length > 0
                width: parent.width
                height: Math.min(list.contentHeight, 5.5 * 40)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: walks.ids
                currentIndex: panel.pickedRow

                delegate: Rectangle {
                    id: row
                    required property var modelData
                    required property int index
                    readonly property var walk: panel.walkOf(row.modelData)

                    width: list.width
                    height: 40
                    radius: 4
                    color: rowMouse.containsMouse || (panel.picking && row.index === panel.pickedRow)
                        ? panel.theme.hoverColor : "transparent"

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Row {
                            spacing: 6
                            Text {
                                text: row.walk ? Qt.formatDateTime(new Date(row.walk.startedAt), "ddd d MMM HH:mm") : ""
                                color: panel.theme.fgColor
                                font.pixelSize: 12
                                font.features: { "tnum": 1 }
                            }
                            Text {
                                visible: !!row.walk && row.walk.open
                                text: "Now"
                                color: panel.theme.goodColor
                                font.pixelSize: 10
                                font.bold: true
                                anchors.verticalCenter: parent.verticalCenter
                            }
                        }
                        Text {
                            text: row.walk ? Pad.walkLine(row.walk) : ""
                            color: panel.theme.dimColor
                            font.pixelSize: 11
                            font.features: { "tnum": 1 }
                        }
                    }
                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: panel.openDetail(row.modelData)
                    }
                }
            }
        }
    }

    Component {
        id: detailPage

        Column {
            id: detail
            readonly property var walk: panel.walkOf(panel.detailWalk)
            readonly property bool isOpen: !!detail.walk && detail.walk.open
            spacing: 8

            // The open walk's trace grows live. A finished walk's comes from
            // the helper when its detail opens, and when the walk closes.
            onIsOpenChanged: {
                if (!detail.isOpen && detail.walk)
                    panel.service.fetchSamples(detail.walk.id);
            }

            Row {
                spacing: 8

                Button {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: panel.theme
                    label: "‹ Walks"
                    onClicked: panel.closeDetail()
                }
                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: detail.walk ? Qt.formatDateTime(new Date(detail.walk.startedAt), "dddd d MMMM") : ""
                    color: panel.theme.fgColor
                    font.pixelSize: 12
                    font.bold: true
                }
            }

            SpeedTrace {
                width: parent.width
                theme: panel.theme
                points: !detail.walk ? []
                    : detail.isOpen ? (panel.model.trace.walk === detail.walk.id ? panel.model.trace.points : [])
                    : (panel.model.samples && panel.model.samples.walk === detail.walk.id ? panel.model.samples.points : [])
                from: detail.walk ? detail.walk.startedAt : 0
                to: detail.walk ? detail.walk.endedAt : 0
            }

            Column {
                width: parent.width
                spacing: 2

                Field {
                    width: parent.width
                    theme: panel.theme
                    label: "Distance"
                    value: detail.walk ? Pad.km(detail.walk.distanceKm) : ""
                }
                Field {
                    width: parent.width
                    theme: panel.theme
                    label: "Time"
                    value: detail.walk ? Pad.clock(detail.walk.elapsedS) : ""
                }
                Field {
                    width: parent.width
                    theme: panel.theme
                    label: "Calories"
                    value: detail.walk ? `${detail.walk.calories} kcal` : ""
                }
                Field {
                    width: parent.width
                    theme: panel.theme
                    label: "Top speed"
                    value: detail.walk ? `${Pad.speed(detail.walk.maxSpeedKmh)} km/h` : ""
                }
                Field {
                    width: parent.width
                    theme: panel.theme
                    label: "Started"
                    value: detail.walk ? Qt.formatDateTime(new Date(detail.walk.startedAt), "ddd d MMM yyyy HH:mm:ss") : ""
                }
                Field {
                    width: parent.width
                    theme: panel.theme
                    label: "Last movement"
                    value: detail.walk ? Qt.formatDateTime(new Date(detail.walk.endedAt), "HH:mm:ss") : ""
                }
            }

            // The first press asks, the second deletes.
            Button {
                anchors.right: parent.right
                enabled: panel.up && !!detail.walk
                theme: panel.theme
                label: panel.confirmDelete === panel.detailWalk ? "Delete this walk?" : "Delete"
                primary: panel.confirmDelete === panel.detailWalk
                accent: panel.theme.badColor
                onClicked: {
                    if (panel.confirmDelete !== panel.detailWalk) {
                        panel.confirmDelete = panel.detailWalk;
                        return;
                    }
                    panel.service.deleteWalk(panel.detailWalk);
                    panel.closeDetail();
                }
            }
        }
    }

    Component {
        id: daysPage

        Column {
            id: daysColumn
            readonly property var days: Pad.lastDays(Pad.DAYS, panel.model.walks, panel.now)
            readonly property var bars: Pad.plotDays(daysColumn.days, { width: chart.width, height: chart.height - 1, gap: 2 })

            // The days with walks, newest first, replaced only when they change.
            property var keys: []

            function sync() {
                const next = daysColumn.days.filter(d => d.walks > 0).map(d => d.day).reverse();
                if (next.join() !== daysColumn.keys.join())
                    daysColumn.keys = next;
            }

            Component.onCompleted: daysColumn.sync()
            onDaysChanged: daysColumn.sync()

            spacing: 4

            Heading {
                text: `Distance on the pad, last ${Pad.DAYS} days`
                color: panel.theme.dimColor
            }

            Item {
                id: chart
                width: parent.width
                height: 90

                Rectangle {
                    y: chart.height - 1
                    width: chart.width
                    height: 1
                    color: panel.theme.lineColor
                }

                Repeater {
                    model: daysColumn.bars.length

                    Rectangle {
                        id: bar
                        required property int index
                        readonly property var box: daysColumn.bars[bar.index]

                        visible: !!bar.box && bar.box.height > 0
                        x: bar.box ? bar.box.x : 0
                        y: bar.box ? bar.box.y : 0
                        width: bar.box ? bar.box.width : 0
                        height: bar.box ? bar.box.height : 0
                        radius: 1
                        color: panel.theme.accentColor
                    }
                }
            }

            // A date under every seventh bar, counting back from today.
            Item {
                width: parent.width
                height: 14

                Repeater {
                    model: daysColumn.bars.length

                    Text {
                        id: tick
                        required property int index
                        readonly property bool shown: (daysColumn.bars.length - 1 - tick.index) % 7 === 0

                        visible: tick.shown
                        x: Math.max(0, Math.min(chart.width - tick.implicitWidth, daysColumn.bars[tick.index].x))
                        text: tick.index === daysColumn.bars.length - 1 ? "today"
                            : Qt.formatDate(new Date(daysColumn.days[tick.index].day), "d MMM")
                        color: panel.theme.dimColor
                        font.pixelSize: 9
                    }
                }
            }

            Text {
                visible: daysColumn.keys.length === 0
                topPadding: 6
                width: parent.width
                wrapMode: Text.Wrap
                text: `No walks in the last ${Pad.DAYS} days.`
                color: panel.theme.dimColor
                font.pixelSize: 11
            }

            ListView {
                id: dayList
                visible: daysColumn.keys.length > 0
                width: parent.width
                height: Math.min(dayList.contentHeight, 4.5 * 38)
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: daysColumn.keys

                delegate: Item {
                    id: dayRow
                    required property var modelData
                    readonly property var day: daysColumn.days.find(d => d.day === dayRow.modelData) ?? null

                    width: dayList.width
                    height: 38

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: 6
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2

                        Text {
                            text: Qt.formatDate(new Date(dayRow.modelData), "dddd d MMMM")
                            color: panel.theme.fgColor
                            font.pixelSize: 12
                        }
                        Text {
                            text: dayRow.day ? Pad.dayLine(dayRow.day) : ""
                            color: panel.theme.dimColor
                            font.pixelSize: 11
                            font.features: { "tnum": 1 }
                        }
                    }
                }
            }
        }
    }

    Component {
        id: settingsPage

        Column {
            spacing: 10

            // The switch persists in the helper, so the desktop stays away
            // from the pad until it is turned on again.
            Item {
                width: parent.width
                height: 22
                opacity: panel.up ? 1 : 0.4

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Connect to the pad"
                    color: panel.theme.fgColor
                    font.pixelSize: 12
                }
                Rectangle {
                    id: track
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 32
                    height: 18
                    radius: 9
                    color: panel.model.connect ? panel.theme.accentColor : panel.theme.trackColor
                    border.color: panel.theme.lineColor

                    Rectangle {
                        x: panel.model.connect ? track.width - width - 2 : 2
                        anchors.verticalCenter: parent.verticalCenter
                        width: 14
                        height: 14
                        radius: 7
                        color: panel.theme.fgColor
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: panel.up
                        onClicked: panel.service.setConnect(!panel.model.connect)
                    }
                }
            }

            Item {
                visible: panel.model.pad !== null
                width: parent.width
                height: 22

                Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Pad"
                    color: panel.theme.dimColor
                    font.pixelSize: 12
                }
                Text {
                    anchors.right: forgetButton.left
                    anchors.rightMargin: 10
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: panel.model.pad ?? ""
                    color: panel.theme.fgColor
                    font.pixelSize: 12
                }
                Button {
                    id: forgetButton
                    anchors.right: parent.right
                    enabled: panel.up
                    theme: panel.theme
                    label: "Forget this pad"
                    onClicked: panel.service.forget()
                }
            }

            Text {
                width: parent.width
                wrapMode: Text.Wrap
                text: "The pad takes one connection at a time. Turn this off to hand it to the iPhone app. Super+Space w c does the same."
                color: panel.theme.dimColor
                font.pixelSize: 10
            }
        }
    }
}
