pragma ComponentBehavior: Bound

// The panel Volume.qml opens under the bar: the default sink's level, a
// picker for the output, and the level of each stream playing into it.
// From the keyboard, the arrows step the level, M mutes, and 1–9 pick the
// output listed under that number.

import QtQuick
import Quickshell.Io
import Quickshell.Services.Pipewire
import "audio.mjs" as Audio
import "hints.mjs" as Hints

Item {
    id: panel

    required property var theme
    // Whether the panel is open. The nodes it lists are only tracked then:
    // PipeWire reports no volume for a node nothing tracks.
    property bool active: false

    readonly property var sink: Pipewire.defaultAudioSink
    readonly property var sinks: Pipewire.nodes.values.filter(n => n.type === PwNodeType.AudioSink)
    // The outputs offered: not the ones nothing is plugged into, unless it is
    // the current one.
    property var unplugged: []
    readonly property var shownSinks: panel.sinks
        .filter(n => n === panel.sink || panel.unplugged.indexOf(n.name) < 0)
    readonly property var streams: links.linkGroups
        .map(group => group.source)
        .filter(n => !!n && n.isStream)

    implicitWidth: 280
    implicitHeight: content.implicitHeight

    // A key pressed while the panel is open, from Volume.qml. Up and Right
    // step the default sink as a wheel notch does, Down and Left back; M
    // mutes; a digit picks that output. Answers whether it was one of those.
    function keyPressed(event) {
        const audio = panel.sink ? panel.sink.audio : null;
        const digit = Hints.digitKey(event.text, event.nativeScanCode);
        if (event.key === Qt.Key_Up || event.key === Qt.Key_Right) {
            if (audio)
                audio.volume = Audio.stepVolume(audio.volume, 1);
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Left) {
            if (audio)
                audio.volume = Audio.stepVolume(audio.volume, -1);
        } else if (event.key === Qt.Key_M) {
            if (audio)
                audio.muted = !audio.muted;
        } else if (digit > 0) {
            if (digit <= panel.shownSinks.length)
                Pipewire.preferredDefaultAudioSink = panel.shownSinks[digit - 1];
        } else {
            return false;
        }
        return true;
    }

    PwNodeLinkTracker {
        id: links
        node: panel.sink
    }

    PwObjectTracker {
        objects: panel.active ? panel.shownSinks.concat(panel.streams) : []
    }

    // PipeWire's node objects don't say whether a port has anything behind
    // it; pulse's view of the card does. Read on opening, and whenever a sink
    // comes or goes while open.
    property bool stale: false

    function refresh() {
        if (!panel.active)
            return;
        if (portsFetch.running)
            panel.stale = true;
        else
            portsFetch.running = true;
    }

    onActiveChanged: panel.refresh()
    onSinksChanged: panel.refresh()

    Process {
        id: portsFetch
        command: ["pactl", "-f", "json", "list", "sinks"]
        stdout: StdioCollector {
            id: portsOutput
            onStreamFinished: panel.unplugged = Audio.unpluggedSinks(portsOutput.text)
        }
        onRunningChanged: {
            if (!portsFetch.running && panel.stale) {
                panel.stale = false;
                panel.refresh();
            }
        }
    }

    // A node's level, 0–100 %, set by clicking or dragging along it. Past
    // 100 % the fill is full and in the warn colour.
    component LevelSlider: Item {
        id: slider

        required property var theme
        required property var node

        readonly property real level: slider.node && slider.node.audio ? slider.node.audio.volume : 0
        readonly property bool muted: !!(slider.node && slider.node.audio && slider.node.audio.muted)

        implicitHeight: 16

        function setFrom(x) {
            if (slider.node && slider.node.audio)
                slider.node.audio.volume = Math.max(0, Math.min(1, x / slider.width));
        }

        Rectangle {
            id: track
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            height: 6
            radius: 3
            color: slider.theme.trackColor
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: track.width * Math.min(1, slider.level)
            height: 6
            radius: 3
            color: slider.muted ? slider.theme.dimColor
                : slider.level > 1.0005 ? slider.theme.warnColor
                : slider.theme.accentColor
        }
        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            x: track.width * Math.min(1, slider.level) - width / 2
            width: 10
            height: 10
            radius: 5
            color: slider.muted ? slider.theme.dimColor : slider.theme.fgColor
        }
        MouseArea {
            anchors.fill: parent
            preventStealing: true
            onPressed: event => slider.setFrom(event.x)
            onPositionChanged: event => slider.setFrom(event.x)
        }
    }

    component Heading: Text {
        topPadding: 10
        bottomPadding: 2
        font.pixelSize: 11
        font.capitalization: Font.AllUppercase
        font.letterSpacing: 0.4
    }

    Column {
        id: content
        width: parent.width
        spacing: 4

        // The default sink: glyph (click to mute), name, level.
        Item {
            width: parent.width
            implicitHeight: 22

            AudioIcon {
                id: headIcon
                anchors.verticalCenter: parent.verticalCenter
                theme: panel.theme
                kind: panel.sink ? Audio.sinkKind(panel.sink.name, panel.sink.properties) : "speaker"
                level: panel.sink && panel.sink.audio ? panel.sink.audio.volume : 0
                muted: !!(panel.sink && panel.sink.audio && panel.sink.audio.muted)
                ink: panel.theme.fgColor
            }
            MouseArea {
                anchors.fill: headIcon
                anchors.margins: -3
                onClicked: {
                    if (panel.sink && panel.sink.audio)
                        panel.sink.audio.muted = !panel.sink.audio.muted;
                }
            }
            Text {
                anchors.left: headIcon.right
                anchors.leftMargin: 8
                anchors.right: headLevel.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: panel.sink ? Audio.sinkLabel(panel.sink.description, panel.sink.name) : "No output"
                color: panel.theme.fgColor
                font.pixelSize: 12
                font.bold: true
            }
            Text {
                id: headLevel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: !(panel.sink && panel.sink.audio) ? ""
                    : panel.sink.audio.muted ? "muted"
                    : Audio.percent(panel.sink.audio.volume)
                color: !(panel.sink && panel.sink.audio) || panel.sink.audio.muted ? panel.theme.dimColor
                    : panel.sink.audio.volume > 1.0005 ? panel.theme.warnColor
                    : panel.theme.fgColor
                font.pixelSize: 12
                font.features: { "tnum": 1 }
            }
        }

        LevelSlider {
            width: parent.width
            theme: panel.theme
            node: panel.sink
        }

        Heading {
            text: "Output"
            color: panel.theme.dimColor
        }

        Repeater {
            model: panel.shownSinks

            Item {
                id: sinkRow
                required property var modelData
                required property int index
                readonly property bool current: sinkRow.modelData === panel.sink

                width: content.width
                implicitHeight: 24

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: -6
                    anchors.rightMargin: -6
                    radius: 4
                    color: sinkMouse.containsMouse ? panel.theme.hoverColor : "transparent"
                }
                Rectangle {
                    id: dot
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: sinkRow.current ? panel.theme.accentColor : "transparent"
                    border.color: sinkRow.current ? panel.theme.accentColor : panel.theme.dimColor
                }
                AudioIcon {
                    id: sinkIcon
                    anchors.left: dot.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    theme: panel.theme
                    kind: Audio.sinkKind(sinkRow.modelData.name, sinkRow.modelData.properties)
                    level: 1
                    ink: sinkRow.current ? panel.theme.fgColor : panel.theme.dimColor
                }
                Text {
                    anchors.left: sinkIcon.right
                    anchors.leftMargin: 6
                    anchors.right: sinkKey.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Audio.sinkLabel(sinkRow.modelData.description, sinkRow.modelData.name)
                    color: sinkRow.current ? panel.theme.fgColor : panel.theme.dimColor
                    font.pixelSize: 12
                }
                // The digit that picks it, as a menu shows a shortcut.
                Text {
                    id: sinkKey
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: sinkRow.index < 9 ? String(sinkRow.index + 1) : ""
                    color: panel.theme.dimColor
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                }
                MouseArea {
                    id: sinkMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: Pipewire.preferredDefaultAudioSink = sinkRow.modelData
                }
            }
        }

        Heading {
            text: "Playing"
            color: panel.theme.dimColor
        }

        Text {
            visible: panel.streams.length === 0
            text: "Nothing is playing."
            color: panel.theme.dimColor
            font.pixelSize: 11
        }

        Repeater {
            model: panel.streams

            Item {
                id: streamRow
                required property var modelData

                width: content.width
                implicitHeight: 22

                Text {
                    id: streamName
                    anchors.verticalCenter: parent.verticalCenter
                    width: 84
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Audio.streamLabel(streamRow.modelData.properties,
                                            streamRow.modelData.description,
                                            streamRow.modelData.name)
                    color: panel.theme.fgColor
                    font.pixelSize: 12
                }
                LevelSlider {
                    anchors.left: streamName.right
                    anchors.leftMargin: 8
                    anchors.right: streamLevel.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    theme: panel.theme
                    node: streamRow.modelData
                }
                Text {
                    id: streamLevel
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 34
                    horizontalAlignment: Text.AlignRight
                    text: streamRow.modelData.audio ? Audio.percent(streamRow.modelData.audio.volume) : ""
                    color: panel.theme.dimColor
                    font.pixelSize: 12
                    font.features: { "tnum": 1 }
                }
            }
        }

        Text {
            topPadding: 10
            text: "↑↓ volume · M mute · 1–9 output · Esc close"
            color: panel.theme.dimColor
            font.pixelSize: 11
        }

        Item {
            width: 1
            height: 4
        }
    }
}
