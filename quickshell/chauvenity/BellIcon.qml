// The bell of the bar's notifications indicator, crossed out while
// do-not-disturb is on. Drawn rather than taken from the icon theme, so it
// takes the bar's colours.

import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    required property var theme
    property bool muted: false
    property color ink: icon.theme.fgColor

    implicitWidth: 16
    implicitHeight: 16

    Shape {
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: icon.ink
            strokeWidth: 1.4
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: "M4 10.8V7.2a4 4 0 0 1 8 0v3.6l1.3 1.6H2.7zM6.5 14.2a1.6 1.6 0 0 0 3 0" }
        }
        ShapePath {
            strokeColor: icon.muted ? icon.theme.badColor : "transparent"
            strokeWidth: 1.4
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathSvg { path: "M2.2 2.2l11.6 11.6" }
        }
    }
}
