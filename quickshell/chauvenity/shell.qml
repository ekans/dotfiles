pragma ComponentBehavior: Bound

// chauvenity-os default Quickshell bar for the niri session.
//
// Quickshell resolves `qs -c chauvenity` against the XDG config directories in
// order, so this file is only used when the user has not written their own:
//
//     ~/.config/quickshell/chauvenity/shell.qml   <- wins if it exists
//     /etc/xdg/quickshell/chauvenity/shell.qml    <- this file
//
// To take it over, copy the whole directory and edit; Quickshell reloads the
// QML every time a file is saved:
//
//     mkdir -p ~/.config/quickshell
//     cp -r /etc/xdg/quickshell/chauvenity ~/.config/quickshell/
//     systemctl --user restart chauvenity-quickshell
//
// Why each line matters: https://github.com/ekans/chauvenity-os#taking-it-over
//
// The polkit prompt comes from mate-polkit, its own systemd user unit, so
// there is no second implementation of it here. Notifications are this
// shell's own (NotificationService.qml), in place of mako, which has to be
// masked for it to get the D-Bus name:
//
//     systemctl --user mask --now mako.service

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Widgets
import Quickshell.Services.Pipewire
import "calendar.mjs" as Cal
import "claude-pace.mjs" as Pace
import "hints.mjs" as Hints
import "window-title.mjs" as WindowTitle

ShellRoot {
    id: root

    // Palette, kept in one place so a copy of this file is easy to retheme.
    readonly property color bgColor: "#1c1b22"
    readonly property color fgColor: "#deddda"
    readonly property color dimColor: "#77767b"
    readonly property color accentColor: "#62a0ea"
    readonly property color goodColor: "#57e389"
    readonly property color warnColor: "#ffa348"
    readonly property color badColor: "#f66151"
    readonly property color panelColor: "#24232b"
    readonly property color lineColor: "#36353e"
    readonly property color trackColor: "#2e2d36"
    readonly property color hoverColor: "#2a2932"
    readonly property int barHeight: 32

    // --- niri state ---------------------------------------------------------
    // Fed by a single `niri msg --json event-stream`, which emits one JSON
    // object per line. Everything below tolerates unknown or missing fields:
    // a niri release that adds an event must not take the bar down.
    property var workspaces: []

    function handleEvent(line) {
        let ev;
        try {
            ev = JSON.parse(line);
        } catch (e) {
            return;
        }

        if (ev.WorkspacesChanged) {
            const list = (ev.WorkspacesChanged.workspaces || []).slice();
            list.sort((a, b) => (a.idx || 0) - (b.idx || 0));
            root.workspaces = list;
        } else if (ev.WorkspaceActivated) {
            // The event carries only {id, focused}. Activating a workspace
            // deactivates every other workspace *on the same output*, and niri
            // does not say so — without this the pills of previously visited
            // workspaces stay lit for the rest of the session.
            const activated = ev.WorkspaceActivated;
            const target = root.workspaces.find(ws => ws.id === activated.id);
            const output = target ? target.output : null;
            root.workspaces = root.workspaces.map(ws => {
                const isTarget = ws.id === activated.id;
                const next = Object.assign({}, ws);
                if (isTarget)
                    next.is_active = true;
                else if (output !== null && ws.output === output)
                    next.is_active = false;
                if (activated.focused)
                    next.is_focused = isTarget;
                return next;
            });
        }
    }

    Process {
        id: niriEvents
        running: true
        command: ["niri", "msg", "--json", "event-stream"]
        stdout: SplitParser {
            onRead: line => root.handleEvent(line)
        }
        // Without this, a stream that dies for any reason leaves the
        // workspaces and the title frozen for the rest of the session, with
        // nothing on screen to say so. Keyed on `running` rather than the
        // `exited` signal, whose parameter types qmllint cannot resolve.
        onRunningChanged: {
            if (!niriEvents.running)
                restartEvents.restart();
        }
    }

    Timer {
        id: restartEvents
        interval: 1000
        onTriggered: niriEvents.running = true
    }

    // --- Claude Code usage ---------------------------------------------------
    // Polled from Claude Code's own usage endpoint (the one behind `/usage`)
    // by claude-usage-fetch.sh, every 5 minutes: it rate-limits anything more
    // frequent. A failed poll keeps the last answer; the panel says how old it
    // is and why the poll failed.
    property string claudeUsageBody: ""
    property var claudeUsageFetchedAt: null
    property string claudeUsageProblem: ""
    readonly property var claudeUsage: Object.assign(Pace.readUsage(root.claudeUsageBody, clock.date), {
        fetchedAt: root.claudeUsageFetchedAt,
        problem: root.claudeUsageProblem
    })

    function handleClaudeUsage(output) {
        const result = Pace.parseFetch(output);
        root.claudeUsageProblem = Pace.fetchProblem(result.status) ?? "";
        if (root.claudeUsageProblem === "") {
            root.claudeUsageBody = result.body;
            root.claudeUsageFetchedAt = new Date();
        }
    }

    Process {
        id: claudeUsageFetch
        command: ["sh", Quickshell.shellPath("claude-usage-fetch.sh")]
        stdout: StdioCollector {
            id: claudeUsageOutput
            onStreamFinished: root.handleClaudeUsage(claudeUsageOutput.text)
        }
    }

    Timer {
        interval: 5 * 60 * 1000
        running: true
        repeat: true
        triggeredOnStart: true
        // A no-op while the previous poll still runs.
        onTriggered: claudeUsageFetch.running = true
    }

    // --- calendars ----------------------------------------------------------
    // The events of the Google and Microsoft 365 accounts added in Settings →
    // Online Accounts, for the clock's panel. calendar-events.py reads them
    // from Google and Microsoft with the tokens Online Accounts gives it, and
    // prints a whole snapshot per line each time they change; an account
    // added there shows up here on its own. A helper that stops leaves its
    // last snapshot on screen, says so, and is started again.
    property var calendarFeed: Cal.emptyFeed()
    property string calendarProblem: ""
    readonly property var calendar: Object.assign({}, root.calendarFeed, {
        problems: root.calendarFeed.problems.concat(root.calendarProblem ? [root.calendarProblem] : [])
    })

    function handleCalendar(line) {
        const feed = Cal.readFeed(line);
        if (!feed)
            return;
        root.calendarFeed = feed;
        root.calendarProblem = "";
    }

    Process {
        id: calendarEvents
        running: true
        command: ["/usr/bin/python3", Quickshell.shellPath("calendar-events.py")]
        stdout: SplitParser {
            onRead: line => root.handleCalendar(line)
        }
        stderr: SplitParser {
            onRead: line => console.warn(`calendar-events.py: ${line}`)
        }
        onRunningChanged: {
            if (!calendarEvents.running) {
                root.calendarProblem = "Calendar reader stopped; starting it again. Its log is in journalctl --user -u chauvenity-quickshell.";
                restartCalendar.restart();
            }
        }
    }

    Timer {
        id: restartCalendar
        interval: 10000
        onTriggered: calendarEvents.running = true
    }

    // --- services -----------------------------------------------------------

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    // Pipewire only publishes volume for nodes something is tracking.
    PwObjectTracker {
        objects: [Pipewire.defaultAudioSink]
    }

    // --- panels -------------------------------------------------------------
    // At most one indicator panel is open, across every bar. A panel's popup
    // grab closes it on a click in another client, but a click on the bar is
    // this client's own and never does: without this, a second panel opened
    // over the first one is re-parented to it by Qt ("does not match the
    // current topmost grabbing popup") and the panels pile up.
    QtObject {
        id: barPanels

        property PopupWindow current: null

        // The open panel is closed first, so that its grab is gone by the
        // time the next one asks niri for its own. `current` changes once and
        // before either: the bar holds the keyboard while it is set, and
        // letting go of it between two panels would close the second one.
        function toggle(panel) {
            const previous = barPanels.current;
            const wasOpen = panel.visible;
            barPanels.current = wasOpen ? null : panel;
            if (previous)
                previous.visible = false;
            if (!wasOpen)
                panel.visible = true;
        }

        function close() {
            const previous = barPanels.current;
            barPanels.current = null;
            if (previous)
                previous.visible = false;
        }
    }

    // A panel niri closed, on a click in another client, gives the keyboard
    // back as well.
    Connections {
        target: barPanels.current
        function onVisibleChanged() {
            if (barPanels.current && !barPanels.current.visible)
                barPanels.current = null;
        }
    }

    // --- keyboard -----------------------------------------------------------
    // Everything a click on the bar does, from the keyboard, on the bar of the
    // output niri has focused:
    //
    //     qs -c chauvenity ipc call bar toggle volume   # any item's hintName
    //     qs -c chauvenity ipc call bar hints           # Mod+B in ~/.config/niri
    //     qs -c chauvenity ipc call bar close
    //
    // `hints` puts a key over each workspace and item and takes the keyboard:
    // the next key picks one, any other key gives the keyboard back, and so
    // does waiting 5 s.
    //
    // An open panel takes the keyboard too, so that Escape closes it.
    //
    // An item anywhere in the bar takes part by declaring
    //
    //     property string hintName: "volume"   // the name `toggle` takes
    //     property string hintKey: "v"         // optional
    //     function toggle() { … }
    //
    // hints.mjs hands out the letters, and says in the log what it could not.

    readonly property string focusedOutput: root.workspaces.find(ws => ws.is_focused)?.output ?? ""
    // The output whose bar shows its hints, or "".
    property string hintOutput: ""

    // The bar on the focused output; the first one until niri has said which
    // output that is.
    function focusedBar() {
        const all = bars.instances;
        return all.find(b => b.modelData.name === root.focusedOutput) ?? all[0] ?? null;
    }

    function endHints() {
        hintTimeout.stop();
        root.hintOutput = "";
    }

    // `focus-workspace` takes an index or a name, not an id, and an index is
    // resolved against the *focused* output — so the monitor has to be
    // focused first for a pick on another bar to land on the workspace that
    // was actually picked.
    function focusWorkspace(ws) {
        barPanels.close();
        Quickshell.execDetached(
            ["sh", "-c",
             "niri msg action focus-monitor \"$1\" && niri msg action focus-workspace \"$2\"",
             "sh",
             String(ws.output),
             String(ws.idx)]);
    }

    IpcHandler {
        target: "bar"

        // Answers with the problem, or "" when the panel opened or closed.
        function toggle(item: string): string {
            const bar = root.focusedBar();
            return bar ? bar.toggle(item) : "no bar on screen";
        }
        // Calling it again while the hints show takes them down.
        function hints(): void {
            const bar = root.focusedBar();
            if (!bar || root.hintOutput !== "") {
                root.endHints();
                return;
            }
            // Its popup grab would hold the keyboard the hints need, as would
            // the translator's chooser and the leader menu.
            barPanels.close();
            translate.close();
            leader.close();
            root.hintOutput = bar.modelData.name;
            hintTimeout.restart();
        }
        // The open panel and the hints.
        function close(): void {
            root.endHints();
            barPanels.close();
        }
    }

    Timer {
        id: hintTimeout
        interval: 5000
        onTriggered: root.endHints()
    }

    // --- keyboard shortcuts --------------------------------------------------
    // niri's binds, grouped and in columns, on the focused output: Mod+Shift+/
    // in ~/.config/niri/config.kdl, in place of niri's own one-column list.
    //
    //     qs -c chauvenity ipc call keys toggle
    //     qs -c chauvenity ipc call keys close

    KeysPanel {
        id: keysPanel
        theme: root
        outputName: root.focusedOutput
    }

    IpcHandler {
        target: "keys"

        function toggle(): void {
            // Their popup grab, the hints and the leader menu would hold the
            // keyboard the panel's filter needs.
            root.endHints();
            barPanels.close();
            leader.close();
            keysPanel.toggle();
        }
        function close(): void {
            keysPanel.close();
        }
    }

    // Keys that only change the next one, so not an answer to the hints.
    readonly property var modifierKeys: [
        Qt.Key_Shift, Qt.Key_Control, Qt.Key_Alt, Qt.Key_AltGr, Qt.Key_Meta,
        Qt.Key_Super_L, Qt.Key_Super_R, Qt.Key_CapsLock, Qt.Key_NumLock
    ]

    // --- translator ---------------------------------------------------------
    // French into English, and English made simple, from the keyboard: Mod+E
    // in ~/.config/niri, then a key for the mode. Translator.qml has the whole
    // story; all of it shows in a panel on the right (TranslatePanel), none
    // in the bar.
    //
    //     qs -c chauvenity ipc call translate choose
    //     qs -c chauvenity ipc call translate close

    Translator {
        id: translate
        theme: root
        outputName: root.focusedOutput || (Quickshell.screens[0]?.name ?? "")
        // Their grabs would hold the keyboard the chooser needs.
        onOpening: {
            root.endHints();
            barPanels.close();
            leader.close();
        }
    }

    // --- leader menu ----------------------------------------------------------
    // One key to every plugin, this bar's and the others': Mod+Space in
    // ~/.config/niri, then a key at a time, the way Spacemacs does it.
    // Leader.qml has the whole story, leader-menu.mjs the keys.
    //
    //     qs -c chauvenity ipc call leader toggle
    //     qs -c chauvenity ipc call leader close

    Leader {
        id: leader
        theme: root
        outputName: root.focusedOutput || (Quickshell.screens[0]?.name ?? "")
        // Their grabs would hold the keyboard the menu needs. Its page of
        // the bar's items is read now, under the letters Mod+B gives them.
        onOpening: {
            root.endHints();
            barPanels.close();
            translate.close();
            keysPanel.close();
            leader.barItems = root.barItems();
        }
    }

    // The focused bar's items on screen and their hint letters,
    // `[{ key, name }]`.
    function barItems() {
        const bar = root.focusedBar();
        if (!bar)
            return [];
        return bar.assignHints()
            .filter(hint => hint.item.visible)
            .map(hint => ({ key: hint.key, name: hint.item.hintName }));
    }

    // --- caffeine -----------------------------------------------------------
    // What GNOME's Caffeine extension does. While on, every bar holds a
    // Wayland idle inhibitor, so niri stops reporting the session idle and
    // swayidle neither locks nor blanks it. Sleep is untouched: closing the
    // lid or `systemctl suspend` still locks and suspends, and a crashed bar
    // drops the inhibitor with it. Off again at every start of the bar.
    //
    //     qs -c chauvenity ipc call bar toggle caffeine

    property bool caffeine: false

    // --- notifications ------------------------------------------------------
    // This shell is the notification server. They show one at a time in an
    // island out of the middle of the bar (NotificationIsland), on the
    // focused output, and stay in the bell's panel (Notifications) until
    // dismissed. From the keyboard:
    //
    //     qs -c chauvenity ipc call notifications dnd     # Mod+Shift+N
    //     qs -c chauvenity ipc call notifications close   # Mod+Escape
    //     qs -c chauvenity ipc call notifications clear
    //     qs -c chauvenity ipc call bar toggle notifications

    NotificationService {
        id: notifications
    }

    NotificationIsland {
        id: notificationIsland
        theme: root
        service: notifications
        outputName: root.focusedOutput
    }

    IpcHandler {
        target: "notifications"

        // Answers with the new state, "on" or "off".
        function dnd(): string {
            notifications.dnd = !notifications.dnd;
            return notifications.dnd ? "on" : "off";
        }
        // Puts the island's away; it stays in the panel.
        function close(): void {
            notificationIsland.hide();
        }
        // Dismisses every one of them.
        function clear(): void {
            notifications.clearAll();
        }
    }

    // --- the bar ------------------------------------------------------------

    // Lets pick-to-bb (Mod+Shift+A) describe bar and popup elements.
    PickInspector {
        roots: [bars, keysPanel.window, translate.panel, leader.window]
    }

    Variants {
        id: bars
        model: Quickshell.screens

        PanelWindow {
            id: bar
            required property var modelData

            // Only this output's workspaces. Without the filter every bar
            // lists every monitor's workspaces.
            readonly property var outputWorkspaces:
                root.workspaces.filter(ws => ws.output === bar.modelData.name)

            // One breakpoint for the right items, which pass it on: a laptop's
            // bar has no room for their labels.
            readonly property bool compact: bar.width < 1600

            readonly property bool hinting: root.hintOutput === bar.modelData.name
            // The items with a hint and their letters, `[{ item, key }]`,
            // worked out as the hints come up.
            property var hinted: []
            // Whether the open panel is one of this bar's items'.
            readonly property bool panelOpen: !!barPanels.current && bar.holds(barPanels.current.anchor.item)

            screen: bar.modelData
            color: root.bgColor
            implicitHeight: root.barHeight
            // An open panel's keys, Escape among them, only come to this
            // client while the bar holds the keyboard; Qt hands them to the
            // panel.
            WlrLayershell.keyboardFocus: bar.hinting || bar.panelOpen
                ? WlrKeyboardFocus.Exclusive
                : WlrKeyboardFocus.None

            function holds(item) {
                for (let at = item; at; at = at.parent) {
                    if (at === bar.contentItem)
                        return true;
                }
                return false;
            }

            anchors {
                top: true
                left: true
                right: true
            }

            IdleInhibitor {
                window: bar
                enabled: root.caffeine
            }

            // The item a hint picked, waiting for the bar to give the
            // keyboard back before its panel opens.
            property Item pendingItem: null

            onHintingChanged: {
                if (!bar.hinting)
                    return;
                bar.hinted = bar.assignHints();
                hintKeys.forceActiveFocus();
            }

            // Every item in the bar that declares a hintName and a toggle(),
            // in the order they sit in. Their own insides are not searched.
            function hintItems() {
                const found = [];
                const walk = parent => {
                    for (let i = 0; i < parent.children.length; i++) {
                        const child = parent.children[i];
                        if (typeof child.hintName === "string" && typeof child.toggle === "function")
                            found.push(child);
                        else
                            walk(child);
                    }
                };
                walk(bar.contentItem);
                return found;
            }

            // Every hint item gets its letter, on screen or not, so that one
            // coming and going does not move the others'.
            function assignHints() {
                const items = bar.hintItems();
                const result = Hints.assignKeys(items.map(item => ({ name: item.hintName, key: item.hintKey ?? "" })));
                for (const problem of result.problems)
                    console.warn(`bar hints: ${problem}`);
                return items.map((item, i) => ({ item: item, key: result.keys[i] }))
                    .filter(hint => hint.key !== "");
            }

            // Answers with the problem, or "" when the panel opened or closed.
            function toggle(name: string): string {
                const items = bar.hintItems();
                const item = items.find(i => i.hintName === name);
                if (!item)
                    return `no item named "${name}": ${items.map(i => i.hintName).join(", ")}`;
                // A desktop has no battery; a session without a sink no volume.
                if (!item.visible)
                    return `${name} is not on screen`;
                item.toggle();
                return "";
            }

            function pickHint(event) {
                event.accepted = true;
                if (root.modifierKeys.includes(event.key))
                    return;
                const shown = bar.hinted.filter(hint => hint.item.visible);
                const target = Hints.hintTarget(event.text, event.nativeScanCode,
                                                bar.outputWorkspaces.length, shown.map(hint => hint.key));
                if (target?.workspace !== undefined)
                    root.focusWorkspace(bar.outputWorkspaces[target.workspace]);
                else if (target?.key)
                    bar.pendingItem = shown.find(hint => hint.key === target.key).item;
                root.endHints();
            }

            // Holds the keyboard while the hints show.
            Item {
                id: hintKeys
                Keys.onPressed: event => bar.pickHint(event)
                // A panel opened while the keyboard is leaving the bar is
                // closed again some 30 ms later: it opens a moment after.
                onActiveFocusChanged: {
                    if (!hintKeys.activeFocus && bar.pendingItem)
                        openPicked.restart();
                }
            }

            Timer {
                id: openPicked
                interval: 100
                onTriggered: {
                    const item = bar.pendingItem;
                    bar.pendingItem = null;
                    if (item?.visible)
                        item.toggle();
                }
            }

            // A click on the bar outside the indicators closes the open panel.
            MouseArea {
                anchors.fill: parent
                onClicked: barPanels.close()
            }

            // Left: workspace indices.
            Row {
                id: workspacesRow
                anchors.left: parent.left
                anchors.leftMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                Repeater {
                    model: bar.outputWorkspaces

                    Rectangle {
                        id: wsItem
                        required property var modelData
                        required property int index

                        readonly property bool isFocused: !!wsItem.modelData.is_focused
                        readonly property bool isActive: !!wsItem.modelData.is_active

                        width: Math.max(24, label.implicitWidth + 12)
                        height: 22
                        radius: 4
                        color: wsItem.isFocused ? root.accentColor : "transparent"

                        Text {
                            id: label
                            anchors.centerIn: parent
                            text: wsItem.modelData.name || String(wsItem.modelData.idx)
                            color: wsItem.isFocused
                                ? root.bgColor
                                : (wsItem.isActive ? root.fgColor : root.dimColor)
                            font.pixelSize: 12
                            font.bold: wsItem.isFocused
                        }

                        MouseArea {
                            anchors.fill: parent
                            onClicked: root.focusWorkspace(wsItem.modelData)
                        }

                        HintBadge {
                            anchors.centerIn: parent
                            theme: root
                            shown: bar.hinting
                            label: Hints.workspaceKey(wsItem.index)
                        }
                    }
                }
            }

            // Centre: the focused window's icon and title; none on an empty
            // workspace.
            Item {
                id: centre

                readonly property var toplevel: ToplevelManager.activeToplevel
                readonly property var entry: centre.toplevel ? DesktopEntries.heuristicLookup(centre.toplevel.appId) : null
                readonly property string iconPath: centre.entry ? Quickshell.iconPath(centre.entry.icon, true) : ""
                readonly property real iconSlot: centre.iconPath !== "" ? 14 + row.spacing : 0
                // Between the workspaces and the right items, less a gap.
                readonly property real lo: workspacesRow.x + workspacesRow.width + 16
                readonly property real hi: rightItems.x - 16

                visible: titleText.text !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, Math.min(centre.iconSlot + titleText.implicitWidth, centre.hi - centre.lo))
                height: row.height
                // Centred when it fits, else slid left to stop short of the
                // right items.
                x: Math.min(Math.max(bar.width / 2 - centre.width / 2, centre.lo), centre.hi - centre.width)
                // Gives way to the notification island on this output.
                opacity: notificationIsland.shown && notificationIsland.screenName === bar.modelData.name ? 0 : 1
                Behavior on opacity { NumberAnimation { duration: 150 } }

                Row {
                    id: row
                    spacing: 6

                    IconImage {
                        visible: centre.iconPath !== ""
                        anchors.verticalCenter: parent.verticalCenter
                        implicitSize: 14
                        source: centre.iconPath
                    }

                    Text {
                        id: titleText
                        width: Math.max(0, centre.width - centre.iconSlot)
                        // The end of a title (repo, file) is what tells windows apart.
                        elide: Text.ElideMiddle
                        // Any client sets its own title. AutoText would render markup
                        // in it, <img src="https://…"> included, and fetch that URL.
                        textFormat: Text.PlainText
                        text: WindowTitle.withoutAppName(centre.toplevel?.title ?? "", centre.entry?.name ?? "",
                                                         centre.toplevel?.appId ?? "")
                        color: root.dimColor
                        font.pixelSize: 12
                    }
                }
            }

            // Right: Claude Code usage, network, volume, battery, caffeine,
            // notifications, clock.
            Row {
                id: rightItems
                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 12

                ClaudeUsage {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: root
                    panels: barPanels
                    compact: bar.compact
                    summary: root.claudeUsage
                    now: clock.date
                }

                Network {
                    anchors.verticalCenter: parent.verticalCenter
                    compact: bar.compact
                    theme: root
                    panels: barPanels
                }

                Volume {
                    anchors.verticalCenter: parent.verticalCenter
                    compact: bar.compact
                    theme: root
                    panels: barPanels
                }

                Battery {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: root
                    panels: barPanels
                }

                Caffeine {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: root
                    on: root.caffeine
                    onFlipped: root.caffeine = !root.caffeine
                }

                Notifications {
                    anchors.verticalCenter: parent.verticalCenter
                    theme: root
                    panels: barPanels
                    service: notifications
                    now: clock.date
                }

                Clock {
                    anchors.verticalCenter: parent.verticalCenter
                    compact: bar.compact
                    theme: root
                    panels: barPanels
                    now: clock.date
                    calendar: root.calendar
                }
            }

            // The items' hints, last so they sit on top. Placed as the hints
            // come up, as an item can sit anywhere in the bar.
            Repeater {
                model: bar.hinted

                HintBadge {
                    id: badge
                    required property var modelData
                    readonly property point centre: badge.modelData.item.mapToItem(
                        null, badge.modelData.item.width / 2, badge.modelData.item.height / 2)

                    x: Math.round(badge.centre.x - badge.width / 2)
                    y: Math.round(badge.centre.y - badge.height / 2)
                    theme: root
                    shown: bar.hinting && badge.modelData.item.visible
                    label: badge.modelData.key
                }
            }
        }
    }
}
