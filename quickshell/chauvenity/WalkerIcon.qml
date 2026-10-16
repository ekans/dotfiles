// The walkpad's glyph: a walker over a belt, drawn with QtQuick.Shapes like
// the bar's other icons. fgColor when lit (the pad connected), dimColor
// otherwise.

import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    required property var theme
    property bool lit: false

    readonly property color ink: icon.lit ? icon.theme.fgColor : icon.theme.dimColor

    implicitWidth: 14
    implicitHeight: 16

    Rectangle {
        x: 5.2
        y: 0.5
        width: 3.6
        height: 3.6
        radius: 1.8
        color: icon.ink
    }

    // Body leaning into the step, an arm each way, a leg ahead and a leg behind.
    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: icon.ink
            strokeWidth: 1.5
            fillColor: "transparent"
            joinStyle: ShapePath.RoundJoin
            capStyle: ShapePath.RoundCap
            PathSvg { path: "M7.4 5 L6.6 9 M7.2 6.4 L4.6 8 M7.2 6.4 L9.8 7.4 M6.6 9 L9 11.4 L9.6 13.2 M6.6 9 L4.4 11.2 L2.8 12.6" }
        }
    }

    // The belt under the feet.
    Rectangle {
        x: 0.5
        y: 14
        width: icon.width - 1
        height: 1.5
        radius: 0.75
        color: icon.ink
    }
}
