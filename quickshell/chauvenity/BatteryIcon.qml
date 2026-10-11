pragma ComponentBehavior: Bound

// The battery glyph of the bar and its panel: an outline whose fill follows
// the level in the tone's colour. Drawn rather than taken from the icon theme,
// so it takes the bar's colours.
//
// While charging a bolt sits across it and a bright fifth of the outline runs
// round it, like current in a circuit. At 5 % or below on battery (the "alert" tone)
// the outline turns the bad colour, a "!" replaces the level, and the inside
// flashes twice every two seconds, a heartbeat. The Timer starts each beat, so
// between beats nothing animates and the bar is not redrawn: the alert runs
// on an almost empty battery.

import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    required property var theme
    property real level: 0
    // One of battery.mjs batteryTone()'s answers.
    property string tone: "normal"

    readonly property bool charging: icon.tone === "charging"
    readonly property bool alert: icon.tone === "alert"
    readonly property color fill: icon.charging ? icon.theme.goodColor
        : icon.alert || icon.tone === "critical" ? icon.theme.badColor
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
        opacity: 0
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

    Timer {
        interval: 2000
        repeat: true
        triggeredOnStart: true
        running: icon.alert
        onTriggered: beat.restart()
    }

    // Two flashes, the second longer, then still: about 0.75 s of the 2 s.
    SequentialAnimation {
        id: beat

        OpacityAnimator { target: alarm; from: 0; to: 0.75; duration: 90; easing.type: Easing.OutQuad }
        OpacityAnimator { target: alarm; from: 0.75; to: 0; duration: 180; easing.type: Easing.InQuad }
        PauseAnimation { duration: 70 }
        OpacityAnimator { target: alarm; from: 0; to: 0.75; duration: 90; easing.type: Easing.OutQuad }
        OpacityAnimator { target: alarm; from: 0.75; to: 0; duration: 320; easing.type: Easing.InQuad }
    }

    // The charging trace: ShapePath.trim (Qt 6.10) shows a fifth of the
    // outline and trim.offset walks it round, wrapping past the start.
    Shape {
        visible: icon.charging
        anchors.fill: body
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            id: trace
            strokeColor: icon.theme.goodColor
            strokeWidth: 1.2
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            trim.end: 0.22

            PathRectangle {
                x: 0.5
                y: 0.5
                width: body.width - 1
                height: body.height - 1
                radius: body.radius - 0.5
            }
        }

        NumberAnimation {
            target: trace
            property: "trim.offset"
            from: 0
            to: 1
            duration: 1800
            loops: Animation.Infinite
            running: icon.charging
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
