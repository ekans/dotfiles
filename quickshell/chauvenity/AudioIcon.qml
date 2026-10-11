pragma ComponentBehavior: Bound

// The volume glyph of the bar and its panel: a speaker or headphones for the
// sink's kind, sound waves that follow the level, a red cross when muted, and
// an accent badge for a Bluetooth or network sink. Drawn rather than taken
// from the icon theme, so it takes the bar's colours.

import QtQuick
import QtQuick.Shapes

Row {
    id: icon

    required property var theme
    // One of audio.mjs sinkKind()'s answers.
    property string kind: "speaker"
    property real level: 0
    property bool muted: false
    property color ink: icon.theme.fgColor

    readonly property bool headphones: icon.kind === "headphones" || icon.kind === "bluetooth"

    spacing: 1

    // One SVG path in a 16-unit box, stroked or filled.
    component Glyph: Shape {
        id: glyph
        required property string d
        required property color ink
        property bool filled: false
        anchors.fill: parent
        preferredRendererType: Shape.CurveRenderer

        ShapePath {
            strokeColor: glyph.filled ? "transparent" : glyph.ink
            strokeWidth: 1.4
            fillColor: glyph.filled ? glyph.ink : "transparent"
            capStyle: ShapePath.RoundCap
            joinStyle: ShapePath.RoundJoin
            PathSvg { path: glyph.d }
        }
    }

    Item {
        visible: icon.kind === "bluetooth" || icon.kind === "network"
        width: 8
        height: 16

        Glyph {
            visible: icon.kind === "bluetooth"
            ink: icon.theme.accentColor
            d: "M1 5l6 6-3 3V2l3 3-6 6"
        }
        Glyph {
            visible: icon.kind === "network"
            ink: icon.theme.accentColor
            d: "M0.8 8.5a4.5 4.5 0 0 1 6.4 0M2.3 10.6a2.3 2.3 0 0 1 3.4 0M4 13v0.1"
        }
    }

    Item {
        width: 16
        height: 16

        Glyph {
            visible: !icon.headphones
            filled: true
            ink: icon.ink
            d: "M2 6.2h2.6L8.2 3v10L4.6 9.8H2z"
        }
        Glyph {
            visible: !icon.headphones && !icon.muted && icon.level > 0.005
            ink: icon.ink
            d: "M10.5 5.8a3 3 0 0 1 0 4.4"
        }
        Glyph {
            visible: !icon.headphones && !icon.muted && icon.level >= 0.5
            ink: icon.ink
            d: "M12.4 3.9a5.6 5.6 0 0 1 0 8.2"
        }
        Glyph {
            visible: icon.headphones
            ink: icon.ink
            d: "M2.5 10.5V8.5a5.5 5.5 0 0 1 11 0v2"
        }
        Glyph {
            visible: icon.headphones
            filled: true
            ink: icon.ink
            d: "M2 10.5a1 1 0 0 1 1-1h1a1 1 0 0 1 1 1V13a1 1 0 0 1-1 1H3a1 1 0 0 1-1-1zM11 10.5a1 1 0 0 1 1-1h1a1 1 0 0 1 1 1V13a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1z"
        }
        Glyph {
            visible: icon.muted
            ink: icon.theme.badColor
            d: icon.headphones ? "M6.3 9l3.4 3.4M9.7 9l-3.4 3.4" : "M11 6l4 4M15 6l-4 4"
        }
    }
}
