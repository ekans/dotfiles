// The bar's light/dark switch: a sun while apps are light, a moon while they
// are dark. No panel; a click flips it. The scheme it shows and sets lives in
// shell.qml. Drawn rather than taken from the icon theme, so it takes the
// bar's colours.

import QtQuick
import QtQuick.Shapes

Item {
    id: appearance

    required property var theme
    // "light" or "dark"; "" until gsettings has answered, and nothing shows.
    required property string mode
    // Its hint, as shell.qml's `keyboard` section describes; hints.mjs picks
    // the letter.
    property string hintName: "appearance"

    signal flipped()

    visible: appearance.mode !== ""
    implicitWidth: 16 + 12
    implicitHeight: 22

    Rectangle {
        anchors.fill: parent
        radius: 4
        color: mouse.containsMouse ? appearance.theme.hoverColor : "transparent"
    }

    Shape {
        anchors.centerIn: parent
        width: 16
        height: 16
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: appearance.theme.fgColor
            strokeWidth: 1.4
            fillColor: "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg {
                path: appearance.mode === "dark"
                    ? "M13.5 9.5a5.5 5.5 0 1 1-7-7a4.5 4.5 0 0 0 7 7z"
                    : "M8 5a3 3 0 1 1 0 6a3 3 0 1 1 0-6zM8 1.5v1.2M8 13.3v1.2M1.5 8h1.2M13.3 8h1.2M3.4 3.4l.85.85M11.75 11.75l.85.85M3.4 12.6l.85-.85M11.75 4.25l.85-.85"
            }
        }
    }

    // A click, the bar's hints and `qs -c chauvenity ipc call bar toggle
    // appearance` all come here.
    function toggle() {
        appearance.flipped();
    }

    MouseArea {
        id: mouse
        anchors.fill: parent
        hoverEnabled: true
        onClicked: appearance.toggle()
    }
}
