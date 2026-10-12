pragma ComponentBehavior: Bound

// Claude Code usage, as the bar shows it: the 5h window against linear pace,
// always, plus the other window furthest ahead of pace when that is more than
// 5 points — e.g. `claude 5h 26% ≈+2 · fable 44% ▲+12`. Clicking it opens
// ClaudeUsagePanel with all three windows.
//
// shell.qml polls the numbers through claude-usage-fetch.sh.

import QtQuick
import QtQuick.Shapes
import Quickshell
import Quickshell.Wayland
import "claude-pace.mjs" as Pace

Item {
    id: usage

    required property var theme
    // shell.qml's barPanels: opening this panel closes any other.
    required property var panels
    // Its hint, as shell.qml's `keyboard` section describes: the name
    // `ipc call bar toggle` takes, and the letter it asks for.
    property string hintName: "claude"
    property string hintKey: "c"
    // A ring and a percentage, where the bar is narrow.
    property bool compact: false
    required property var summary
    required property date now

    readonly property var shown: Pace.barWindows(usage.summary.windows)
    // The window furthest into its allowance, which the ring stands for.
    readonly property var busiest: usage.summary.windows.filter(w => w.measured).reduce((a, b) => !a || b.used > a.used ? b : a, null)

    implicitWidth: (usage.compact ? ring.implicitWidth : indicator.implicitWidth) + 12
    implicitHeight: 22

    function toneColor(tone) {
        return {
            good: usage.theme.goodColor,
            warn: usage.theme.warnColor,
            bad: usage.theme.badColor
        }[tone] ?? usage.theme.dimColor;
    }

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse || panel.visible ? usage.theme.hoverColor : "transparent"
    }

    Row {
        id: ring
        visible: usage.compact
        anchors.centerIn: parent
        spacing: 5

        Shape {
            anchors.verticalCenter: parent.verticalCenter
            width: 14
            height: 14
            preferredRendererType: Shape.CurveRenderer

            ShapePath {
                strokeColor: usage.theme.trackColor
                strokeWidth: 2
                fillColor: "transparent"
                PathAngleArc {
                    centerX: 7
                    centerY: 7
                    radiusX: 6
                    radiusY: 6
                    startAngle: 0
                    sweepAngle: 360
                }
            }
            ShapePath {
                strokeColor: usage.toneColor(usage.busiest?.tone)
                strokeWidth: 2
                fillColor: "transparent"
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: 7
                    centerY: 7
                    radiusX: 6
                    radiusY: 6
                    startAngle: -90
                    sweepAngle: 360 * Math.min(100, Math.max(0, usage.busiest?.used ?? 0)) / 100
                }
            }
        }

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: usage.busiest ? Math.round(usage.busiest.used) + "%" : "–"
            color: usage.theme.fgColor
            font.pixelSize: 12
        }
    }

    Row {
        id: indicator
        visible: !usage.compact
        anchors.centerIn: parent
        spacing: 6

        Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "claude"
            color: usage.theme.dimColor
            font.pixelSize: 12
        }

        Repeater {
            model: usage.shown

            Row {
                id: item
                required property var modelData
                required property int index

                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Text {
                    visible: item.index > 0
                    text: "·"
                    color: usage.theme.dimColor
                    font.pixelSize: 12
                }
                Text {
                    text: item.modelData.label
                    color: usage.theme.dimColor
                    font.pixelSize: 12
                }
                Text {
                    text: Math.round(item.modelData.used) + "%"
                    color: usage.theme.fgColor
                    font.pixelSize: 12
                }
                Text {
                    text: Pace.deltaText(item.modelData.delta).replace(" ", "")
                    color: usage.toneColor(item.modelData.tone)
                    font.pixelSize: 12
                }
            }
        }
    }

    // Opens or closes ClaudeUsagePanel, closing any other panel. A click, the bar's
    // hints and `qs -c chauvenity ipc call bar toggle claude` all come here.
    function toggle() {
        usage.panels.toggle(panel);
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: usage.toggle()
    }

    PopupWindow {
        id: panel
        visible: false
        onVisibleChanged: {
            if (panel.visible)
                panelKeys.forceActiveFocus();
        }
        // Closes it on a click in another client; a click on the bar goes
        // through barPanels in shell.qml.
        grabFocus: true
        color: "transparent"
        // niri blurs the windows behind a popup (popups are not "xray").
        BackgroundEffect.blurRegion: Region {
            item: sheet
            radius: sheet.radius
        }
        implicitWidth: content.implicitWidth + 28
        implicitHeight: content.implicitHeight + 16

        // Right-aligned under the indicator, placed through the rect alone:
        // `anchor.edges` and `anchor.gravity` are untyped in Quickshell's
        // qmltypes, so qmllint flags them.
        anchor.item: usage
        anchor.rect.x: usage.width - panel.implicitWidth
        anchor.rect.y: usage.height + 6

        // Translucent over niri's blur.
        Rectangle {
            id: sheet
            anchors.fill: parent
            radius: 8
            color: Qt.alpha(usage.theme.panelColor, 0.75)
            border.color: usage.theme.lineColor
        }

        // Escape closes it. Qt hands the panel the bar's keys while it is
        // open, but focus has to be asked for each time it opens.
        Item {
            id: panelKeys
            Keys.onEscapePressed: usage.panels.close()
        }

        ClaudeUsagePanel {
            id: content
            x: 14
            y: 4
            theme: usage.theme
            summary: usage.summary
            now: usage.now
        }
    }
}
