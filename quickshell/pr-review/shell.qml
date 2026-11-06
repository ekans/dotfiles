pragma ComponentBehavior: Bound

// The pull requests waiting for your review, from anywhere in the niri
// session: the queue on the left, the focused one's description and CI state
// on the right. From there Enter opens it in the browser, t hands it to a bb
// thread in the repo's project, and d reads its diff, unified or split, with
// syntax colours.
//
// The overlay opens over IPC, from Super+Space p in chauvenity's leader menu:
//
//     qs -c pr-review ipc call prreview toggle
//
// (From a shell without WAYLAND_DISPLAY, a bb thread's for one, add
// `--any-display` after `ipc`: qs only finds instances on its own display.)
//
// It runs as pr-review.service, which niri.service pulls in through
// ~/.config/systemd/user/niri.service.d/50-pr-review.conf like bb-go.service.
//
// The queue is `gh search prs --review-requested=@me`; the last answer shows
// at once on each open while gh is asked again. Repos to leave out are
// `gh search` qualifiers in $XDG_CONFIG_HOME/pr-review/search, not in this
// repo: they name private work. x hides the focused pull request, one you will
// not review, and h shows the hidden ones again, dimmed, so x on one unhides
// it. The hidden URLs, one per line, are state kept in
// $XDG_STATE_HOME/pr-review/hidden, not in this repo. The diff is
// `gh pr diff`, coloured by one `bat` per file, so it shows in plain text and
// gains colour file by file.
//
// Keys, in the list: ↑↓ or j/k or Ctrl+J/K select · PgUp/PgDn scroll the
// preview · Enter open · t bb thread · d diff · x hide / unhide · h show hidden ·
// r refresh · Esc close.
// In the diff: ↑↓ or j/k scroll · PgUp/PgDn page · n/p next / previous file ·
// s unified / split · Enter open · t bb thread · Esc back to the list.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "prreview.mjs" as Logic

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
    readonly property color addColor: Qt.rgba(root.goodColor.r, root.goodColor.g, root.goodColor.b, 0.18)
    readonly property color delColor: Qt.rgba(root.badColor.r, root.badColor.g, root.badColor.b, 0.18)
    readonly property string monoFont: "JetBrains Mono"

    // Found on pr-review.service's PATH: gh, bb and bat.
    readonly property string bb: "bb"

    // Logic.CI_LOOK names a palette role.
    readonly property var roleColors: ({ warn: root.warnColor, bad: root.badColor, good: root.goodColor, dim: root.dimColor })

    property bool open: false
    property var targetScreen: null
    property double now: Date.now()

    // "list" or "diff".
    property string view: "list"

    // --- what gh lists ----------------------------------------------------------

    // The last answer as [Pr], null until there is one.
    property var prs: null
    // The URLs of the pull requests hidden, and whether the list shows them anyway.
    property var hidden: []
    property bool hiddenReady: false
    property bool showHidden: false
    // What the list shows, and the rest of this file indexes: `prs` stays gh's whole answer.
    readonly property var shown: Logic.visiblePrs(root.prs, root.hidden, root.showHidden)
    readonly property int hiddenCount: Logic.hiddenCount(root.prs, root.hidden)
    property bool listing: false
    property bool listAgain: false
    property string listFailure: ""
    property int index: 0
    readonly property var focusedPr: root.shown && root.shown.length > 0 ? (root.shown[root.index] ?? null) : null

    // The extra `gh search` qualifiers, once their file has been read or found
    // missing: asking gh sooner would not leave the excluded repos out.
    property var qualifiers: []
    property bool searchReady: false

    property string error: ""
    property string notice: ""

    // url -> {phase: "loading" | "ready" | "error", ci, at, error}
    property var ciCache: ({})
    property var ciFetching: null
    property var ciWanted: null
    readonly property var focusedCi: root.focusedPr ? (root.ciCache[root.focusedPr.url] ?? null) : null

    // The diff being read, or last read: {pr, url, updatedAt, phase: "loading"
    // | "ready" | "error", files, styled, error}. `styled` maps a path to its
    // StyledText lines as bat colours them.
    property var diff: null
    property string diffMode: Logic.DIFF_MODES[0]
    property var diffRows: []
    property var diffFetching: null
    property var hlQueue: []
    property var hlJob: null

    // The bb projects, null until bb has listed them.
    property var projects: null
    property string projectsFailure: ""
    property bool spawning: false
    property string spawnTitle: ""
    property string spawnProject: ""

    readonly property var activePr: root.view === "diff" && root.diff ? root.diff.pr : root.focusedPr
    readonly property var diffStats: root.diff && root.diff.phase === "ready" ? Logic.diffStats(root.diff.files) : null

    // --- opening ----------------------------------------------------------------

    IpcHandler {
        target: "prreview"

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
        name: "pr-review"
        open: root.open
    }

    // Lets pick-to-bb (Super+Space b a) describe the overlay's elements.
    PickInspector {
        roots: [overlay]
    }

    function summon() {
        probe.running = true;
        root.refresh();
        root.refreshProjects();
    }

    // Opens on the output niri has focused rather than wherever Qt puts it.
    function present(output) {
        root.targetScreen = Quickshell.screens.find(s => s.name === output) ?? Quickshell.screens[0];
        root.error = "";
        root.notice = "";
        root.now = Date.now();
        root.view = "list";
        root.index = 0;
        root.open = true;
    }

    function close() {
        root.open = false;
    }

    Process {
        id: probe
        command: ["niri", "msg", "--json", "focused-output"]
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: root.present(Logic.parseFocusedOutput(probeOut.text))
        }
    }

    // --- the queue --------------------------------------------------------------

    FileView {
        path: (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config")) + "/pr-review/search"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            root.qualifiers = Logic.parseSearch(text());
            root.searchReady = true;
            root.refresh();
        }
        onLoadFailed: {
            root.qualifiers = [];
            root.searchReady = true;
            root.refresh();
        }
    }

    FileView {
        id: hiddenFile
        path: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/pr-review/hidden"
        printErrors: false
        onLoaded: {
            root.hidden = Logic.parseHidden(text());
            root.hiddenReady = true;
        }
        onLoadFailed: {
            root.hidden = [];
            root.hiddenReady = true;
        }
    }

    Component.onCompleted: root.refreshProjects()

    function refresh() {
        if (!root.searchReady)
            return;
        if (lister.running) {
            root.listAgain = true;
            return;
        }
        root.listing = true;
        lister.exec(Logic.listCommand(root.qualifiers));
    }

    Process {
        id: lister
        stdout: StdioCollector {
            id: listOut
        }
        stderr: StdioCollector {
            id: listErr
        }
        onExited: code => {
            root.listing = false;
            const prs = code === 0 ? Logic.parsePrs(listOut.text) : null;
            if (prs === null) {
                root.listFailure = Logic.listError(listOut.text, listErr.text, code);
            } else {
                // Keeps the selection on the same pull request.
                const url = root.focusedPr ? root.focusedPr.url : "";
                root.prs = prs;
                root.listFailure = "";
                root.index = root.indexOfShown(url);
            }
            root.now = Date.now();
            if (root.listAgain) {
                root.listAgain = false;
                root.refresh();
            }
        }
    }

    // --- CI of the focused pull request -------------------------------------------

    onFocusedPrChanged: {
        ciDebounce.restart();
        previewFlick.contentY = 0;
    }

    // Moving through the list quickly does not ask gh about every row.
    Timer {
        id: ciDebounce
        interval: 150
        onTriggered: root.wantCi(root.focusedPr)
    }

    function setCi(url, entry) {
        const next = Object.assign({}, root.ciCache);
        next[url] = entry;
        root.ciCache = next;
    }

    function wantCi(pr) {
        if (!pr)
            return;
        const entry = root.ciCache[pr.url];
        if (entry && (entry.phase === "loading" || Date.now() - entry.at < 30000))
            return;
        // Only the newest one wanted waits for the one running.
        if (ciProc.running) {
            root.ciWanted = pr;
            return;
        }
        root.ciFetching = pr;
        root.setCi(pr.url, { phase: "loading", ci: entry ? entry.ci : null, at: Date.now(), error: "" });
        ciProc.exec(Logic.ciCommand(pr));
    }

    Process {
        id: ciProc
        stdout: StdioCollector {
            id: ciOut
        }
        stderr: StdioCollector {
            id: ciErr
        }
        onExited: code => {
            const pr = root.ciFetching;
            root.ciFetching = null;
            const ci = code === 0 ? Logic.parseCi(ciOut.text) : null;
            if (ci)
                root.setCi(pr.url, { phase: "ready", ci: ci, at: Date.now(), error: "" });
            else
                root.setCi(pr.url, { phase: "error", ci: null, at: Date.now(), error: Logic.listError(ciOut.text, ciErr.text, code) });
            const wanted = root.ciWanted;
            root.ciWanted = null;
            root.wantCi(wanted);
        }
    }

    // --- bb projects and threads ----------------------------------------------------

    function refreshProjects() {
        if (!projectLister.running)
            projectLister.exec(Logic.projectsCommand(root.bb));
    }

    Process {
        id: projectLister
        stdout: StdioCollector {
            id: projectsOut
        }
        stderr: StdioCollector {
            id: projectsErr
        }
        onExited: code => {
            const projects = code === 0 ? Logic.parseProjects(projectsOut.text) : null;
            if (projects === null) {
                root.projectsFailure = Logic.commandError("bb", projectsOut.text, projectsErr.text, code);
            } else {
                root.projects = projects;
                root.projectsFailure = "";
            }
        }
    }

    function startThread() {
        const pr = root.activePr;
        if (!pr || root.spawning)
            return;
        root.error = "";
        root.notice = "";
        if (root.projects === null) {
            root.error = (root.projectsFailure || "bb has not listed its projects yet") + ": no thread started.";
            return;
        }
        const project = Logic.findProject(root.projects, pr.repo);
        if (!project) {
            root.error = "No bb project for " + pr.repo + ": no thread started.";
            return;
        }
        root.spawning = true;
        root.spawnTitle = Logic.threadTitle(pr);
        root.spawnProject = project.name;
        spawner.exec(Logic.spawnCommand(root.bb, project.id, pr));
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
            root.spawning = false;
            const answer = Logic.parseSpawn(spawnOut.text, spawnErr.text, code);
            if (answer.error)
                root.error = answer.error;
            else
                root.notice = "Started " + root.spawnTitle + " in " + root.spawnProject + ".";
        }
    }

    // --- the diff -------------------------------------------------------------------

    function setDiff(patch) {
        root.diff = Object.assign({}, root.diff, patch);
    }

    // Rebuilds the rows the list shows. With a file number the view goes to
    // that file's row; without, it stays where it was, so colour arriving for
    // a file does not throw the reader back to the top.
    function rebuildRows(file) {
        const d = root.diff;
        const rows = !d ? [] : (root.diffMode === "split" ? Logic.splitRows(d.files, d.styled) : Logic.unifiedRows(d.files, d.styled));
        const y = diffList.contentY;
        root.diffRows = rows;
        if (file >= 0) {
            const starts = Logic.fileStarts(rows);
            diffList.positionViewAtIndex(starts.length > 0 ? starts[Math.min(file, starts.length - 1)] : 0, ListView.Beginning);
        } else {
            diffList.contentY = y;
        }
    }

    function showDiff() {
        const pr = root.focusedPr;
        if (!pr)
            return;
        root.error = "";
        root.notice = "";
        root.view = "diff";
        const d = root.diff;
        // The same pull request, not updated since: the diff is still good.
        if (d && d.url === pr.url && d.updatedAt === pr.updatedAt && d.phase !== "error")
            return;
        root.hlQueue = [];
        if (hlProc.running)
            hlProc.running = false;
        root.diff = { pr: pr, url: pr.url, updatedAt: pr.updatedAt, phase: "loading", files: [], styled: ({}), error: "" };
        root.rebuildRows(0);
        root.fetchDiff(pr);
    }

    function fetchDiff(pr) {
        // The exit of the one running starts this one if it is still wanted.
        if (diffProc.running)
            return;
        root.diffFetching = pr;
        diffProc.exec(Logic.diffCommand(pr));
    }

    Process {
        id: diffProc
        stdout: StdioCollector {
            id: diffOut
        }
        stderr: StdioCollector {
            id: diffErr
        }
        onExited: code => {
            const fetched = root.diffFetching;
            root.diffFetching = null;
            const d = root.diff;
            if (!d || d.phase !== "loading")
                return;
            if (d.url !== fetched.url) {
                root.fetchDiff(d.pr);
                return;
            }
            const files = Logic.parseDiff(diffOut.text);
            if (code !== 0 && files.length === 0) {
                root.setDiff({ phase: "error", error: Logic.listError(diffOut.text, diffErr.text, code) });
                return;
            }
            root.setDiff({ phase: "ready", files: files });
            root.rebuildRows(0);
            root.hlQueue = Logic.highlightQueue(files);
            root.pumpHighlight();
        }
    }

    // One bat at a time, a file after the file before it.
    function pumpHighlight() {
        const d = root.diff;
        if (hlProc.running || !d || d.phase !== "ready" || root.hlQueue.length === 0)
            return;
        const file = d.files[root.hlQueue[0]];
        root.hlQueue = root.hlQueue.slice(1);
        root.hlJob = { url: d.url, file: file };
        hlProc.command = Logic.highlightCommand(file.path);
        hlProc.stdinEnabled = true;
        hlProc.running = true;
    }

    Process {
        id: hlProc
        stdinEnabled: false
        environment: Logic.HIGHLIGHT_ENV
        stdout: StdioCollector {
            id: hlOut
        }
        // bat reads to the end of its input: closing stdin lets it finish.
        onStarted: {
            hlProc.write(Logic.highlightInput(root.hlJob.file));
            hlProc.stdinEnabled = false;
        }
        onExited: code => {
            const job = root.hlJob;
            const d = root.diff;
            const html = code === 0 && d && d.url === job.url ? Logic.applyHighlight(job.file, hlOut.text) : null;
            if (html) {
                const styled = Object.assign({}, d.styled);
                styled[job.file.path] = html;
                root.setDiff({ styled: styled });
                root.rebuildRows(-1);
            }
            root.pumpHighlight();
        }
    }

    // --- keys -------------------------------------------------------------------

    // Where `url` is in the list, else the current place kept inside it.
    function indexOfShown(url) {
        const shown = root.shown ?? [];
        const at = shown.findIndex(p => p.url === url);
        return at >= 0 ? at : Math.max(0, Math.min(root.index, shown.length - 1));
    }

    function toggleHide() {
        const pr = root.focusedPr;
        // Until the file is read, a write would drop what is in it.
        if (!pr || !root.hiddenReady)
            return;
        root.hidden = Logic.toggleHidden(root.hidden, pr.url);
        hiddenFile.setText(Logic.hiddenText(root.hidden, root.prs));
        root.index = root.indexOfShown("");
    }

    function toggleShowHidden() {
        const url = root.focusedPr ? root.focusedPr.url : "";
        root.showHidden = !root.showHidden;
        root.index = root.indexOfShown(url);
        prList.positionViewAtIndex(root.index, ListView.Contain);
    }

    function move(step) {
        const count = root.shown ? root.shown.length : 0;
        if (count === 0)
            return;
        root.index = (root.index + step + count) % count;
        prList.positionViewAtIndex(root.index, ListView.Contain);
    }

    function scrollPreview(px) {
        const max = Math.max(0, previewFlick.contentHeight - previewFlick.height);
        previewFlick.contentY = Math.max(0, Math.min(max, previewFlick.contentY + px));
    }

    function scrollDiff(px) {
        const max = Math.max(0, diffList.contentHeight - diffList.height);
        diffList.contentY = Math.max(0, Math.min(max, diffList.contentY + px));
    }

    // The row at the top of the diff.
    function topRow() {
        return Math.max(0, diffList.indexAt(10, diffList.contentY + 1));
    }

    function stepFile(step) {
        const starts = Logic.fileStarts(root.diffRows);
        const top = root.topRow();
        const target = step > 0 ? starts.find(i => i > top) : starts.filter(i => i < top).pop();
        if (target !== undefined)
            diffList.positionViewAtIndex(target, ListView.Beginning);
    }

    // Keeps the file at the top of the view across the switch.
    function toggleMode() {
        const file = Logic.fileNumberAt(root.diffRows, root.topRow());
        const modes = Logic.DIFF_MODES;
        root.diffMode = modes[(modes.indexOf(root.diffMode) + 1) % modes.length];
        root.rebuildRows(file);
    }

    function openPr() {
        const pr = root.activePr;
        if (!pr)
            return;
        Qt.openUrlExternally(pr.url);
        root.close();
    }

    // What each action of Logic.KEYS does.
    readonly property var actions: ({
            next: () => root.move(1),
            prev: () => root.move(-1),
            previewDown: () => root.scrollPreview(previewFlick.height - 40),
            previewUp: () => root.scrollPreview(40 - previewFlick.height),
            open: () => root.openPr(),
            thread: () => root.startThread(),
            diff: () => root.showDiff(),
            hide: () => root.toggleHide(),
            showHidden: () => root.toggleShowHidden(),
            refresh: () => {
                if (root.focusedPr)
                    root.setCi(root.focusedPr.url, { phase: "ready", ci: null, at: 0, error: "" });
                root.refresh();
                ciDebounce.restart();
            },
            close: () => root.close(),
            lineDown: () => root.scrollDiff(60),
            lineUp: () => root.scrollDiff(-60),
            pageDown: () => root.scrollDiff(diffList.height - 40),
            pageUp: () => root.scrollDiff(40 - diffList.height),
            nextFile: () => root.stepFile(1),
            prevFile: () => root.stepFile(-1),
            mode: () => root.toggleMode(),
            back: () => {
                root.view = "list";
                root.error = "";
            }
        })

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
        WlrLayershell.namespace: "pr-review"
        WlrLayershell.keyboardFocus: overlayFocus.keyboardFocus
        color: "transparent"
        // niri blurs the windows behind the card: niri/config.kdl turns
        // xray off for the overlay layer.
        BackgroundEffect.blurRegion: Region {
            item: card
            radius: card.radius
        }

        onVisibleChanged: {
            if (!overlay.visible)
                return;
            keys.forceActiveFocus();
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

            // The diff takes nearly the whole screen.
            readonly property bool wide: root.view === "diff"
            width: Math.round(frame.wide ? overlay.width * 0.94 : Math.min(1100, overlay.width - 80))
            height: Math.round(frame.wide ? overlay.height * 0.94 : Math.min(580, overlay.height * 0.72))
            x: Math.round((overlay.width - frame.width) / 2)
            y: Math.round(overlay.height * (frame.wide ? 0.03 : 0.12))

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

                FocusScope {
                    id: keys
                    anchors.fill: parent
                    focus: true

                    Keys.onPressed: event => {
                        const name = Logic.keyName(event.key, event.text, (event.modifiers & Qt.ControlModifier) !== 0);
                        const action = Logic.actionFor(root.view, name);
                        if (action === "")
                            return;
                        event.accepted = true;
                        root.actions[action]();
                    }
                }

                // The title line.
                Item {
                    id: header
                    anchors {
                        top: parent.top
                        left: parent.left
                        right: parent.right
                        margins: 16
                    }
                    height: 16

                    Text {
                        id: headerTitle
                        anchors.verticalCenter: parent.verticalCenter
                        width: parent.width - headerRight.implicitWidth - 16
                        elide: Text.ElideRight
                        text: root.view === "diff" && root.diff
                            ? root.diff.pr.repoName + "#" + root.diff.pr.number + " " + root.diff.pr.title
                            : "Pull requests waiting for your review" + (root.prs ? " · " + root.prs.length + (root.hiddenCount > 0 ? " · " + root.hiddenCount + " hidden" : "") : "")
                        color: root.view === "diff" ? root.fgColor : root.dimColor
                        font.family: root.monoFont
                        font.pixelSize: 11
                        font.bold: root.view === "diff"
                    }
                    Text {
                        id: headerRight
                        anchors {
                            right: parent.right
                            verticalCenter: parent.verticalCenter
                        }
                        textFormat: Text.StyledText
                        text: {
                            if (root.view === "diff") {
                                const s = root.diffStats;
                                const mode = "  " + root.diffMode;
                                if (!s)
                                    return root.diff && root.diff.phase === "loading" ? "reading the diff…" + mode : mode;
                                return s.files + (s.files === 1 ? " file  " : " files  ")
                                    + "<font color=\"" + root.goodColor + "\">+" + s.adds + "</font> "
                                    + "<font color=\"" + root.badColor + "\">−" + s.dels + "</font>" + mode;
                            }
                            return root.listing ? "asking gh…" : "";
                        }
                        color: root.dimColor
                        font.family: root.monoFont
                        font.pixelSize: 11
                    }
                }

                // What the user is told, above the key chips.
                Column {
                    id: footer
                    anchors {
                        bottom: parent.bottom
                        left: parent.left
                        right: parent.right
                        margins: 16
                    }
                    spacing: 8

                    Text {
                        visible: text !== ""
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: root.error || root.listFailure
                        color: root.badColor
                        font.family: root.monoFont
                        font.pixelSize: 12
                    }

                    Text {
                        visible: root.spawning || root.notice !== ""
                        width: parent.width
                        wrapMode: Text.Wrap
                        text: root.spawning ? "Starting a thread…" : root.notice
                        color: root.spawning ? root.accentColor : root.goodColor
                        font.family: root.monoFont
                        font.pixelSize: 11
                    }

                    Flow {
                        width: parent.width
                        spacing: 12

                        Repeater {
                            model: Logic.HINTS[root.view]

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

                // --- the list view ---------------------------------------------------
                Item {
                    id: listView
                    visible: root.view === "list"
                    anchors {
                        top: header.bottom
                        topMargin: 10
                        bottom: footer.top
                        bottomMargin: 10
                        left: parent.left
                        right: parent.right
                        leftMargin: 16
                        rightMargin: 16
                    }

                    // The pull requests.
                    Rectangle {
                        id: listPane
                        anchors {
                            top: parent.top
                            bottom: parent.bottom
                            left: parent.left
                        }
                        width: Math.round(parent.width * 0.42)
                        radius: 8
                        color: root.panelColor
                        border.color: root.lineColor
                        clip: true

                        ListView {
                            id: prList
                            anchors.fill: parent
                            anchors.margins: 1
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds
                            model: root.shown ?? []
                            currentIndex: root.index

                            delegate: Rectangle {
                                id: row
                                required property var modelData
                                required property int index
                                readonly property bool current: row.index === root.index
                                readonly property bool isHidden: root.hidden.indexOf(row.modelData.url) !== -1

                                width: prList.width
                                height: 56
                                color: row.current ? root.selectColor : "transparent"

                                Rectangle {
                                    visible: row.current
                                    width: 2
                                    height: parent.height
                                    color: root.accentColor
                                }
                                Row {
                                    id: topLine
                                    x: 12
                                    y: 7
                                    spacing: 8

                                    Text {
                                        text: row.modelData.repoName + "#" + row.modelData.number
                                        color: row.isHidden ? root.dimColor : root.accentColor
                                        font.family: root.monoFont
                                        font.pixelSize: 11
                                    }
                                    Text {
                                        visible: row.modelData.draft
                                        text: "draft"
                                        color: root.warnColor
                                        font.family: root.monoFont
                                        font.pixelSize: 11
                                    }
                                    Text {
                                        visible: row.isHidden
                                        text: "hidden"
                                        color: root.dimColor
                                        font.family: root.monoFont
                                        font.pixelSize: 11
                                        font.italic: true
                                    }
                                    Text {
                                        visible: row.modelData.bot
                                        text: "bot"
                                        color: root.dimColor
                                        font.family: root.monoFont
                                        font.pixelSize: 11
                                    }
                                }
                                Text {
                                    x: 12
                                    y: 22
                                    width: parent.width - 24
                                    elide: Text.ElideRight
                                    text: row.modelData.title
                                    color: row.isHidden ? root.dimColor : root.fgColor
                                    font.family: root.monoFont
                                    font.pixelSize: 13
                                }
                                Text {
                                    x: 12
                                    y: 40
                                    width: parent.width - 24
                                    elide: Text.ElideRight
                                    text: row.modelData.author + " · " + Logic.age(row.modelData.updatedAt, root.now)
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 11
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: root.index = row.index
                                }
                            }
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !root.shown || root.shown.length === 0
                            text: root.prs === null ? (root.listing ? "Asking gh…" : "Nothing from gh yet") : (root.prs.length > 0 ? "Every pull request is hidden: h shows them" : "Nothing waiting for your review")
                            color: root.dimColor
                            font.family: root.monoFont
                            font.pixelSize: 12
                        }
                    }

                    // The focused one.
                    Flickable {
                        id: previewFlick
                        anchors {
                            top: parent.top
                            bottom: parent.bottom
                            left: listPane.right
                            leftMargin: 16
                            right: parent.right
                        }
                        clip: true
                        contentWidth: width
                        contentHeight: preview.height
                        boundsBehavior: Flickable.StopAtBounds

                        Column {
                            id: preview
                            visible: root.focusedPr !== null
                            width: previewFlick.width
                            spacing: 8

                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: root.focusedPr ? root.focusedPr.title : ""
                                color: root.fgColor
                                font.family: root.monoFont
                                font.pixelSize: 15
                                font.bold: true
                            }
                            Text {
                                width: parent.width
                                wrapMode: Text.Wrap
                                text: root.focusedPr ? root.focusedPr.repo + "#" + root.focusedPr.number + " by " + root.focusedPr.author : ""
                                color: root.dimColor
                                font.family: root.monoFont
                                font.pixelSize: 11
                            }

                            // CI: a dot and a word, the checks that failed under it.
                            Column {
                                id: ciBlock
                                width: parent.width
                                spacing: 3

                                readonly property var entry: root.focusedCi
                                readonly property var ci: ciBlock.entry ? ciBlock.entry.ci : null
                                readonly property var look: ciBlock.ci ? Logic.CI_LOOK[ciBlock.ci.state] : null

                                Row {
                                    spacing: 7

                                    Rectangle {
                                        anchors.verticalCenter: parent.verticalCenter
                                        width: 8
                                        height: 8
                                        radius: 4
                                        color: ciBlock.look ? root.roleColors[ciBlock.look.color] : root.dimColor
                                    }
                                    Text {
                                        text: ciBlock.look ? ciBlock.look.label : (ciBlock.entry && ciBlock.entry.phase === "error" ? "CI state unavailable" : "checking…")
                                        color: ciBlock.look ? root.roleColors[ciBlock.look.color] : root.dimColor
                                        font.family: root.monoFont
                                        font.pixelSize: 12
                                    }
                                    Text {
                                        visible: text !== ""
                                        text: ciBlock.ci ? Logic.ciDetail(ciBlock.ci) : ""
                                        color: root.dimColor
                                        font.family: root.monoFont
                                        font.pixelSize: 11
                                    }
                                }
                                Text {
                                    visible: ciBlock.ci !== null && ciBlock.ci.state === "failure"
                                    width: parent.width
                                    wrapMode: Text.Wrap
                                    text: ciBlock.ci ? ciBlock.ci.failing.join(", ") : ""
                                    color: root.badColor
                                    font.family: root.monoFont
                                    font.pixelSize: 11
                                }
                                Text {
                                    visible: ciBlock.entry !== null && ciBlock.entry.phase === "error"
                                    width: parent.width
                                    wrapMode: Text.Wrap
                                    text: ciBlock.entry ? ciBlock.entry.error : ""
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 11
                                }
                            }

                            Flow {
                                visible: root.focusedPr !== null && root.focusedPr.labels.length > 0
                                width: parent.width
                                spacing: 6

                                Repeater {
                                    model: root.focusedPr ? root.focusedPr.labels : []

                                    delegate: Rectangle {
                                        id: label
                                        required property string modelData
                                        width: labelText.implicitWidth + 12
                                        height: 18
                                        radius: 9
                                        color: root.panelColor
                                        border.color: root.lineColor

                                        Text {
                                            id: labelText
                                            anchors.centerIn: parent
                                            text: label.modelData
                                            color: root.fgColor
                                            font.family: root.monoFont
                                            font.pixelSize: 10
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                width: parent.width
                                height: 1
                                color: root.lineColor
                            }

                            Text {
                                readonly property string body: root.focusedPr ? Logic.previewBody(root.focusedPr.body) : ""
                                readonly property string shown: Logic.plainLinks(body)
                                width: parent.width
                                wrapMode: Text.Wrap
                                textFormat: body === "" ? Text.PlainText : Text.MarkdownText
                                text: body === "" ? "No description." : shown
                                color: body === "" ? root.dimColor : root.fgColor
                                font.family: root.monoFont
                                font.pixelSize: 12
                            }
                        }
                    }
                }

                // --- the diff view ---------------------------------------------------
                Rectangle {
                    id: diffPane
                    visible: root.view === "diff"
                    anchors {
                        top: header.bottom
                        topMargin: 10
                        bottom: footer.top
                        bottomMargin: 10
                        left: parent.left
                        right: parent.right
                        leftMargin: 16
                        rightMargin: 16
                    }
                    radius: 8
                    color: root.panelColor
                    border.color: root.lineColor
                    clip: true

                    ListView {
                        id: diffList
                        anchors.fill: parent
                        anchors.margins: 1
                        clip: true
                        boundsBehavior: Flickable.StopAtBounds
                        model: root.diffRows
                        // Wheel steps of a few lines, not Qt's default jump.
                        flickDeceleration: 4000

                        delegate: Item {
                            id: line
                            required property var modelData
                            required property int index

                            readonly property string type: line.modelData.type
                            readonly property int half: Math.floor(line.width / 2)
                            // Wide enough for a five-digit line number.
                            readonly property int gutter: 52

                            width: diffList.width
                            height: line.type === "file" ? 28 : (line.type === "hunk" ? 22 : 20)

                            // A file.
                            Rectangle {
                                visible: line.type === "file"
                                anchors.fill: parent
                                color: root.selectColor

                                Text {
                                    id: filePath
                                    anchors {
                                        left: parent.left
                                        leftMargin: 12
                                        right: fileStats.left
                                        rightMargin: 12
                                        verticalCenter: parent.verticalCenter
                                    }
                                    elide: Text.ElideMiddle
                                    text: line.type === "file"
                                        ? (line.modelData.status === "renamed" ? line.modelData.oldPath + " → " + line.modelData.path : line.modelData.path)
                                        : ""
                                    color: root.fgColor
                                    font.family: root.monoFont
                                    font.pixelSize: 12
                                    font.bold: true
                                }
                                Text {
                                    id: fileStats
                                    anchors {
                                        right: parent.right
                                        rightMargin: 12
                                        verticalCenter: parent.verticalCenter
                                    }
                                    textFormat: Text.StyledText
                                    text: {
                                        if (line.type !== "file")
                                            return "";
                                        const m = line.modelData;
                                        const counts = m.status === "binary" ? "" : "  <font color=\"" + root.goodColor + "\">+" + m.adds + "</font> <font color=\"" + root.badColor + "\">−" + m.dels + "</font>";
                                        return m.status + counts;
                                    }
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 11
                                }
                            }

                            // A hunk.
                            Rectangle {
                                visible: line.type === "hunk"
                                anchors.fill: parent
                                color: Qt.rgba(1, 1, 1, 0.03)

                                Text {
                                    anchors {
                                        left: parent.left
                                        leftMargin: 12
                                        right: parent.right
                                        verticalCenter: parent.verticalCenter
                                    }
                                    elide: Text.ElideRight
                                    text: line.type === "hunk" ? line.modelData.text : ""
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 12
                                }
                            }

                            // A line, unified: two numbers, a sign, the code.
                            Rectangle {
                                visible: line.type === "line"
                                anchors.fill: parent
                                color: line.type !== "line" ? "transparent" : (line.modelData.kind === "add" ? root.addColor : (line.modelData.kind === "del" ? root.delColor : "transparent"))
                                clip: true

                                Text {
                                    x: 0
                                    width: line.gutter - 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    text: line.type === "line" ? (line.modelData.oldNo ?? "") : ""
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 12
                                }
                                Text {
                                    x: line.gutter
                                    width: line.gutter - 8
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    text: line.type === "line" ? (line.modelData.newNo ?? "") : ""
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 12
                                }
                                Text {
                                    x: line.gutter * 2
                                    width: 18
                                    anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignHCenter
                                    text: line.type !== "line" ? "" : (line.modelData.kind === "add" ? "+" : (line.modelData.kind === "del" ? "-" : ""))
                                    color: line.type === "line" && line.modelData.kind === "add" ? root.goodColor : root.badColor
                                    font.family: root.monoFont
                                    font.pixelSize: 12
                                }
                                Text {
                                    x: line.gutter * 2 + 18
                                    width: parent.width - x
                                    anchors.verticalCenter: parent.verticalCenter
                                    textFormat: Text.StyledText
                                    wrapMode: Text.NoWrap
                                    clip: true
                                    text: line.type === "line" ? line.modelData.html : ""
                                    color: root.fgColor
                                    font.family: root.monoFont
                                    font.pixelSize: 12
                                }
                            }

                            // A pair, split: each half has its own number.
                            Row {
                                visible: line.type === "pair"
                                anchors.fill: parent

                                Repeater {
                                    model: line.type === "pair" ? [line.modelData.left, line.modelData.right] : []

                                    delegate: Rectangle {
                                        id: side
                                        required property var modelData
                                        required property int index

                                        width: side.index === 0 ? line.half : line.width - line.half
                                        height: line.height
                                        clip: true
                                        color: side.modelData === null ? Qt.rgba(0, 0, 0, 0.2)
                                            : (side.modelData.kind === "add" ? root.addColor : (side.modelData.kind === "del" ? root.delColor : "transparent"))

                                        // The line between the halves.
                                        Rectangle {
                                            visible: side.index === 1
                                            width: 1
                                            height: parent.height
                                            color: root.lineColor
                                        }
                                        Text {
                                            x: 0
                                            width: line.gutter - 8
                                            anchors.verticalCenter: parent.verticalCenter
                                            horizontalAlignment: Text.AlignRight
                                            text: side.modelData ? (side.modelData.no ?? "") : ""
                                            color: root.dimColor
                                            font.family: root.monoFont
                                            font.pixelSize: 12
                                        }
                                        Text {
                                            x: line.gutter
                                            width: parent.width - x
                                            anchors.verticalCenter: parent.verticalCenter
                                            textFormat: Text.StyledText
                                            wrapMode: Text.NoWrap
                                            clip: true
                                            text: side.modelData ? side.modelData.html : ""
                                            color: root.fgColor
                                            font.family: root.monoFont
                                            font.pixelSize: 12
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        anchors.centerIn: parent
                        visible: !root.diff || root.diff.phase !== "ready" || root.diffRows.length === 0
                        text: !root.diff || root.diff.phase === "loading" ? "Reading the diff…" : (root.diff.phase === "error" ? root.diff.error : "The diff is empty")
                        color: root.diff && root.diff.phase === "error" ? root.badColor : root.dimColor
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.Wrap
                        width: parent.width - 40
                        font.family: root.monoFont
                        font.pixelSize: 12
                    }
                }
            }
        }
    }
}
