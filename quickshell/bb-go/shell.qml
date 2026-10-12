pragma ComponentBehavior: Bound

// Go somewhere in bb from anywhere in the niri session: the threads that need
// you (unread, or waiting on an answer) first, then bb's sidebar items, its
// Settings sections, each plugin's settings page and the projects. Enter
// sends the bb tab already open there and raises its browser window.
//
// The overlay opens over IPC, bound in ~/.config/niri/config.kdl:
//
//     qs -c bb-go ipc call bbgo toggle               Mod+G
//
// (From a shell without WAYLAND_DISPLAY, a bb thread's for one, add
// `--any-display` after `ipc`: qs only finds instances on its own display.)
//
// It runs as bb-go.service, which niri.service pulls in through
// ~/.config/systemd/user/niri.service.d/50-bb-go.conf like bb-new.service.
//
// The lists and the going are the bb-plugin-nav plugin's
// (~/src/bb-plugins/bb-plugin-nav): `bb nav list` on each open, the last
// answer shown at once while bb is asked again, and `bb nav open <target>`,
// which navigates every open bb tab and says which went and whether it is on
// screen. The window raised is the one whose title starts with that tab's
// page title. If only tabs in the background went, the overlay says so; if
// no bb tab is open, the target opens in the default browser.
//
// Sidebar items show once a bb tab has been open with the plugin loaded;
// items moved under the sidebar's More are not listed.
//
// Keys: type to filter · ↑↓ or Ctrl+J/K select · Tab / Shift+Tab next /
// previous group · Enter go · Esc close.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "bbgo.mjs" as Logic

ShellRoot {
    id: root

    // chauvenity's bar palette, so the overlay looks like part of it.
    readonly property color bgColor: "#1c1b22"
    readonly property color fgColor: "#deddda"
    readonly property color dimColor: "#77767b"
    readonly property color accentColor: "#62a0ea"
    readonly property color goodColor: "#8ff0a4"
    readonly property color badColor: "#f66151"
    readonly property color warnColor: "#f9f06b"
    readonly property color panelColor: "#24232b"
    readonly property color lineColor: "#36353e"
    readonly property color selectColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.16)
    readonly property string monoFont: "JetBrains Mono"

    // Found on bb-go.service's PATH.
    readonly property string bb: "bb"

    property bool open: false
    property var targetScreen: null

    // `bb nav list`'s last answer, null until there is one.
    property var list: null
    property bool listing: false
    property string query: ""
    // Whether the selection was moved since the overlay opened or the filter
    // changed: only then does it follow its row when the list catches up.
    property bool moved: false
    readonly property var rows: Logic.filterRows(Logic.allRows(root.list), root.query)
    property double now: Date.now()

    property bool going: false
    // Why `bb nav list` failed, until it next answers.
    property string listFailure: ""
    property string error: ""
    property string notice: ""

    readonly property var hints: [["type", "filter"], ["↑↓", "select"], ["Tab", "next group"], ["Enter", "go"], ["Esc", "close"]]

    // --- opening ----------------------------------------------------------------

    IpcHandler {
        target: "bbgo"

        function toggle(): void {
            if (root.open)
                root.close();
            else
                root.summon();
        }
        // Not `show`: `qs ipc call <target> show` lists the target instead.
        function open(): void {
            if (!root.open)
                root.summon();
        }
        function close(): void {
            root.close();
        }
    }

    // Lets an overlay opened over this one take the keyboard (OverlayFocus.qml).
    OverlayFocus {
        id: overlayFocus
        name: "bb-go"
        open: root.open
    }

    // Lets pick-to-bb (Mod+Shift+A) describe the overlay's elements.
    PickInspector {
        roots: [overlay]
    }

    function summon() {
        probe.running = true;
        root.refresh();
    }

    // Opens on the output niri has focused rather than wherever Qt puts it.
    function present(output) {
        root.targetScreen = Quickshell.screens.find(s => s.name === output) ?? Quickshell.screens[0];
        filterInput.text = "";
        root.error = "";
        root.notice = "";
        root.now = Date.now();
        root.moved = false;
        rowList.currentIndex = 0;
        root.open = true;
    }

    function close() {
        root.open = false;
        closeTimer.stop();
    }

    Process {
        id: probe
        command: ["niri", "msg", "--json", "focused-output"]
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: root.present(Logic.parseFocusedOutput(probeOut.text))
        }
    }

    // --- what bb lists --------------------------------------------------------------
    // Asked at start, so the first open has something to show, and on each open.

    Component.onCompleted: root.refresh()

    function refresh() {
        if (lister.running)
            return;
        root.listing = true;
        lister.running = true;
    }

    Process {
        id: lister
        command: [root.bb, "nav", "list", "--json"]
        stdout: StdioCollector {
            id: listOut
        }
        stderr: StdioCollector {
            id: listErr
        }
        onExited: code => {
            root.listing = false;
            const list = Logic.parseList(listOut.text);
            if (list === null) {
                root.listFailure = Logic.listError(listOut.text, listErr.text, code);
                return;
            }
            const selected = root.moved ? root.rows[rowList.currentIndex] : null;
            root.list = list;
            root.listFailure = "";
            const again = selected ? root.rows.findIndex(r => r.target === selected.target) : -1;
            rowList.currentIndex = Math.max(0, again);
        }
    }

    // --- going there ----------------------------------------------------------------

    function go() {
        const row = root.rows[rowList.currentIndex];
        if (root.going || !row)
            return;
        root.error = "";
        root.notice = "";
        root.going = true;
        opener.exec(Logic.openCommand(root.bb, row.target));
    }

    Process {
        id: opener
        stdout: StdioCollector {
            id: openOut
        }
        stderr: StdioCollector {
            id: openErr
        }
        onExited: code => {
            root.going = false;
            const next = Logic.decide(openOut.text, openErr.text, code);
            if (next.error) {
                root.error = next.error;
            } else if (next.action === "raise") {
                root.close();
                // After the overlay lets go of the keyboard.
                Qt.callLater(() => root.raise(next.title));
            } else if (next.action === "browse") {
                Qt.openUrlExternally(next.url);
                root.close();
            } else {
                root.notice = "bb went there in a background tab: bring it to the front in the browser";
                closeTimer.restart();
            }
        }
    }

    // The browser window showing the tab: wlr foreign-toplevel, which niri
    // implements, lists every window with its title.
    function raise(title) {
        const windows = ToplevelManager.toplevels.values;
        const index = Logic.findWindow(windows.map(w => w.title), title);
        if (index >= 0)
            windows[index].activate();
    }

    Timer {
        id: closeTimer
        interval: 2500
        onTriggered: root.close()
    }

    // --- keys -------------------------------------------------------------------

    function move(step) {
        const count = root.rows.length;
        if (count === 0)
            return;
        root.moved = true;
        rowList.currentIndex = (rowList.currentIndex + step + count) % count;
        rowList.positionViewAtIndex(rowList.currentIndex, ListView.Contain);
    }

    function jump(step) {
        root.moved = true;
        rowList.currentIndex = Logic.groupJump(root.rows, rowList.currentIndex, step);
        rowList.positionViewAtIndex(rowList.currentIndex, ListView.Contain);
    }

    // The filter sends its keys here first; false leaves the key to it.
    function handleKey(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const key = event.key;

        if (key === Qt.Key_Escape) {
            root.close();
        } else if (root.going) {
            // Nothing changes while bb is going there.
        } else if (key === Qt.Key_Down || (ctrl && (key === Qt.Key_J || key === Qt.Key_N))) {
            root.move(1);
        } else if (key === Qt.Key_Up || (ctrl && (key === Qt.Key_K || key === Qt.Key_P))) {
            root.move(-1);
        } else if (key === Qt.Key_Tab) {
            root.jump(1);
        } else if (key === Qt.Key_Backtab) {
            root.jump(-1);
        } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            root.go();
        } else {
            return false;
        }
        return true;
    }

    // --- the overlay ------------------------------------------------------------

    PanelWindow {
        id: overlay

        visible: root.open
        screen: root.targetScreen
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "bb-go"
        WlrLayershell.keyboardFocus: overlayFocus.keyboardFocus
        color: "transparent"
        // niri blurs the wallpaper behind the card ("xray"); a layer-rule
        // with `background-effect { xray false; }` blurs the windows instead.
        BackgroundEffect.blurRegion: Region {
            item: card
            radius: card.radius
        }

        onVisibleChanged: {
            if (!overlay.visible)
                return;
            filterInput.forceActiveFocus();
            openAnimation.restart();
        }

        ParallelAnimation {
            id: openAnimation
            NumberAnimation { target: backdrop; property: "opacity"; from: 0; to: 1; duration: 140 }
            NumberAnimation { target: frame; property: "opacity"; from: 0; to: 1; duration: 140; easing.type: Easing.OutCubic }
            NumberAnimation { target: frame; property: "scale"; from: 0.96; to: 1; duration: 180; easing.type: Easing.OutCubic }
        }

        // Dims the screen; a click outside the card closes.
        Rectangle {
            id: backdrop
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.35)

            MouseArea {
                anchors.fill: parent
                onClicked: root.close()
            }
        }

        Item {
            id: frame
            width: Math.round(Math.min(720, overlay.width - 80))
            height: Math.round(body.implicitHeight + 32)
            x: Math.round((overlay.width - frame.width) / 2)
            y: Math.round(overlay.height * 0.15)

            // Translucent over niri's blur (BackgroundEffect on the overlay),
            // and without a drop shadow: a shadow is dark under the card too,
            // and would hide the blur.
            Rectangle {
                id: card
                anchors.fill: parent
                radius: 14
                color: Qt.alpha(root.bgColor, 0.75)
                border.color: root.lineColor

                // Swallows clicks, so only the backdrop closes.
                MouseArea {
                    anchors.fill: parent
                }

                Column {
                    id: body
                    anchors {
                        top: parent.top
                        left: parent.left
                        right: parent.right
                        margins: 16
                    }
                    spacing: 10

                    Item {
                        width: parent.width
                        height: 14

                        Text {
                            text: "Go to in bb"
                            color: root.dimColor
                            font.family: root.monoFont
                            font.pixelSize: 11
                        }
                        Text {
                            anchors.right: parent.right
                            text: root.listing ? "asking bb…" : ""
                            color: root.dimColor
                            font.family: root.monoFont
                            font.pixelSize: 11
                        }
                    }

                    // The filter.
                    Rectangle {
                        width: parent.width
                        height: 40
                        radius: 8
                        color: root.panelColor
                        border.width: 1
                        border.color: filterInput.activeFocus ? root.accentColor : root.lineColor

                        TextInput {
                            id: filterInput
                            anchors {
                                left: parent.left
                                right: parent.right
                                margins: 12
                                verticalCenter: parent.verticalCenter
                            }
                            focus: true
                            color: root.fgColor
                            selectionColor: root.accentColor
                            font.family: root.monoFont
                            font.pixelSize: 14
                            onTextChanged: {
                                root.query = filterInput.text;
                                root.moved = false;
                                rowList.currentIndex = 0;
                            }
                            Keys.onPressed: event => {
                                if (root.handleKey(event))
                                    event.accepted = true;
                            }
                        }
                        Text {
                            anchors {
                                left: filterInput.left
                                verticalCenter: parent.verticalCenter
                            }
                            visible: filterInput.text.length === 0
                            text: "A thread, a sidebar item, a setting, a project…"
                            color: root.dimColor
                            font: filterInput.font
                        }
                    }

                    // The rows, a header above the first of each group.
                    Rectangle {
                        width: parent.width
                        height: Math.min(Math.max(rowList.contentHeight, 32), 460)
                        radius: 8
                        color: root.panelColor
                        border.color: root.lineColor
                        clip: true

                        ListView {
                            id: rowList
                            anchors.fill: parent
                            anchors.margins: 1
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: root.rows

                            delegate: Column {
                                id: row
                                required property var modelData
                                required property int index
                                readonly property bool current: row.index === rowList.currentIndex

                                width: rowList.width

                                Text {
                                    visible: row.modelData.first
                                    height: row.modelData.first ? 24 : 0
                                    leftPadding: 10
                                    topPadding: 7
                                    text: row.modelData.group
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 11
                                }

                                Rectangle {
                                    width: parent.width
                                    height: 28
                                    color: row.current ? root.selectColor : "transparent"

                                    Rectangle {
                                        visible: row.current
                                        width: 2
                                        height: parent.height
                                        color: root.accentColor
                                    }
                                    // ● unread, ? waiting on an answer.
                                    Text {
                                        x: 12
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: row.modelData.waiting ? "?" : (row.modelData.unread ? "●" : "")
                                        color: row.modelData.waiting ? root.warnColor : root.accentColor
                                        font.family: root.monoFont
                                        font.pixelSize: 12
                                    }
                                    Text {
                                        x: 30
                                        width: parent.width - 30 - detailText.implicitWidth - 24
                                        anchors.verticalCenter: parent.verticalCenter
                                        elide: Text.ElideRight
                                        text: row.modelData.label
                                        color: root.fgColor
                                        font.family: root.monoFont
                                        font.pixelSize: 13
                                    }
                                    Text {
                                        id: detailText
                                        anchors {
                                            right: parent.right
                                            rightMargin: 10
                                            verticalCenter: parent.verticalCenter
                                        }
                                        text: row.modelData.thread
                                            ? [row.modelData.detail, Logic.age(row.modelData.attentionAt, root.now)].filter(s => s).join(" · ")
                                            : ""
                                        color: root.dimColor
                                        font.family: root.monoFont
                                        font.pixelSize: 11
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            rowList.currentIndex = row.index;
                                            root.go();
                                        }
                                    }
                                }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: root.rows.length === 0
                            text: root.list === null ? (root.listing ? "Asking bb…" : "Nothing from bb yet") : "Nothing matches"
                            color: root.dimColor
                            font.family: root.monoFont
                            font.pixelSize: 12
                        }
                    }

                    Text {
                        visible: root.list !== null && !root.list.sidebarReported
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: "No sidebar items yet: open bb in a browser once, with the nav plugin loaded."
                        color: root.dimColor
                        font.family: root.monoFont
                        font.pixelSize: 11
                    }

                    Text {
                        visible: root.error !== "" || root.listFailure !== ""
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: root.error || root.listFailure
                        color: root.badColor
                        font.family: root.monoFont
                        font.pixelSize: 12
                    }

                    Text {
                        visible: root.going || root.notice !== ""
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: root.going ? "Sending bb there…" : root.notice
                        color: root.going ? root.accentColor : root.goodColor
                        font.family: root.monoFont
                        font.pixelSize: 11
                    }

                    Flow {
                        visible: !root.going && root.notice === ""
                        width: parent.width
                        spacing: 12

                        Repeater {
                            model: root.hints

                            delegate: Row {
                                id: hint
                                required property var modelData
                                spacing: 5

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: keyName.implicitWidth + 10
                                    height: 18
                                    radius: 4
                                    color: root.panelColor
                                    border.color: root.lineColor

                                    Text {
                                        id: keyName
                                        anchors.centerIn: parent
                                        text: hint.modelData[0]
                                        color: root.fgColor
                                        font.family: root.monoFont
                                        font.pixelSize: 11
                                    }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: hint.modelData[1]
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 11
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
