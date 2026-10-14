pragma ComponentBehavior: Bound

// Super+Space's leader menu, the way Spacemacs's which-key does it: one bind
// in ~/.config/niri, then a key at a time down a menu of the plugins.
//
//     qs -c chauvenity ipc call leader toggle     # Super+Space in ~/.config/niri
//     qs -c chauvenity ipc call leader close
//
// It takes the keyboard at once but shows nothing for a moment: keys typed
// without a pause (Super+Space b n) run their pick before anything shows.
// After a pause a strip rises from the bottom of the focused output with the
// next keys, a page of its own in blue with a "+".
//
// A page with arguments (bb's, which bb-new answers) lists them first, the
// way Magit's transients do: "-" then a key steps one forward, "-" then its
// capital back, and the picks on the page run with them. Only the arguments
// changed are handed on; the others stay the plugin's own defaults.
//
// leader-menu.mjs says what each key does, leader.mjs makes the decisions.
// A pick gives the keyboard back, then runs its command; so does a key that
// leads nowhere, after the strip has said so for a moment.
//
// Keys: a key goes down a page or runs its pick · Backspace back a page · Esc, or
// Super+Space again, closes. A click on an entry picks it.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "leader.mjs" as Lead
import "leader-menu.mjs" as Menu

Scope {
    id: leader

    required property var theme
    // The output niri has focused, by name: the strip opens on it.
    required property string outputName
    // The bar's items and their hint letters, `[{ key, name }]`, for the page
    // that opens their panels: shell.qml reads them on `opening`.
    property var barItems: []

    // Just before it takes the keyboard: shell.qml takes the hints and any
    // open panel down, whose grabs would hold it.
    signal opening()

    readonly property alias window: strip

    // Holding the keyboard; the output it shows on; the keys typed after the
    // leader.
    property bool open: false
    property string output: ""
    property var path: []
    // The strip is up: after the pause, or saying a key led nowhere.
    property bool shown: false
    // What led nowhere ("SPC b x") while the strip says so, else "".
    property string missed: ""
    // "-" typed: the next key sets an argument.
    property bool dash: false
    // The page's arguments as its `args` command answered them, and those
    // changed from their default, name → value.
    property var args: []
    property var chosen: ({})
    // The command of the last pick, run once the keyboard is back.
    property var pending: []

    readonly property var page: Lead.pageAt(Menu.MENU, leader.path, leader.barItems) ?? { entry: null, entries: [] }
    readonly property string crumb: ["SPC"].concat(leader.path).join(" ")

    // Lets an overlay opened over this one take the keyboard (OverlayFocus.qml).
    OverlayFocus {
        id: overlayFocus
        name: "chauvenity-leader"
        open: leader.open
    }

    IpcHandler {
        target: "leader"

        // Calling it again while it is open closes it.
        function toggle(): void {
            if (leader.open)
                leader.close();
            else
                leader.summon();
        }
        function close(): void {
            leader.close();
        }
    }

    Component.onCompleted: {
        for (const problem of Lead.checkMenu(Menu.MENU))
            console.warn(`leader: ${problem}`);
    }

    function summon() {
        leader.opening();
        missTimer.stop();
        leader.missed = "";
        leader.output = leader.outputName;
        leader.path = [];
        leader.open = true;
        leader.enter();
        strip.visible = true;
        catcher.forceActiveFocus();
    }

    function close() {
        leader.open = false;
        leader.reset();
        leader.hide();
    }

    // Everything back as it was but the strip, which goes on its own.
    function reset() {
        pauseTimer.stop();
        argsProcess.running = false;
        leader.path = [];
        leader.dash = false;
        leader.args = [];
        leader.chosen = {};
    }

    function reveal() {
        pauseTimer.stop();
        if (leader.shown)
            return;
        leader.shown = true;
        hideAnimation.stop();
        showAnimation.restart();
    }

    function hide() {
        if (!leader.shown) {
            strip.visible = false;
            return;
        }
        leader.shown = false;
        showAnimation.stop();
        hideAnimation.restart();
    }

    // On a new page: its arguments asked for, and either the change shown or
    // the pause started again.
    function enter() {
        leader.dash = false;
        leader.args = [];
        leader.chosen = {};
        argsProcess.running = false;
        const argv = leader.page.entry?.args;
        if (argv)
            argsProcess.exec(argv);
        if (leader.shown)
            pageAnimation.restart();
        else
            pauseTimer.restart();
    }

    function valueOf(arg) {
        return leader.chosen[arg.name] ?? arg.value;
    }

    function step(arg, by) {
        leader.chosen = Lead.choose(leader.chosen, arg, Lead.stepArgument(arg, leader.valueOf(arg), by));
    }

    function key(event) {
        event.accepted = true;
        if (leader.theme.modifierKeys.indexOf(event.key) !== -1)
            return;
        if (event.key === Qt.Key_Escape) {
            leader.close();
        } else if (event.key === Qt.Key_Backspace) {
            if (leader.dash) {
                leader.dash = false;
            } else if (leader.path.length === 0) {
                leader.close();
            } else {
                leader.path = leader.path.slice(0, -1);
                leader.enter();
            }
        } else if (leader.dash) {
            leader.dash = false;
            const hit = Lead.argumentKey(leader.args, event.text);
            if (hit)
                leader.step(hit.arg, hit.step);
        } else if (event.text === "-" && leader.args.length > 0) {
            leader.dash = true;
            leader.reveal();
        } else {
            leader.choose(Lead.answer(leader.page.entries, event.text), event.text);
        }
    }

    // A key's or a click's entry: down its page, or its pick.
    function choose(entry, typed) {
        if (!entry) {
            leader.miss(typed);
        } else if (Lead.childrenOf(entry, leader.barItems)) {
            leader.path = leader.path.concat([entry.key]);
            leader.enter();
        } else {
            leader.pending = Lead.command(entry.run, leader.chosen);
            console.info(`leader: ${leader.crumb} ${entry.key} runs ${JSON.stringify(leader.pending)}`);
            leader.close();
            launch.restart();
        }
    }

    // The keyboard goes back at once; the strip says what led nowhere for a
    // moment, then goes too.
    function miss(typed) {
        const shown = /^[!-~ -￿]$/.test(typed) ? typed : "that key";
        leader.missed = `${leader.crumb} ${shown}`;
        leader.open = false;
        leader.reset();
        leader.reveal();
        missTimer.restart();
    }

    Timer {
        id: pauseTimer
        interval: 350
        onTriggered: leader.reveal()
    }

    Timer {
        id: missTimer
        interval: 1600
        onTriggered: {
            leader.missed = "";
            if (!leader.open)
                leader.hide();
        }
    }

    // After the strip has let go of the keyboard: a plugin that takes it as
    // it opens would otherwise race the strip giving it back.
    Timer {
        id: launch
        interval: 60
        onTriggered: Quickshell.execDetached(leader.pending)
    }

    Process {
        id: argsProcess
        stdout: StdioCollector {
            id: argsOutput
            onStreamFinished: {
                leader.args = Lead.readArguments(argsOutput.text);
                if (leader.page.entry?.args && leader.args.length === 0)
                    console.warn(`leader: no arguments for ${leader.crumb} from ${JSON.stringify(leader.page.entry.args)}: “${argsOutput.text.trim()}”`);
            }
        }
    }

    // --- the strip ---------------------------------------------------------------

    readonly property string mono: "JetBrains Mono"

    component Label: Text {
        textFormat: Text.PlainText
        color: leader.theme.fgColor
        font.family: leader.mono
        font.pixelSize: 13
    }

    PanelWindow {
        id: strip

        readonly property int margin: 10
        readonly property int pad: 14
        // 0 below the screen's edge, 1 up.
        property real rise: 0

        visible: false
        screen: Quickshell.screens.find(s => s.name === leader.output) ?? Quickshell.screens[0]
        anchors {
            bottom: true
            left: true
            right: true
        }
        implicitHeight: card.height + 2 * strip.margin
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "chauvenity-leader"
        WlrLayershell.keyboardFocus: overlayFocus.keyboardFocus
        color: "transparent"
        // Clicks go through while the strip is down, and around it once up.
        mask: Region {
            item: leader.shown ? card : null
        }

        onVisibleChanged: {
            if (strip.visible)
                catcher.forceActiveFocus();
        }

        NumberAnimation {
            id: showAnimation
            target: strip
            property: "rise"
            to: 1
            duration: 200
            easing.type: Easing.OutCubic
        }

        NumberAnimation {
            id: hideAnimation
            target: strip
            property: "rise"
            to: 0
            duration: 150
            easing.type: Easing.InCubic
            onFinished: {
                if (!leader.shown && !leader.open)
                    strip.visible = false;
            }
        }

        ParallelAnimation {
            id: pageAnimation
            NumberAnimation { target: body; property: "opacity"; from: 0; to: 1; duration: 140 }
            NumberAnimation { target: bodyShift; property: "x"; from: 12; to: 0; duration: 180; easing.type: Easing.OutCubic }
        }

        Item {
            id: catcher
            focus: true
            Keys.onPressed: event => leader.key(event)
        }

        // Centred, and no wider than four columns of keys: across a wide
        // screen the eye would have to travel from one end to the other.
        // The same width on every page, so going down one does not move it.
        Rectangle {
            id: card
            readonly property int maxWidth: 1000
            x: Math.round((strip.width - card.width) / 2)
            y: Math.round(strip.margin + (1 - strip.rise) * (card.height + strip.margin + 4))
            width: Math.min(strip.width - 2 * strip.margin, card.maxWidth)
            height: content.implicitHeight + 2 * strip.pad
            radius: 10
            color: leader.theme.bgColor
            border.color: leader.missed !== "" ? leader.theme.badColor : leader.theme.lineColor

            Column {
                id: content
                x: strip.pad
                y: strip.pad
                width: card.width - 2 * strip.pad
                spacing: 8

                // Where the keys have led, and the keys that always work.
                Item {
                    width: content.width
                    height: crumbRow.implicitHeight

                    Row {
                        id: crumbRow
                        visible: leader.missed === ""
                        spacing: 6

                        Label {
                            text: "SPC"
                            color: leader.theme.accentColor
                            font.bold: true
                        }
                        Repeater {
                            model: leader.path
                            Label {
                                required property string modelData
                                text: modelData
                                color: leader.theme.warnColor
                                font.bold: true
                            }
                        }
                        Label {
                            text: leader.dash ? "- …" : "-"
                            color: leader.dash ? leader.theme.warnColor : leader.theme.dimColor
                        }
                    }

                    Label {
                        visible: leader.missed !== ""
                        text: `${leader.missed} leads nowhere`
                        color: leader.theme.badColor
                    }

                    Label {
                        anchors.right: parent.right
                        text: (leader.args.length > 0 ? "- then a key sets an argument, its capital steps back · " : "")
                            + "Backspace back · Esc close"
                        color: leader.theme.dimColor
                        font.pixelSize: 11
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Rectangle {
                    width: content.width
                    height: 1
                    color: leader.theme.lineColor
                }

                Row {
                    id: body
                    spacing: 36
                    transform: Translate {
                        id: bodyShift
                    }

                    // Magit's half: the page's arguments, the value each picks
                    // run with on a green pill.
                    Column {
                        id: argsColumn
                        visible: leader.args.length > 0
                        spacing: 4

                        Label {
                            text: "Arguments"
                            color: leader.theme.accentColor
                            font.bold: true
                                font.pixelSize: 12
                        }

                        Repeater {
                            model: leader.args

                            Row {
                                id: argRow
                                required property var modelData
                                readonly property string value: leader.valueOf(argRow.modelData)
                                readonly property int selected: argRow.modelData.choices.findIndex(c => c.value === argRow.value)
                                spacing: 8

                                Label {
                                    text: "-" + argRow.modelData.key
                                    color: leader.dash ? leader.theme.fgColor : leader.theme.warnColor
                                    font.bold: true
                                }
                                Label {
                                    text: argRow.modelData.name
                                    // Changed from its default.
                                    color: argRow.value !== argRow.modelData.value ? leader.theme.accentColor : leader.theme.fgColor
                                }
                                Item {
                                    width: choiceRow.implicitWidth
                                    height: choiceRow.implicitHeight

                                    Rectangle {
                                        id: pill
                                        readonly property Item at: choices.count > 0 ? choices.itemAt(argRow.selected) : null
                                        x: pill.at ? pill.at.x : 0
                                        width: pill.at ? pill.at.width : 0
                                        height: parent.height
                                        radius: 4
                                        color: leader.theme.goodColor
                                        Behavior on x { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                        Behavior on width { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                    }

                                    Row {
                                        id: choiceRow
                                        spacing: 2

                                        Repeater {
                                            id: choices
                                            model: argRow.modelData.choices

                                            Label {
                                                required property var modelData
                                                required property int index
                                                text: modelData.name
                                                leftPadding: 5
                                                rightPadding: 5
                                                color: index === argRow.selected ? leader.theme.bgColor : leader.theme.dimColor
                                                font.bold: index === argRow.selected
                                                Behavior on color { ColorAnimation { duration: 150 } }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // which-key's half: the page's keys, down the columns.
                    Column {
                        spacing: 4

                        Label {
                            visible: argsColumn.visible
                            text: "Actions"
                            color: leader.theme.accentColor
                            font.bold: true
                                font.pixelSize: 12
                        }

                        Grid {
                            id: entries
                            readonly property int columnWidth: 220
                            readonly property int gap: 24
                            readonly property int room: content.width - (argsColumn.visible ? argsColumn.width + body.spacing : 0)
                            readonly property int columnCount: Math.max(1, Math.floor((entries.room + entries.gap) / (entries.columnWidth + entries.gap)))
                            flow: Grid.TopToBottom
                            rows: Math.max(1, Math.ceil(leader.page.entries.length / entries.columnCount))
                            columnSpacing: entries.gap
                            rowSpacing: 4

                            Repeater {
                                model: leader.page.entries

                                Item {
                                    id: entry
                                    required property var modelData
                                    readonly property bool isPage: !!Lead.childrenOf(entry.modelData, leader.barItems)
                                    width: entries.columnWidth
                                    height: entryRow.implicitHeight + 2

                                    Rectangle {
                                        anchors.fill: parent
                                        anchors.leftMargin: -4
                                        anchors.rightMargin: -4
                                        radius: 4
                                        color: entryMouse.containsMouse ? leader.theme.hoverColor : "transparent"
                                    }

                                    Row {
                                        id: entryRow
                                        y: 1
                                        spacing: 8

                                        Label {
                                            text: entry.modelData.key
                                            color: leader.theme.warnColor
                                            font.bold: true
                                        }
                                        Label {
                                            text: "→"
                                            color: leader.theme.dimColor
                                        }
                                        Label {
                                            width: entries.columnWidth - x
                                            elide: Text.ElideRight
                                            text: (entry.isPage ? "+" : "") + entry.modelData.name
                                            color: entry.isPage ? leader.theme.accentColor : leader.theme.fgColor
                                        }
                                    }

                                    MouseArea {
                                        id: entryMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: leader.choose(entry.modelData, entry.modelData.key)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
