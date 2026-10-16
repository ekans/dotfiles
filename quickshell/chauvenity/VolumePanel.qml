pragma ComponentBehavior: Bound

// The panel Volume.qml opens under the bar: the default sink's level, a
// picker for the output, the level of each stream playing into it, and below
// them the same again for the microphone: the default source's level and a
// picker for the input.
// From the keyboard, the arrows step the level, M mutes, T tests, and 1–9 pick
// the device listed under that number; with Shift they act on the microphone.
//
// The output reads and drives Quickshell's PipeWire nodes, as the bar does.
// The input reads and drives pactl instead: its nodes resolve a monitor
// default to the sink and give a virtual source no audio, and pulse's view
// has both as plain sources with a level and a mute of their own.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pipewire
import "audio.mjs" as Audio
import "hints.mjs" as Hints

Item {
    id: panel

    required property var theme
    // Whether the panel is open. The nodes it lists are only tracked, and the
    // microphones only followed, then: PipeWire reports no volume for a node
    // nothing tracks.
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

    // The microphones, as audio.mjs inputDevices() reads them from pactl:
    // `current`, the default, and `shown`, the ones the picker lists.
    property var inputState: ({ current: null, shown: [] })

    // The two device directions, each shown and driven the same way: what the
    // head row and slider show (`current`, the default, or null), what the
    // picker lists (`devices`, in picking order) and what the keys and the
    // pointer do to them.
    readonly property var output: ({
        heading: "Output",
        input: false,
        current: panel.sink ? {
            name: panel.sink.name,
            label: Audio.sinkLabel(panel.sink.description, panel.sink.name),
            kind: Audio.nodeKind(panel.sink.name, panel.sink.properties),
            volume: panel.sink.audio ? panel.sink.audio.volume : 0,
            muted: !!(panel.sink.audio && panel.sink.audio.muted)
        } : null,
        devices: panel.shownSinks.map(n => ({
            label: Audio.sinkLabel(n.description, n.name),
            kind: Audio.nodeKind(n.name, n.properties),
            current: n === panel.sink
        })),
        setVolume: v => {
            if (panel.sink && panel.sink.audio)
                panel.sink.audio.volume = v;
        },
        toggleMute: () => {
            if (panel.sink && panel.sink.audio)
                panel.sink.audio.muted = !panel.sink.audio.muted;
        },
        pick: i => { Pipewire.preferredDefaultAudioSink = panel.shownSinks[i]; },
        runTest: () => panel.toggleTest(false)
    })
    readonly property var input: ({
        heading: "Input",
        input: true,
        current: panel.inputState.current,
        devices: panel.inputState.shown.map(d => ({
            label: d.label,
            kind: d.kind,
            current: !!panel.inputState.current && d.name === panel.inputState.current.name
        })),
        setVolume: v => panel.setInputVolume(v),
        toggleMute: () => panel.toggleInputMute(),
        pick: i => panel.pickInput(i),
        runTest: () => panel.toggleTest(true)
    })

    implicitWidth: 280
    implicitHeight: content.implicitHeight

    // A key pressed while the panel is open, from Volume.qml. Up and Right
    // step the default sink as a wheel notch does, Down and Left back; M
    // mutes; T tests the output; a digit picks that output. With Shift the
    // same keys act on the default source and the inputs. Answers whether it
    // was one of those.
    function keyPressed(event) {
        const direction = event.modifiers & Qt.ShiftModifier ? panel.input : panel.output;
        const current = direction.current;
        // Shift on the keypad types its navigation keys, so the digit comes
        // from the key's position, before the arrows are asked.
        const shiftedKeypad = (event.modifiers & Qt.ShiftModifier) && (event.modifiers & Qt.KeypadModifier);
        const digit = shiftedKeypad ? Hints.keypadDigit(event.nativeScanCode)
            : Hints.digitKey(event.text, event.nativeScanCode);
        if (digit > 0) {
            if (digit <= direction.devices.length)
                direction.pick(digit - 1);
        } else if (event.key === Qt.Key_Up || event.key === Qt.Key_Right) {
            if (current)
                direction.setVolume(Audio.stepVolume(current.volume, 1));
        } else if (event.key === Qt.Key_Down || event.key === Qt.Key_Left) {
            if (current)
                direction.setVolume(Audio.stepVolume(current.volume, -1));
        } else if (event.key === Qt.Key_M) {
            if (current)
                direction.toggleMute();
        } else if (event.key === Qt.Key_T) {
            if (current)
                direction.runTest();
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

    onActiveChanged: {
        panel.refresh();
        panel.refreshInput();
        if (!panel.active)
            panel.setTest(null);
    }
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

    // The microphones, read from pactl: the default's name on the first line,
    // then the sources as JSON. Read on opening, and whenever pulse says a
    // source or the default changed while open. A read asked for while one
    // runs is made once it ends, so the last change is always read.
    property bool inputStale: false

    function refreshInput() {
        if (!panel.active)
            return;
        if (inputFetch.running)
            panel.inputStale = true;
        else
            inputFetch.running = true;
    }

    Process {
        id: inputFetch
        command: ["sh", "-c", "pactl get-default-source; pactl -f json list sources"]
        environment: ({ LC_ALL: "C" })
        stdout: StdioCollector {
            id: inputOutput
            onStreamFinished: {
                // A volume being set is newer than what was read: the read
                // that follows it will have it.
                if (volumeSet.running || panel.pendingVolume)
                    return;
                const text = inputOutput.text;
                const newline = text.indexOf("\n");
                panel.inputState = newline < 0 ? Audio.inputDevices("", "")
                    : Audio.inputDevices(text.slice(newline + 1), text.slice(0, newline).trim());
            }
        }
        onRunningChanged: {
            if (!inputFetch.running && panel.inputStale) {
                panel.inputStale = false;
                panel.refreshInput();
            }
        }
    }

    // Source and default changes, as they happen, only while open.
    Process {
        running: panel.active
        command: ["pactl", "subscribe"]
        environment: ({ LC_ALL: "C" })
        stdout: SplitParser {
            onRead: line => {
                if (/ on (source|server) /.test(line))
                    panel.refreshInput();
            }
        }
    }

    // `patch` applied to the input called `name` in the state at once, so a
    // slider follows the pointer without waiting for pactl to answer.
    function patchInput(name, patch) {
        const apply = d => d.name === name ? Object.assign({}, d, patch) : d;
        const state = panel.inputState;
        panel.inputState = {
            current: state.current ? apply(state.current) : null,
            shown: state.shown.map(apply)
        };
    }

    // A slider drag sets the level many times a second. One command runs at a
    // time, and the latest value asked for while it runs waits for it to end;
    // the ones in between are never sent.
    property var pendingVolume: null

    function sendVolume(job) {
        if (volumeSet.running) {
            panel.pendingVolume = job;
        } else {
            volumeSet.command = ["pactl", "set-source-volume", job.name, String(job.raw)];
            volumeSet.running = true;
        }
    }

    function setInputVolume(volume) {
        const current = panel.inputState.current;
        if (!current)
            return;
        panel.patchInput(current.name, { volume: Math.max(0, volume) });
        panel.sendVolume({ name: current.name, raw: Audio.paVolume(volume) });
    }

    function toggleInputMute() {
        const current = panel.inputState.current;
        if (!current)
            return;
        panel.patchInput(current.name, { muted: !current.muted });
        Quickshell.execDetached(["pactl", "set-source-mute", current.name, "toggle"]);
    }

    function pickInput(index) {
        const picked = panel.inputState.shown[index];
        if (!picked)
            return;
        panel.inputState = { current: picked, shown: panel.inputState.shown };
        Quickshell.execDetached(["pactl", "set-default-source", picked.name]);
    }

    Process {
        id: volumeSet
        onRunningChanged: {
            if (volumeSet.running)
                return;
            const next = panel.pendingVolume;
            panel.pendingVolume = null;
            if (next)
                panel.sendVolume(next);
            else
                panel.refreshInput();
        }
    }

    // The self-test of a direction, audio.mjs's one value for both: what the
    // control on the picker's heading shows, and what the keys and the
    // pointer start or cancel. One test runs at a time. Starting the one that
    // runs cancels it, starting the other replaces it, and closing the panel
    // cancels it. A problem stays shown until the next test or until the
    // panel closes.
    property var test: null
    // Where the input test records. It holds the user's voice, so it is
    // removed whenever the test ends, however it ends.
    readonly property string testFile: Quickshell.env("XDG_RUNTIME_DIR") + "/chauvenity-mic-test.wav"
    // Whether the command running was stopped for a test that is no longer
    // the current one, so its exit says nothing about the current test.
    property bool testStopped: false

    // The test as `input`'s control shows it: running or a problem, or null
    // when the other direction has the test or none runs.
    function testOf(input) {
        return panel.test && panel.test.input === input ? panel.test : null;
    }

    function toggleTest(input) {
        const device = input ? panel.input.current : panel.output.current;
        if (!device)
            return;
        const running = panel.test && panel.test.kind === "running" && panel.test.input === input;
        panel.setTest(running ? null : input ? Audio.inputTest(device, panel.testFile) : Audio.outputTest(device));
    }

    // Makes `next` the test. Its steps go on from where a step ends, so a
    // recording stays only while the test it belongs to goes on.
    function setTest(next) {
        const previous = panel.test;
        const goesOn = !!next && next.kind === "running" && !!previous && next.steps === previous.steps;
        if (previous && previous.kind === "running" && previous.input && !goesOn)
            Quickshell.execDetached(["rm", "-f", panel.testFile]);
        panel.test = next;
        panel.runStep();
    }

    // A command runs at a time. One that is running while another test is
    // wanted is stopped first, and its exit starts the wanted one.
    function runStep() {
        if (testRun.running) {
            panel.testStopped = true;
            testRun.running = false;
        } else if (panel.test && panel.test.kind === "running") {
            testRun.command = panel.test.steps[panel.test.step].command;
            testRun.running = true;
        }
    }

    Process {
        id: testRun
        onExited: exitCode => {
            if (panel.testStopped) {
                panel.testStopped = false;
                panel.runStep();
            } else {
                panel.setTest(Audio.testStepEnded(panel.test, exitCode));
            }
        }
    }

    // The input's peaks while the test records: the meter on the heading, and
    // the loudest one the test goes by.
    PwNodePeakMonitor {
        id: testMonitor
        node: {
            const target = Audio.testTarget(panel.test);
            return target ? Pipewire.nodes.values.find(n => n.name === target) : null;
        }
        enabled: Audio.testListening(panel.test)
        onPeaksChanged: panel.test = Audio.testHeard(panel.test, testMonitor.peak)
    }
    readonly property real testPeak: testMonitor.enabled ? Math.min(1, testMonitor.peak) : 0

    // A level, 0–100 %, set by clicking or dragging along it: `moved` says
    // what to. Past 100 % the fill is full and in the warn colour.
    component LevelSlider: Item {
        id: slider

        required property var theme
        required property real level
        required property bool muted

        signal moved(real level)

        implicitHeight: 16

        function setFrom(x) {
            slider.moved(Math.max(0, Math.min(1, x / slider.width)));
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

    // One device direction from the records above: the default device's glyph
    // (click to mute), name and level, its slider, and the picker.
    component DeviceBlock: Column {
        id: block

        required property var theme
        required property var direction
        readonly property var current: block.direction.current

        spacing: 4

        Item {
            width: parent.width
            implicitHeight: 22

            AudioIcon {
                id: headIcon
                anchors.verticalCenter: parent.verticalCenter
                theme: block.theme
                kind: block.current ? block.current.kind : "speaker"
                input: block.direction.input
                level: block.current ? block.current.volume : 0
                muted: !!block.current && block.current.muted
                ink: block.theme.fgColor
            }
            MouseArea {
                anchors.fill: headIcon
                anchors.margins: -3
                onClicked: {
                    if (block.current)
                        block.direction.toggleMute();
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
                text: block.current ? block.current.label
                    : "No " + block.direction.heading.toLowerCase()
                color: block.theme.fgColor
                font.pixelSize: 12
                font.bold: true
            }
            Text {
                id: headLevel
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: !block.current ? ""
                    : block.current.muted ? "muted"
                    : Audio.percent(block.current.volume)
                color: !block.current || block.current.muted ? block.theme.dimColor
                    : block.current.volume > 1.0005 ? block.theme.warnColor
                    : block.theme.fgColor
                font.pixelSize: 12
                font.features: { "tnum": 1 }
            }
        }

        LevelSlider {
            width: parent.width
            theme: block.theme
            level: block.current ? block.current.volume : 0
            muted: !!block.current && block.current.muted
            onMoved: level => {
                if (block.current)
                    block.direction.setVolume(level);
            }
        }

        Item {
            width: parent.width
            implicitHeight: heading.implicitHeight

            Heading {
                id: heading
                text: block.direction.heading
                color: block.theme.dimColor
            }

            // The direction's test: idle, "Test"; running, its step, and
            // while it records a meter of the microphone; and after a
            // problem, what it was. A click starts it, cancels it or tries
            // again.
            Row {
                id: testControl
                readonly property var testing: panel.testOf(block.direction.input)

                visible: !!block.current
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 2
                spacing: 6

                Rectangle {
                    visible: Audio.testListening(testControl.testing)
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    height: 4
                    radius: 2
                    color: block.theme.trackColor

                    Rectangle {
                        width: parent.width * panel.testPeak
                        height: parent.height
                        radius: 2
                        color: block.theme.accentColor
                    }
                }
                Text {
                    // What the heading leaves, less the meter.
                    width: Math.min(implicitWidth, block.width - heading.implicitWidth - 12
                                    - (Audio.testListening(testControl.testing) ? 46 : 0))
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: !testControl.testing ? "Test"
                        : testControl.testing.kind === "running" ? testControl.testing.steps[testControl.testing.step].label
                        : testControl.testing.message
                    color: !testControl.testing ? (testMouse.containsMouse ? block.theme.fgColor : block.theme.dimColor)
                        : testControl.testing.kind === "running" ? block.theme.accentColor
                        : block.theme.warnColor
                    font.pixelSize: 11
                }
            }
            MouseArea {
                id: testMouse
                visible: testControl.visible
                anchors.fill: testControl
                anchors.margins: -3
                hoverEnabled: true
                onClicked: block.direction.runTest()
            }
        }

        Repeater {
            model: block.direction.devices

            Item {
                id: row
                required property var modelData
                required property int index
                readonly property bool current: row.modelData.current

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
                    kind: row.modelData.kind
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
                    text: row.modelData.label
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
                    onClicked: block.direction.pick(row.index)
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
                    level: streamRow.modelData.audio ? streamRow.modelData.audio.volume : 0
                    muted: !!(streamRow.modelData.audio && streamRow.modelData.audio.muted)
                    onMoved: level => {
                        if (streamRow.modelData.audio)
                            streamRow.modelData.audio.volume = level;
                    }
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
            text: "↑↓ volume · M mute · T test · 1–9 output · Esc close\nShift: the same for the microphone"
            color: panel.theme.dimColor
            font.pixelSize: 11
        }

        Item {
            width: 1
            height: 4
        }
    }
}
