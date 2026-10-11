pragma ComponentBehavior: Bound

// The panel ClaudeUsage.qml opens under the bar: one row per usage window,
// each with a pace bar — blue fill for usage, a white tick where linear pace
// says usage should be, and the stretch between them in the status colour.

import QtQuick
import "claude-pace.mjs" as Pace

Item {
    id: panel

    required property var theme
    required property var summary
    required property date now

    readonly property var clock: Pace.paceClock(panel.now)

    implicitWidth: 360
    implicitHeight: content.implicitHeight + 8

    function toneColor(tone) {
        return {
            good: panel.theme.goodColor,
            warn: panel.theme.warnColor,
            bad: panel.theme.badColor
        }[tone] ?? panel.theme.dimColor;
    }

    function note(w) {
        if (w.used >= 100)
            return "Limit reached.";
        if (w.expected === null)
            return "No working time in this window, so no pace.";
        if (w.tone === "bad" || w.tone === "warn")
            return Pace.workDuration(w.deltaWorkMinutes) + " of work ahead of pace · "
                + (w.hitAt ? "limit at this rate " + Pace.clockTime(w.hitAt, panel.now)
                           : "ends at " + Math.round(w.projected) + "% at this rate");
        if (w.tone === "good")
            return Pace.workDuration(w.deltaWorkMinutes) + " of work in hand"
                + (w.projected === null ? "" : " · ends at " + Math.round(w.projected) + "% at this rate");
        return "On pace.";
    }

    function unmeasured(w) {
        if (w.reason === "reset")
            return "Reset at " + Pace.clockTime(w.resetsAt, panel.now) + ". The next poll fills it in.";
        if (!panel.summary.fetchedAt)
            return panel.summary.problem ? "Not measured." : "Not measured yet: fetching.";
        return "Not measured: the usage endpoint does not report it.";
    }

    Column {
        id: content
        width: parent.width
        spacing: 0

        Repeater {
            model: panel.summary.windows

            Item {
                id: row
                required property var modelData
                required property int index

                width: content.width
                implicitHeight: rowContent.implicitHeight + 24

                Rectangle {
                    visible: row.index > 0
                    width: parent.width
                    height: 1
                    color: panel.theme.lineColor
                }

                Column {
                    id: rowContent
                    y: 12
                    width: parent.width
                    spacing: 4

                    Item {
                        width: parent.width
                        implicitHeight: name.implicitHeight

                        Text {
                            id: name
                            text: row.modelData.name
                            color: panel.theme.fgColor
                            font.pixelSize: 12
                            font.bold: true
                        }
                        Text {
                            anchors.right: parent.right
                            visible: row.modelData.measured
                            text: !row.modelData.measured ? ""
                                : "resets in " + Pace.duration(row.modelData.leftMinutes)
                                  + " · " + Pace.clockTime(row.modelData.resetsAt, panel.now)
                            color: panel.theme.dimColor
                            font.pixelSize: 11
                        }
                    }

                    Text {
                        visible: !row.modelData.measured
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: row.modelData.measured ? "" : panel.unmeasured(row.modelData)
                        color: panel.theme.dimColor
                        font.pixelSize: 11
                    }

                    Row {
                        visible: row.modelData.measured
                        spacing: 8

                        Text {
                            id: usedText
                            text: Math.round(row.modelData.used ?? 0) + "%"
                            color: panel.theme.fgColor
                            font.pixelSize: 22
                            font.bold: true
                        }
                        Text {
                            anchors.baseline: usedText.baseline
                            text: Pace.deltaText(row.modelData.delta ?? null)
                            color: panel.toneColor(row.modelData.tone)
                            font.pixelSize: 12
                        }
                        Text {
                            anchors.baseline: usedText.baseline
                            visible: row.modelData.expected !== null && row.modelData.expected !== undefined
                            text: "vs linear " + Math.round(row.modelData.expected ?? 0) + "%"
                            color: panel.theme.dimColor
                            font.pixelSize: 12
                        }
                    }

                    // The pace bar.
                    Item {
                        visible: row.modelData.measured
                        width: parent.width
                        height: 18

                        readonly property real used: Math.min(100, row.modelData.used ?? 0)
                        readonly property real pace: Math.min(100, row.modelData.expected ?? 0)
                        readonly property bool hasPace: row.modelData.expected !== null && row.modelData.expected !== undefined

                        Rectangle {
                            id: track
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width
                            height: 8
                            radius: 4
                            color: panel.theme.trackColor
                        }
                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            width: track.width * parent.used / 100
                            height: 8
                            radius: 4
                            color: panel.theme.accentColor
                        }
                        Rectangle {
                            visible: parent.hasPace
                            anchors.verticalCenter: parent.verticalCenter
                            x: track.width * Math.min(parent.used, parent.pace) / 100
                            width: track.width * Math.abs(parent.used - parent.pace) / 100
                            height: 8
                            color: row.modelData.tone === "neutral"
                                ? panel.theme.accentColor
                                : panel.toneColor(row.modelData.tone)
                        }
                        Rectangle {
                            visible: parent.hasPace
                            x: track.width * parent.pace / 100 - 1
                            width: 2
                            height: 16
                            radius: 1
                            anchors.verticalCenter: parent.verticalCenter
                            color: panel.theme.fgColor
                        }
                    }

                    Text {
                        visible: row.modelData.measured
                        width: parent.width
                        wrapMode: Text.WordWrap
                        text: row.modelData.measured ? panel.note(row.modelData) : ""
                        color: panel.theme.dimColor
                        font.pixelSize: 11
                    }
                }
            }
        }

        Rectangle {
            width: parent.width
            height: 1
            color: panel.theme.lineColor
        }

        Text {
            visible: panel.summary.problem !== ""
            width: parent.width
            topPadding: 8
            wrapMode: Text.WordWrap
            text: panel.summary.problem
            color: panel.theme.warnColor
            font.pixelSize: 11
        }

        Item {
            width: parent.width
            implicitHeight: footer.implicitHeight + 16

            Text {
                id: footer
                y: 8
                text: !panel.clock.until ? "No working hours ahead"
                    : "Pace " + (panel.clock.running ? "running" : "paused") + " until "
                      + Pace.clockTime(panel.clock.until, panel.now)
                color: panel.theme.dimColor
                font.pixelSize: 11
            }
            Text {
                y: 8
                anchors.right: parent.right
                text: panel.summary.fetchedAt
                    ? "updated " + Pace.ago((panel.now - panel.summary.fetchedAt) / 60000)
                    : "no data yet"
                color: panel.theme.dimColor
                font.pixelSize: 11
            }
        }
    }
}
