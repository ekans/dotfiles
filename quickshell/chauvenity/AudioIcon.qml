pragma ComponentBehavior: Bound

// The volume glyph of the bar and its panel: a speaker or headphones for the
// sink's kind, sound waves that follow the level, a red cross when muted, and
// an accent badge for a Bluetooth or network sink. An input is a microphone
// instead, without waves. Drawn rather than taken from the icon theme, so it
// takes the bar's colours.

import QtQuick
import QtQuick.Shapes

Row {
    id: icon

    required property var theme
    // One of audio.mjs nodeKind()'s answers; only its badge shows on an input.
    property string kind: "speaker"
    // A source: a microphone rather than a speaker or headphones.
    property bool input: false
    property real level: 0
    property bool muted: false
    property color ink: icon.theme.fgColor

    readonly property bool headphones: !icon.input && (icon.kind === "headphones" || icon.kind === "bluetooth")
    readonly property bool speaker: !icon.input && !icon.headphones

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
            visible: icon.speaker
            filled: true
            ink: icon.ink
            d: "M2 6.2h2.6L8.2 3v10L4.6 9.8H2z"
        }
        Glyph {
            visible: icon.speaker && !icon.muted && icon.level > 0.005
            ink: icon.ink
            d: "M10.5 5.8a3 3 0 0 1 0 4.4"
        }
        Glyph {
            visible: icon.speaker && !icon.muted && icon.level >= 0.5
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
            visible: icon.input
            filled: true
            ink: icon.ink
            d: "M8 1.5A2.5 2.5 0 0 1 10.5 4v3.5a2.5 2.5 0 0 1-5 0V4A2.5 2.5 0 0 1 8 1.5z"
        }
        Glyph {
            visible: icon.input
            ink: icon.ink
            d: "M3.5 7.5a4.5 4.5 0 0 0 9 0M8 12v2.5M5.5 14.5h5"
        }
        Glyph {
            visible: icon.muted
            ink: icon.theme.badColor
            d: icon.input ? "M10 8.5l4.5 4.5M14.5 8.5L10 13"
                : icon.headphones ? "M6.3 9l3.4 3.4M9.7 9l-3.4 3.4"
                : "M11 6l4 4M15 6l-4 4"
        }
    }
}
