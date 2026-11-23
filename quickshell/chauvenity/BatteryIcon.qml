pragma ComponentBehavior: Bound

// The battery glyph of the bar and its panel: an outline whose fill follows
// the level in the tone's colour. Drawn rather than taken from the icon theme,
// so it takes the bar's colours.
//
// While charging a bolt sits across it, still: an animation here would redraw
// the bar every frame for as long as the laptop is plugged in. At 10 % or
// below on battery (the "alert" tone) the outline turns the bad colour, a "!"
// replaces the level, and the inside lights up with `glow`, BatteryAlarm's
// heartbeat.

import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    required property var theme
    property real level: 0
    // One of battery.mjs batteryTone()'s answers.
    property string tone: "normal"
    // BatteryAlarm.glow, 0–1: how lit the inside is during the alert.
    property real glow: 0

    readonly property bool charging: icon.tone === "charging"
    readonly property bool alert: icon.tone === "alert"
    readonly property color fill: icon.charging ? icon.theme.goodColor
        : icon.alert ? icon.theme.badColor
        : icon.tone === "low" ? icon.theme.warnColor
        : icon.theme.dimColor
    readonly property color outline: icon.alert ? icon.theme.badColor : icon.theme.dimColor

    implicitWidth: 20
    implicitHeight: 16

    Rectangle {
        id: body
        x: 0.5
        y: 3
        width: 17
        height: 10
        radius: 2.5
        color: "transparent"
        border.width: 1
        border.color: icon.outline
    }
    Rectangle {
        x: body.x + body.width + 0.5
        y: 6
        width: 1.5
        height: 4
        radius: 0.75
        color: icon.outline
    }
    Rectangle {
        x: body.x + 2
        y: body.y + 2
        width: Math.max(1, (body.width - 4) * Math.min(1, Math.max(0, icon.level)))
        height: body.height - 4
        radius: 1
        color: icon.fill
    }

    // The alert: the inside, lit by each beat, and the "!" over it.
    Rectangle {
        id: alarm
        visible: icon.alert
        x: body.x + 1
        y: body.y + 1
        width: body.width - 2
        height: body.height - 2
        radius: body.radius - 1
        color: icon.theme.badColor
        opacity: icon.glow * 0.75
    }
    Item {
        visible: icon.alert
        anchors.fill: body

        Rectangle {
            x: (parent.width - width) / 2
            y: 2
            width: 1.4
            height: 3.6
            radius: 0.7
            color: icon.theme.fgColor
        }
        Rectangle {
            x: (parent.width - width) / 2
            y: 6.6
            width: 1.4
            height: 1.4
            radius: 0.7
            color: icon.theme.fgColor
        }
    }

    Shape {
        visible: icon.charging
        anchors.fill: body
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: icon.theme.bgColor
            strokeWidth: 1
            fillColor: icon.theme.fgColor
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: "M9.6 0.6 5.4 5.6H8.2L7.2 9.4 11.6 4.2H8.8z" }
        }
    }
}
