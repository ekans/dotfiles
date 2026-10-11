// The cup of the bar's caffeine toggle, steaming while it is on. Drawn rather
// than taken from the icon theme, so it takes the bar's colours.

import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    required property var theme
    property bool on: false
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
            PathSvg { path: "M2.5 7h8.5v3a3.5 3.5 0 0 1-3.5 3.5h-1.5a3.5 3.5 0 0 1-3.5-3.5zM11 8h1a1.5 1.5 0 0 1 0 3h-1.2" }
        }
        ShapePath {
            strokeColor: icon.on ? icon.ink : "transparent"
            strokeWidth: 1.4
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            PathSvg { path: "M5.5 2.5v2.5M8 2.5v2.5" }
        }
    }
}
