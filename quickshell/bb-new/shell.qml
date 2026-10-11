pragma ComponentBehavior: Bound

// Start a bb thread from anywhere in the niri session: a prompt, and under it
// the model, the effort and the project the thread starts with — the newest
// Opus, high, no project, until Ctrl+S saves others.
//
// The overlay opens over IPC, bound in ~/.config/niri/config.kdl:
//
//     qs -c bb-new ipc call bbnew toggle             Mod+N
//
// and the defaults can be read and set the same way:
//
//     qs -c bb-new ipc call bbnew get effort
//     qs -c bb-new ipc call bbnew set effort max     a model by id or name, an
//                                                    effort, a project by id or
//                                                    name, or none
//
// Super+Space b (chauvenity's leader menu) opens it with other settings for
// this thread only, and asks what to offer:
//
//     qs -c bb-new ipc call bbnew openWith "Fable 5.1" max ""   "" leaves one
//                                                    as it is; a project "?"
//                                                    opens the project list
//     qs -c bb-new ipc call bbnew choices            as JSON, for the menu
//
// (From a shell without WAYLAND_DISPLAY, a bb thread's for one, add
// `--any-display` after `ipc`: qs only finds instances on its own display.)
//
// It runs as bb-new.service, which niri.service pulls in through
// ~/.config/systemd/user/niri.service.d/50-bb-new.conf like snippets.service.
// The defaults, and the models and projects bb last listed, are kept in
// state.json under Quickshell.stateDir. bb is asked again each time the overlay
// opens, so the lists are there at once and catch up a moment later.
//
// A thread with no project goes to bb's personal workspace, as pick-to-bb's
// do; one with a project gets the environment bb remembers for it. Once bb
// has started the thread, the overlay closes, leaving bb where it was; if bb
// refuses, the overlay stays, with bb's error and the prompt. A prompt closed with Esc
// is kept, with its settings, for the next open; an empty one starts over
// from the defaults.
//
// Keys: Enter start · Shift+Enter new line · Alt+M / Alt+Shift+M next /
// previous model · Alt+E / Alt+Shift+E next / previous effort · Alt+P pick the
// project · Ctrl+S save these settings as the defaults · Esc close.
// Project list: type to filter · ↑↓ or Ctrl+J/K select · Enter pick · Esc or
// Alt+P back to the prompt.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "bbnew.mjs" as Logic

ShellRoot {
    id: root

    // chauvenity's bar palette, so the overlay looks like part of it.
    readonly property color bgColor: "#1c1b22"
    readonly property color fgColor: "#deddda"
    readonly property color dimColor: "#77767b"
    readonly property color accentColor: "#62a0ea"
    readonly property color goodColor: "#8ff0a4"
    readonly property color badColor: "#f66151"
    readonly property color starColor: "#f9f06b"
    readonly property color panelColor: "#24232b"
    readonly property color lineColor: "#36353e"
    readonly property color selectColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.16)
    readonly property string monoFont: "JetBrains Mono"
    // JetBrains Mono's ligatures draw `->` as an arrow: a prompt has to be shown
    // as the characters it holds.
    readonly property var noLigatures: ({ liga: 0, calt: 0 })
    readonly property var theme: ({
        fg: String(root.fgColor),
        dim: String(root.dimColor),
        accent: String(root.accentColor),
        panel: String(root.panelColor),
        line: String(root.lineColor),
        font: root.monoFont,
    })

    // Found on bb-new.service's PATH.
    readonly property string bb: "bb"

    property bool open: false
    property var targetScreen: null

    // What the thread starts with: ids, "" for no project.
    property string model: Logic.DEFAULTS.model
    property string effort: Logic.DEFAULTS.effort
    property string project: Logic.DEFAULTS.project

    readonly property var models: store.models.length > 0 ? store.models : Logic.FALLBACK_MODELS
    readonly property var projects: store.projects
    readonly property var currentModel: Logic.findModel(root.models, root.model)

    property bool picking: false
    property string pickQuery: ""
    // What `openWith` asked for, applied as the overlay opens: {change, pick}.
    property var asked: null
    readonly property var picks: Logic.filterProjects(root.projects, root.pickQuery)

    property bool starting: false
    property bool timedOut: false
    property string error: ""
    property string notice: ""

    readonly property var hints: root.picking
        ? [["type", "filter"], ["↑↓", "select"], ["Enter", "pick"], ["Esc", "back"]]
        : [["Enter", "start"], ["Shift+Enter", "new line"], ["Alt+M", "model"], ["Alt+E", "effort"],
           ["Alt+P", "project"], ["Ctrl+S", "save as default"], ["Esc", "close"]]

    // bb listed something else: keep the settings to what it has.
    onModelsChanged: root.settle()
    onProjectsChanged: root.settle()

    FileView {
        id: storeFile
        path: Quickshell.stateDir + "/state.json"
        watchChanges: true
        onFileChanged: storeFile.reload()
        onAdapterUpdated: storeFile.writeAdapter()
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                storeFile.writeAdapter();
        }

        JsonAdapter {
            id: store
            // The defaults: ids, "" for no project.
            property string model: Logic.DEFAULTS.model
            property string effort: Logic.DEFAULTS.effort
            property string project: Logic.DEFAULTS.project
            // What bb last listed: [{id, name, efforts, defaultEffort}] and
            // [{id, name}].
            property var models: []
            property var projects: []
        }
    }

    // --- opening ----------------------------------------------------------------

    IpcHandler {
        target: "bbnew"

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
        // Opens with these settings over those it would open with; "" leaves
        // one as it is. Answers why not, or "" once it is opening.
        function openWith(model: string, effort: string, project: string): string {
            const asked = Logic.readOpenWith(model, effort, project, root.models, root.projects);
            if (asked.error)
                return asked.error;
            root.asked = asked;
            if (root.open)
                root.useAsked();
            else
                root.summon();
            return "";
        }
        // What Super+Space's bb page offers, as JSON: see leaderArguments.
        function choices(): string {
            return JSON.stringify(Logic.leaderArguments(root.models, { model: store.model, effort: store.effort }));
        }
        // A default: model, effort or project ("none" for no project).
        function get(key: string): string {
            if (key === "project")
                return store.project || "none";
            if (key === "model" || key === "effort")
                return store[key];
            return `unknown setting "${key}"; model, effort or project`;
        }
        // Sets a default and answers "ok", or why not. A new model brings its
        // own default effort if it does not take the current one.
        function set(key: string, value: string): string {
            const checked = Logic.checkDefault(key, value, root.models, root.projects, store.model);
            if (checked.error)
                return checked.error;
            store[key] = checked.value;
            if (key === "model")
                store.effort = Logic.effortFor(Logic.findModel(root.models, checked.value), store.effort);
            return "ok";
        }
    }

    // Lets pick-to-bb (Mod+Shift+A) describe the overlay's elements.
    PickInspector {
        roots: [overlay]
    }

    function summon() {
        probe.running = true;
        modelLister.running = true;
        projectLister.running = true;
    }

    // Opens on the output niri has focused rather than wherever Qt puts it.
    function present(output) {
        root.targetScreen = Quickshell.screens.find(s => s.name === output) ?? Quickshell.screens[0];
        if (promptInput.text.trim() === "") {
            root.useDefaults();
            root.error = "";
        }
        root.picking = false;
        root.notice = "";
        root.open = true;
        root.useAsked();
    }

    // What `openWith` asked for, over the settings the overlay opened with.
    function useAsked() {
        const asked = root.asked;
        root.asked = null;
        if (!asked)
            return;
        root.apply(Logic.normalize(Object.assign({ model: root.model, effort: root.effort, project: root.project }, asked.change),
                                   root.models, root.projects));
        if (asked.pick && !root.picking)
            root.beginPick();
    }

    function close() {
        root.open = false;
        root.picking = false;
    }

    function useDefaults() {
        root.apply(Logic.normalize({ model: store.model, effort: store.effort, project: store.project }, root.models, root.projects));
    }

    function settle() {
        root.apply(Logic.normalize({ model: root.model, effort: root.effort, project: root.project }, root.models, root.projects));
    }

    function apply(settings) {
        root.model = settings.model;
        root.effort = settings.effort;
        root.project = settings.project;
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
    // Asked at start, for `ipc call bbnew set` before the first open, and again
    // on each open. Stored only when it changed, so an open does not rewrite
    // state.json.

    Component.onCompleted: {
        modelLister.running = true;
        projectLister.running = true;
    }

    Process {
        id: modelLister
        command: [root.bb, "provider", "models", Logic.PROVIDER, "--json"]
        stdout: StdioCollector {
            id: modelsOut
            onStreamFinished: {
                const models = Logic.parseModels(modelsOut.text);
                if (models.length > 0 && JSON.stringify(models) !== JSON.stringify(store.models))
                    store.models = models;
            }
        }
    }

    Process {
        id: projectLister
        command: [root.bb, "project", "list", "--json"]
        stdout: StdioCollector {
            id: projectsOut
            onStreamFinished: {
                if (projectsOut.text.trim() === "")
                    return;
                const projects = Logic.parseProjects(projectsOut.text);
                if (JSON.stringify(projects) !== JSON.stringify(store.projects))
                    store.projects = projects;
            }
        }
    }

    // --- changing the settings ------------------------------------------------------

    function cycleModel(step) {
        root.model = Logic.nextModel(root.models, root.model, step);
        root.effort = Logic.effortFor(Logic.findModel(root.models, root.model), root.effort);
    }

    function cycleEffort(step) {
        root.effort = Logic.nextEffort(root.currentModel, root.effort, step);
    }

    function saveDefaults() {
        store.model = root.model;
        store.effort = root.effort;
        store.project = root.project;
        root.notice = "Saved as the defaults: " + Logic.modelName(root.models, root.model) + " · " + root.effort
            + " · " + Logic.projectName(root.projects, root.project);
        noticeTimer.restart();
    }

    Timer {
        id: noticeTimer
        interval: 2500
        onTriggered: root.notice = ""
    }

    function beginPick() {
        pickFilter.text = "";
        root.picking = true;
        pickList.currentIndex = Math.max(0, root.picks.findIndex(p => p.id === root.project));
        pickList.positionViewAtIndex(pickList.currentIndex, ListView.Contain);
        pickFilter.forceActiveFocus();
    }

    function endPick() {
        root.picking = false;
        promptInput.forceActiveFocus();
    }

    function pickCurrent() {
        const picked = root.picks[pickList.currentIndex];
        if (picked)
            root.project = picked.id;
        root.endPick();
    }

    function movePick(step) {
        const count = root.picks.length;
        if (count === 0)
            return;
        pickList.currentIndex = (pickList.currentIndex + step + count) % count;
        pickList.positionViewAtIndex(pickList.currentIndex, ListView.Contain);
    }

    // --- starting the thread --------------------------------------------------------

    function start() {
        const prompt = promptInput.text.trim();
        if (root.starting || prompt === "")
            return;
        root.error = "";
        root.notice = "";
        root.starting = true;
        spawner.exec(Logic.spawnCommand(root.bb, { model: root.model, effort: root.effort, project: root.project }, prompt));
        spawnTimeout.restart();
    }

    Process {
        id: spawner
        stdout: StdioCollector {
            id: spawnOut
        }
        stderr: StdioCollector {
            id: spawnErr
        }
        onExited: code => {
            spawnTimeout.stop();
            root.starting = false;
            if (root.timedOut) {
                root.timedOut = false;
                root.error = "bb did not answer within a minute";
                return;
            }
            const answer = Logic.parseSpawn(spawnOut.text, spawnErr.text, code);
            if (answer.error) {
                root.error = answer.error;
                return;
            }
            promptInput.text = "";
            root.close();
        }
    }

    Timer {
        id: spawnTimeout
        interval: 60000
        onTriggered: {
            root.timedOut = true;
            spawner.running = false;
        }
    }

    // --- keys -------------------------------------------------------------------

    // Both the prompt and the project filter send their keys here first; false
    // leaves the key to them.
    function handleKey(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const alt = (event.modifiers & Qt.AltModifier) !== 0;
        const key = event.key;
        const enter = key === Qt.Key_Return || key === Qt.Key_Enter;

        if (key === Qt.Key_Escape) {
            if (root.picking)
                root.endPick();
            else
                root.close();
        } else if (root.starting) {
            // Nothing changes while bb is starting the thread.
        } else if (alt && key === Qt.Key_M) {
            root.cycleModel(shift ? -1 : 1);
        } else if (alt && key === Qt.Key_E) {
            root.cycleEffort(shift ? -1 : 1);
        } else if (alt && key === Qt.Key_P) {
            if (root.picking)
                root.endPick();
            else
                root.beginPick();
        } else if (ctrl && key === Qt.Key_S) {
            root.saveDefaults();
        } else if (root.picking && (key === Qt.Key_Down || (ctrl && (key === Qt.Key_J || key === Qt.Key_N)))) {
            root.movePick(1);
        } else if (root.picking && (key === Qt.Key_Up || (ctrl && (key === Qt.Key_K || key === Qt.Key_P)))) {
            root.movePick(-1);
        } else if (root.picking && enter) {
            root.pickCurrent();
        } else if (!root.picking && enter && !shift) {
            root.start();
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
        WlrLayershell.namespace: "bb-new"
        WlrLayershell.keyboardFocus: root.open ? WlrKeyboardFocus.Exclusive : WlrKeyboardFocus.None
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
            if (root.picking) {
                pickFilter.forceActiveFocus();
            } else {
                promptInput.forceActiveFocus();
                promptInput.cursorPosition = promptInput.length;
            }
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
            width: Math.round(Math.min(680, overlay.width - 80))
            height: Math.round(body.implicitHeight + 32)
            x: Math.round((overlay.width - frame.width) / 2)
            y: Math.round(overlay.height * 0.2)

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
                            text: "New bb thread"
                            color: root.dimColor
                            font.family: root.monoFont
                            font.pixelSize: 11
                        }
                        Text {
                            anchors.right: parent.right
                            text: Logic.PROVIDER
                            color: root.dimColor
                            font.family: root.monoFont
                            font.pixelSize: 11
                        }
                    }

                    // The prompt: grows with its text, then scrolls.
                    Rectangle {
                        width: parent.width
                        height: Math.min(Math.max(promptInput.contentHeight, 20), 220) + 20
                        radius: 8
                        color: root.panelColor
                        border.width: 1
                        border.color: promptInput.activeFocus ? root.accentColor : root.lineColor

                        Flickable {
                            id: promptFlick
                            anchors {
                                fill: parent
                                margins: 10
                            }
                            clip: true
                            contentWidth: promptFlick.width
                            contentHeight: promptInput.contentHeight
                            boundsBehavior: Flickable.StopAtBounds

                            function follow(r) {
                                if (promptFlick.contentY >= r.y)
                                    promptFlick.contentY = r.y;
                                else if (promptFlick.contentY + promptFlick.height <= r.y + r.height)
                                    promptFlick.contentY = r.y + r.height - promptFlick.height;
                            }

                            TextEdit {
                                id: promptInput
                                width: promptFlick.width
                                focus: true
                                color: root.fgColor
                                selectionColor: root.accentColor
                                selectByMouse: true
                                wrapMode: TextEdit.Wrap
                                readOnly: root.starting
                                font.family: root.monoFont
                                font.pixelSize: 14
                                font.features: root.noLigatures
                                onCursorRectangleChanged: promptFlick.follow(promptInput.cursorRectangle)
                                Keys.onPressed: event => {
                                    if (root.handleKey(event))
                                        event.accepted = true;
                                }
                            }

                            Text {
                                visible: promptInput.text.length === 0
                                text: "What should the agent do?"
                                color: root.dimColor
                                font: promptInput.font
                            }
                        }
                    }

                    Row {
                        spacing: 8

                        Chip {
                            label: "model"
                            value: root.currentModel ? root.currentModel.name : root.model
                            changed: root.model !== store.model
                            theme: root.theme
                        }
                        Chip {
                            label: "effort"
                            value: root.effort
                            changed: root.effort !== store.effort
                            theme: root.theme
                        }
                        Chip {
                            label: "project"
                            value: Logic.projectName(root.projects, root.project)
                            changed: root.project !== store.project
                            theme: root.theme
                        }
                    }

                    // Alt+P: the projects, filtered as you type.
                    Rectangle {
                        visible: root.picking
                        width: parent.width
                        height: pickColumn.implicitHeight
                        radius: 8
                        color: root.panelColor
                        border.color: root.lineColor
                        clip: true

                        Column {
                            id: pickColumn
                            width: parent.width

                            Item {
                                width: parent.width
                                height: 32

                                Text {
                                    id: pickLabel
                                    x: 10
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: "project ›"
                                    color: root.accentColor
                                    font.family: root.monoFont
                                    font.pixelSize: 13
                                }
                                TextInput {
                                    id: pickFilter
                                    anchors {
                                        left: pickLabel.right
                                        leftMargin: 8
                                        right: parent.right
                                        rightMargin: 10
                                        verticalCenter: parent.verticalCenter
                                    }
                                    color: root.fgColor
                                    selectionColor: root.accentColor
                                    font.family: root.monoFont
                                    font.pixelSize: 13
                                    onTextChanged: {
                                        root.pickQuery = pickFilter.text;
                                        pickList.currentIndex = 0;
                                    }
                                    Keys.onPressed: event => {
                                        if (root.handleKey(event))
                                            event.accepted = true;
                                    }
                                }
                                Text {
                                    anchors {
                                        left: pickFilter.left
                                        verticalCenter: parent.verticalCenter
                                    }
                                    visible: pickFilter.text.length === 0
                                    text: "type to filter"
                                    color: root.dimColor
                                    font: pickFilter.font
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: root.lineColor
                            }

                            ListView {
                                id: pickList
                                width: parent.width
                                height: Math.min(root.picks.length, 8) * 26
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds
                                model: root.picks

                                delegate: Rectangle {
                                    id: pickRow
                                    required property var modelData
                                    required property int index
                                    readonly property bool current: pickRow.index === pickList.currentIndex

                                    width: pickList.width
                                    height: 26
                                    color: pickRow.current ? root.selectColor : "transparent"

                                    Rectangle {
                                        visible: pickRow.current
                                        width: 2
                                        height: parent.height
                                        color: root.accentColor
                                    }
                                    // ★ the default project.
                                    Text {
                                        x: 10
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: pickRow.modelData.id === store.project ? "★" : ""
                                        color: root.starColor
                                        font.family: root.monoFont
                                        font.pixelSize: 12
                                    }
                                    Text {
                                        x: 28
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: pickRow.modelData.name
                                        color: pickRow.modelData.id === root.project ? root.accentColor : root.fgColor
                                        font.family: root.monoFont
                                        font.pixelSize: 13
                                    }
                                    Text {
                                        anchors {
                                            right: parent.right
                                            rightMargin: 10
                                            verticalCenter: parent.verticalCenter
                                        }
                                        text: pickRow.modelData.id || "personal workspace"
                                        color: root.dimColor
                                        font.family: root.monoFont
                                        font.pixelSize: 11
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            pickList.currentIndex = pickRow.index;
                                            root.pickCurrent();
                                        }
                                    }
                                }
                            }

                            Text {
                                visible: root.picks.length === 0
                                padding: 9
                                text: "No project matches"
                                color: root.dimColor
                                font.family: root.monoFont
                                font.pixelSize: 12
                            }
                        }
                    }

                    Text {
                        visible: root.error !== ""
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: root.error
                        color: root.badColor
                        font.family: root.monoFont
                        font.pixelSize: 12
                    }

                    Text {
                        visible: root.starting || root.notice !== ""
                        width: parent.width
                        elide: Text.ElideRight
                        text: root.starting ? "Starting the thread…" : root.notice
                        color: root.starting ? root.accentColor : root.goodColor
                        font.family: root.monoFont
                        font.pixelSize: 11
                    }

                    Flow {
                        visible: !root.starting && root.notice === ""
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
