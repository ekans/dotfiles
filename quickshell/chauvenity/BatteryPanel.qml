pragma ComponentBehavior: Bound

// The panel Battery.qml opens under the bar: the level, state and UPower's
// estimate, the draw and capacity, and the charge history UPower keeps on
// disk — over 6 hours, a day or a week, with the stretches spent charging
// shaded.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import Quickshell.Services.UPower
import "battery.mjs" as Battery

Item {
    id: panel

    required property var theme
    // UPower's DisplayDevice: what the bar shows.
    required property var device
    property string tone: "normal"
    // BatteryAlarm.glow, for the glyph's heartbeat.
    property real glow: 0
    // Whether the panel is open. The history is only fetched then.
    property bool active: false

    // The history lives on the real battery, not on the DisplayDevice.
    readonly property var battery: UPower.devices.values.find(d => d.isLaptopBattery && d.nativePath !== "") ?? null
    readonly property string historyPath: panel.battery ? Battery.historyObjectPath(panel.battery.nativePath) : ""

    readonly property var ranges: [
        { label: "6h", span: 6 * 3600 },
        { label: "24h", span: 24 * 3600 },
        { label: "7d", span: 7 * 24 * 3600 }
    ]
    property int rangeIndex: 1
    readonly property int span: panel.ranges[panel.rangeIndex].span

    // The last answer, kept while a new one is fetched.
    property var history: []
    property real fetchedAt: 0
    property string problem: ""
    // A refresh asked for while a fetch was running.
    property bool stale: false

    readonly property real level: panel.device ? panel.device.percentage * 100 : 0
    readonly property int deviceState: panel.device ? panel.device.state : 0

    implicitWidth: 280
    implicitHeight: content.implicitHeight

    function refresh() {
        if (!panel.active || panel.historyPath === "")
            return;
        if (historyFetch.running) {
            panel.stale = true;
            return;
        }
        historyFetch.running = true;
    }

    function handleHistory(body) {
        const points = Battery.parseHistory(body);
        if (points === null) {
            panel.problem = historyErrors.text.trim() || "UPower returned no history.";
            return;
        }
        panel.problem = "";
        panel.history = points;
        panel.fetchedAt = Date.now() / 1000;
    }

    onActiveChanged: panel.refresh()
    onRangeIndexChanged: panel.refresh()
    onHistoryPathChanged: panel.refresh()

    // One point per pixel or so: UPower averages the samples into this many.
    // It only answers samples inside the timespan, so a quarter more is asked
    // for: the sample before the window gives the level the window opens on.
    Process {
        id: historyFetch
        command: ["busctl", "--system", "--json=short", "call",
                  "org.freedesktop.UPower", panel.historyPath,
                  "org.freedesktop.UPower.Device", "GetHistory", "suu",
                  "charge", String(Math.round(panel.span * 1.25)), "250"]
        stdout: StdioCollector {
            id: historyOutput
            onStreamFinished: panel.handleHistory(historyOutput.text)
        }
        stderr: StdioCollector {
            id: historyErrors
        }
        onRunningChanged: {
            if (!historyFetch.running && panel.stale) {
                panel.stale = false;
                panel.refresh();
            }
        }
    }

    // UPower writes a sample on every 1 % change: a minute is plenty.
    Timer {
        interval: 60 * 1000
        running: panel.active
        repeat: true
        onTriggered: panel.refresh()
    }

    component Heading: Text {
        topPadding: 10
        bottomPadding: 4
        font.pixelSize: 11
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.4
    }

    Column {
        id: content
        width: parent.width
        spacing: 4

        // Glyph, level, state; the estimate on the right.
        Item {
            width: parent.width
            implicitHeight: 22

            BatteryIcon {
                id: headIcon
                anchors.verticalCenter: parent.verticalCenter
                theme: panel.theme
                level: panel.level / 100
                tone: panel.tone
                glow: panel.glow
            }
            Text {
                id: headLevel
                anchors.left: headIcon.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: Battery.percent(panel.level / 100)
                color: panel.theme.fgColor
                font.pixelSize: 12
                font.bold: true
                font.features: { "tnum": 1 }
            }
            Text {
                anchors.left: headLevel.right
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                text: Battery.stateLabel(panel.deviceState)
                color: panel.tone === "charging" ? panel.theme.goodColor : panel.theme.dimColor
                font.pixelSize: 12
            }
            Text {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: panel.device ? Battery.remaining(panel.deviceState, panel.device.timeToEmpty, panel.device.timeToFull) : ""
                color: panel.theme.fgColor
                font.pixelSize: 12
                font.features: { "tnum": 1 }
            }
        }

        // Draw, energy and health, each only when UPower knows it.
        Text {
            width: parent.width
            elide: Text.ElideRight
            text: {
                const d = panel.device;
                if (!d)
                    return "";
                const parts = [];
                // UPower's rate is unsigned whatever Quickshell's docs say:
                // the state tells charging from draining.
                if (Math.abs(d.changeRate) >= 0.05)
                    parts.push((panel.deviceState === Battery.STATE.Charging ? "+" : "")
                               + Math.abs(d.changeRate).toFixed(1) + " W");
                if (d.energyCapacity > 0)
                    parts.push(d.energy.toFixed(1) + " of " + d.energyCapacity.toFixed(1) + " Wh");
                const b = panel.battery;
                if (b && b.healthSupported && b.healthPercentage > 0)
                    parts.push("health " + Math.round(b.healthPercentage) + "%");
                return parts.join("  ·  ");
            }
            color: panel.theme.dimColor
            font.pixelSize: 11
            font.features: { "tnum": 1 }
        }

        // "History", and the range picker on the same line.
        Item {
            width: parent.width
            implicitHeight: historyHeading.implicitHeight

            Heading {
                id: historyHeading
                text: "History"
                color: panel.theme.dimColor
            }
            Row {
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 2
                spacing: 2

                Repeater {
                    model: panel.ranges

                    Rectangle {
                        id: rangeButton
                        required property var modelData
                        required property int index
                        readonly property bool current: rangeButton.index === panel.rangeIndex

                        width: rangeLabel.implicitWidth + 12
                        height: 18
                        radius: 4
                        color: rangeButton.current ? panel.theme.trackColor
                            : rangeMouse.containsMouse ? panel.theme.hoverColor
                            : "transparent"

                        Text {
                            id: rangeLabel
                            anchors.centerIn: parent
                            text: rangeButton.modelData.label
                            color: rangeButton.current ? panel.theme.fgColor : panel.theme.dimColor
                            font.pixelSize: 11
                        }
                        MouseArea {
                            id: rangeMouse
                            anchors.fill: parent
                            hoverEnabled: true
                            onClicked: panel.rangeIndex = rangeButton.index
                        }
                    }
                }
            }
        }

        // The charge over the range: 0 % at the bottom, 50 and 100 % ruled.
        Item {
            id: graph
            width: parent.width
            height: 84

            readonly property var plotted: Battery.plotHistory(panel.history, {
                now: panel.fetchedAt,
                span: panel.span,
                level: panel.level,
                width: graph.width,
                height: graph.height
            })
            readonly property var line: graph.plotted.map(p => Qt.point(p.x, p.y))

            Repeater {
                model: Battery.chargingSpans(panel.history, {
                    now: panel.fetchedAt,
                    span: panel.span,
                    width: graph.width,
                    charging: panel.deviceState === Battery.STATE.Charging
                })

                Rectangle {
                    required property var modelData
                    x: modelData.x
                    width: modelData.width
                    height: graph.height
                    color: Qt.alpha(panel.theme.goodColor, 0.12)
                }
            }

            Repeater {
                model: [0, 0.5, 1]

                Rectangle {
                    required property real modelData
                    y: Math.round(graph.height * (1 - modelData))
                    width: graph.width
                    height: 1
                    color: panel.theme.lineColor
                }
            }
            Text {
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: 2
                text: "100%"
                color: panel.theme.dimColor
                font.pixelSize: 9
            }
            Text {
                anchors.right: parent.right
                y: Math.round(graph.height / 2) + 2
                text: "50%"
                color: panel.theme.dimColor
                font.pixelSize: 9
            }

            Shape {
                anchors.fill: parent
                visible: panel.fetchedAt > 0
                preferredRendererType: Shape.CurveRenderer

                ShapePath {
                    strokeColor: "transparent"
                    fillColor: Qt.alpha(panel.theme.accentColor, 0.15)
                    PathPolyline {
                        // Closed under the line only: with no sample before the
                        // window, the line starts inside it.
                        path: graph.line.concat([
                            Qt.point(graph.line[graph.line.length - 1].x, graph.height),
                            Qt.point(graph.line[0].x, graph.height)
                        ])
                    }
                }
                ShapePath {
                    strokeColor: panel.theme.accentColor
                    strokeWidth: 1.5
                    fillColor: "transparent"
                    joinStyle: ShapePath.RoundJoin
                    capStyle: ShapePath.RoundCap
                    PathPolyline {
                        path: graph.line
                    }
                }
            }
        }

        // Where the range starts, and where it ends.
        Item {
            width: parent.width
            implicitHeight: startLabel.implicitHeight

            Text {
                id: startLabel
                text: panel.fetchedAt > 0
                    ? Qt.formatDateTime(new Date((panel.fetchedAt - panel.span) * 1000),
                                        panel.span > 24 * 3600 ? "ddd HH:mm" : "HH:mm")
                    : ""
                color: panel.theme.dimColor
                font.pixelSize: 10
            }
            Text {
                anchors.right: parent.right
                text: "now"
                color: panel.theme.dimColor
                font.pixelSize: 10
            }
        }

        Text {
            visible: panel.problem !== "" || panel.historyPath === ""
            width: parent.width
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
            text: panel.historyPath === "" ? "No battery with a history found." : panel.problem
            color: panel.theme.warnColor
            font.pixelSize: 11
        }

        Item {
            width: 1
            height: 4
        }
    }
}
