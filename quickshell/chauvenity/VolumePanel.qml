pragma ComponentBehavior: Bound

// The panel Volume.qml opens under the bar: the default sink's level, a
// picker for the output, the level of each stream playing into it, and below
// them the same again for the microphone: the default source's level and a
// picker for the input.
// From the keyboard, the arrows step the level, M mutes, and 1–9 pick the
// device listed under that number; with Shift they act on the microphone.

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
    readonly property var source: Pipewire.defaultAudioSource
    readonly property var sources: Pipewire.nodes.values.filter(n => n.type === PwNodeType.AudioSource)
    // The outputs offered: not the ones nothing is plugged into, unless it is
    // the current one.
    property var unplugged: []
    readonly property var shownSinks: panel.sinks
        .filter(n => n === panel.sink || panel.unplugged.indexOf(n.name) < 0)
    readonly property var streams: links.linkGroups
        .map(group => group.source)
        .filter(n => !!n && n.isStream)

    // The two device directions, each shown and driven the same way: what the
    // head row and slider show (`node`, the default), what the picker lists
    // (`nodes`) and how a pick takes effect.
    readonly property var output: ({
        heading: "Output",
        node: panel.sink,
        nodes: panel.shownSinks,
        pick: node => { Pipewire.preferredDefaultAudioSink = node; },
        input: false
    })
    readonly property var input: ({
        heading: "Input",
        node: panel.source,
        nodes: panel.sources,
        pick: node => { Pipewire.preferredDefaultAudioSource = node; },
        input: true
    })

    implicitWidth: 280
    implicitHeight: content.implicitHeight

    // A key pressed while the panel is open, from Volume.qml. Up and Right
    // step the default sink as a wheel notch does, Down and Left back; M
    // mutes; a digit picks that output. With Shift the same keys act on the
    // default source and the inputs. Answers whether it was one of those.
    function keyPressed(event) {
        const direction = event.modifiers & Qt.ShiftModifier ? panel.input : panel.output;
        const audio = direction.node ? direction.node.audio : null;
        // Shift on the keypad types its navigation keys, so the digit comes
        // from the key's position, before the arrows are asked.
        const shiftedKeypad = (event.modifiers & Qt.ShiftModifier) && (event.modifiers & Qt.KeypadModifier);
        const digit = shiftedKeypad ? Hints.keypadDigit(event.nativeScanCode)
            : Hints.digitKey(event.text, event.nativeScanCode);
        if (digit > 0) {
            if (digit <= direction.nodes.length)
                direction.pick(direction.nodes[digit - 1]);
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Right) {
            if (audio)
                audio.volume = Audio.stepVolume(audio.volume, 1);
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Left) {
            if (audio)
                audio.volume = Audio.stepVolume(audio.volume, -1);
        } else if (event.key === Qt.Key_M) {
            if (audio)
                audio.muted = !audio.muted;
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
        objects: panel.active ? panel.shownSinks.concat(panel.sources, panel.streams) : []
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

    // One device direction from the records above: the default node's glyph
    // (click to mute), name and level, its slider, and the picker.
    component DeviceBlock: Column {
        id: block

        required property var theme
        required property var direction
        readonly property var node: block.direction.node

        spacing: 4

        Item {
            width: parent.width
            implicitHeight: 22

            AudioIcon {
                id: headIcon
                anchors.verticalCenter: parent.verticalCenter
                theme: block.theme
                kind: block.node ? Audio.nodeKind(block.node.name, block.node.properties) : "speaker"
                input: block.direction.input
                level: block.node && block.node.audio ? block.node.audio.volume : 0
                muted: !!(block.node && block.node.audio && block.node.audio.muted)
                ink: block.theme.fgColor
            }
            MouseArea {
                anchors.fill: headIcon
                anchors.margins: -3
                onClicked: {
                    if (block.node && block.node.audio)
                        block.node.audio.muted = !block.node.audio.muted;
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
                text: block.node ? Audio.sinkLabel(block.node.description, block.node.name)
                    : "No " + block.direction.heading.toLowerCase()
                color: block.theme.fgColor
                font.pixelSize: 12
                font.bold: true
            }
            Text {
                id: headLevel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: !(block.node && block.node.audio) ? ""
                    : block.node.audio.muted ? "muted"
                    : Audio.percent(block.node.audio.volume)
                color: !(block.node && block.node.audio) || block.node.audio.muted ? block.theme.dimColor
                    : block.node.audio.volume > 1.0005 ? block.theme.warnColor
                    : block.theme.fgColor
                font.pixelSize: 12
                font.features: { "tnum": 1 }
            }
        }

        LevelSlider {
            width: parent.width
            theme: block.theme
            node: block.node
        }

        Heading {
            text: block.direction.heading
            color: block.theme.dimColor
        }

        Repeater {
            model: block.direction.nodes

            Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool current: row.modelData === block.node

                width: block.width
                implicitHeight: 24

                Rectangle {
                    anchors.fill: parent
                    anchors.leftMargin: -6
                    anchors.rightMargin: -6
                    radius: 4
                    color: rowMouse.containsMouse ? block.theme.hoverColor : "transparent"
                }
                Rectangle {
                    id: dot
                    anchors.verticalCenter: parent.verticalCenter
                    width: 8
                    height: 8
                    radius: 4
                    color: row.current ? block.theme.accentColor : "transparent"
                    border.color: row.current ? block.theme.accentColor : block.theme.dimColor
                }
                AudioIcon {
                    id: rowIcon
                    anchors.left: dot.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    theme: block.theme
                    kind: Audio.nodeKind(row.modelData.name, row.modelData.properties)
                    input: block.direction.input
                    level: 1
                    ink: row.current ? block.theme.fgColor : block.theme.dimColor
                }
                Text {
                    anchors.left: rowIcon.right
                    anchors.leftMargin: 6
                    anchors.right: rowKey.left
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: Audio.sinkLabel(row.modelData.description, row.modelData.name)
                    color: row.current ? block.theme.fgColor : block.theme.dimColor
                    font.pixelSize: 12
                }
                // The digit that picks it, as a menu shows a shortcut.
                Text {
                    id: rowKey
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.index < 9 ? String(row.index + 1) : ""
                    color: block.theme.dimColor
                    font.pixelSize: 11
                    font.features: { "tnum": 1 }
                }
                MouseArea {
                    id: rowMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    onClicked: block.direction.pick(row.modelData)
                }
            }
        }
    }

    Column {
        id: content
        width: parent.width
        spacing: 4

        DeviceBlock {
            width: parent.width
            theme: panel.theme
            direction: panel.output
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

        Item {
            width: 1
            height: 8
        }

        DeviceBlock {
            width: parent.width
            theme: panel.theme
            direction: panel.input
        }

        Text {
            topPadding: 10
            text: "↑↓ volume · M mute · 1–9 output · Esc close\nShift: the same for the microphone"
            color: panel.theme.dimColor
            font.pixelSize: 11
        }

        Item {
            width: 1
            height: 4
        }
    }
}
