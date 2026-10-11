pragma ComponentBehavior: Bound

// The network glyph of the bar and its panel: Wi-Fi arcs lit to the signal,
// the unlit ones faint so the fan keeps its shape; struck through when Wi-Fi
// is off; an Ethernet jack for a cable. While connecting, the arcs light one
// after the other. Drawn rather than taken from the icon theme, so it takes
// the bar's colours.

import QtQuick
import QtQuick.Shapes

Item {
    id: icon

    required property var theme
    // One of network.mjs barState()'s glyphs.
    property string kind: "none"
    // Arcs lit, 0..3.
    property int level: 0
    property bool busy: false
    property color ink: icon.theme.fgColor

    // The arcs the connecting sweep has lit.
    property int sweep: 0
    readonly property int lit: icon.busy ? icon.sweep : icon.level

    implicitWidth: 16
    implicitHeight: 16

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

    // Three arcs round the dot at (8, 13.6), each spanning 90°.
    readonly property var arcs: [
        "M5.74 11.34A3.2 3.2 0 0 1 10.26 11.34",
        "M3.47 9.07A6.4 6.4 0 0 1 12.53 9.07",
        "M1.21 6.81A9.6 9.6 0 0 1 14.79 6.81"
    ]

    Item {
        anchors.fill: parent
        visible: icon.kind !== "wired"

        Glyph {
            filled: true
            ink: icon.ink
            d: "M6.9 13.6a1.1 1.1 0 1 0 2.2 0a1.1 1.1 0 1 0 -2.2 0"
        }
        Repeater {
            model: icon.arcs

            Glyph {
                id: arc
                required property string modelData
                required property int index
                ink: icon.ink
                opacity: arc.index < icon.lit && icon.kind === "wifi" ? 1 : 0.3
                d: arc.modelData
            }
        }
        Glyph {
            visible: icon.kind === "off"
            ink: icon.ink
            d: "M2.5 2.5l11 11"
        }
    }

    Glyph {
        visible: icon.kind === "wired"
        ink: icon.ink
        d: "M2.5 5.5h11v7h-11zM6 5.5V3.5h4v2M5.5 12.5v-2M8 12.5v-2M10.5 12.5v-2"
    }

    Timer {
        running: icon.busy
        interval: 350
        repeat: true
        onTriggered: icon.sweep = (icon.sweep + 1) % 4
        onRunningChanged: icon.sweep = 0
    }
}
