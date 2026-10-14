pragma ComponentBehavior: Bound

// Text snippets for the niri session: templates searched from an overlay and
// pasted into the window that had focus, their {{placeholders}} filled in on
// the way from the selected text, the clipboard, or a small form.
//
// Templates are the *.md and *.txt files under ~/.local/share/snippets, a git
// repo of their own; snip.mjs describes their format. They are read again on
// every open, so an edit shows up the next time. How often each is used and
// the values last typed into its fields are kept in state.json under
// Quickshell.stateDir.
//
// The overlay opens over IPC, from Super+Space s in chauvenity's leader menu:
//
//     qs -c snippets ipc call snippets toggle         Super+Space s s
//     qs -c snippets ipc call snippets capture        Super+Space s c, a new
//                                                     snippet from the selection
//     qs -c snippets ipc call snippets paste <name>   one snippet, the form
//                                                     only if a field is empty
//
// It runs as snippets.service, which niri.service pulls in through
// ~/.config/systemd/user/niri.service.d/50-snippets.conf like
// clipboard-history.service, and watches the primary selection all session: a
// selection made in the last 30 s fills `from=selection` fields on its own, an
// older one waits for Alt+S.
//
// Everything outside QML goes through actions.sh. A paste puts the clipboard
// back afterwards, and copies the snippet as sensitive, so cliphist does not
// keep it.
//
// A new snippet starts in a form: name, keyword (checked against the others),
// folder, tags and apps, pre-filled from the selection and the focused app,
// and the values in the selection that look like fields (tickets, links,
// #numbers…), each made a {{field}} with Space. Ctrl+Enter saves it as it is;
// Enter opens it as a draft under $XDG_RUNTIME_DIR in nvim inside Ghostty
// (snippets.service sets both): saved when nvim closes, it is filed under its
// keyword; quit with :q!, it is gone. A snippet edited with Ctrl+E is renamed
// when its keyword changes, if it was named after it.
//
// Search: type to filter · ↑↓ or Ctrl+J/K select · Enter use · Shift+Enter use
// with the pre-filled values, skipping the form · Ctrl+Enter copy · Alt+1…9
// use that row · Alt+S trust an old selection · Ctrl+E edit · Ctrl+N new
// snippet from the selection · Esc clear the filter, then close.
// New snippet: Tab or ↑↓ change field · → take the greyed completion · Space
// make a spotted value a field, typing names it · Enter write the body in nvim
// · Ctrl+Enter save as it is · Esc back, or cancel.
// Form: Tab or ↑↓ change field · ←→ pick a choice · Alt+S selection into the
// field · Enter next empty field, else paste (Shift+Enter in a multi-line
// field) · Ctrl+Enter copy · Esc back to the search.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "snip.mjs" as Snip

ShellRoot {
    id: root

    // chauvenity's bar palette, so the overlay looks like part of it.
    readonly property color bgColor: "#1c1b22"
    readonly property color fgColor: "#deddda"
    readonly property color dimColor: "#77767b"
    readonly property color accentColor: "#62a0ea"
    readonly property color goodColor: "#8ff0a4"
    readonly property color badColor: "#f66151"
    readonly property color panelColor: "#24232b"
    readonly property color lineColor: "#36353e"
    readonly property color hoverColor: "#2a2932"
    readonly property color selectColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.16)
    readonly property var colors: ({ accent: String(root.accentColor), good: String(root.goodColor), dim: String(root.dimColor) })
    readonly property string monoFont: "JetBrains Mono"
    // JetBrains Mono's ligatures draw `<-` as an arrow: templates have to be
    // shown as the characters they hold.
    readonly property var noLigatures: ({ liga: 0, calt: 0 })

    readonly property string snippetsDir: (Quickshell.env("XDG_DATA_HOME") || Quickshell.env("HOME") + "/.local/share") + "/snippets"
    readonly property string actions: Quickshell.shellPath("actions.sh")

    property bool open: false
    property var targetScreen: null
    // What the probe read when the overlay was summoned; see Snip.makeContext.
    property var ctx: Snip.makeContext({}, 0, Date.now())
    // When the primary selection last changed, by the watcher below.
    property double selectionChangedAt: 0

    property var snippets: []
    property string problem: ""
    property string query: ""
    readonly property var shown: Snip.rank(root.snippets, root.query, root.ctx.app, memory.usage, root.ctx.now)
    readonly property var current: root.shown[list.currentIndex] ?? null
    readonly property var preview: root.current ? Snip.prepare(root.current, root.ctx, memory.values[root.current.id]) : null
    readonly property var previewSegments: root.preview ? Snip.renderSegments(root.current, root.preview.values, root.preview.sources, root.ctx) : []

    // "search"; "form" while the fields of `formSnippet` are filled in; "new"
    // while a new snippet's front matter is.
    property string stage: "search"
    property var formSnippet: null
    property var fields: []
    property var values: ({})
    property var sources: ({})
    property int focusField: 0
    readonly property var formSegments: root.formSnippet ? Snip.renderSegments(root.formSnippet, root.values, root.sources, root.ctx) : []

    // The new snippet: its front matter as typed, the selection it holds, and
    // the values spotted in it with, by key, whether each is made a field and
    // under which name.
    readonly property var newFields: [
        { key: "name", label: "name" },
        { key: "keyword", label: "keyword" },
        { key: "folder", label: "folder" },
        { key: "tags", label: "tags" },
        { key: "apps", label: "apps" },
    ]
    property var draft: ({ name: "", keyword: "", folder: "", tags: "", apps: "" })
    // Until the keyword is typed in, it follows the name.
    property bool keywordTyped: false
    property string newBody: ""
    property var spots: []
    property var spotState: ({})
    // Opened by Super+Space s c, so Esc closes rather than going to the search.
    property bool newFromCapture: false
    readonly property string newKeywordProblem: root.stage === "new" ? Snip.keywordProblem(root.draft.keyword, root.snippets) : ""

    // An open in progress: what it is for ("browse", "paste" or "capture"),
    // and which of its two reads are back.
    property string mode: ""
    property string modeArg: ""
    property bool gotProbe: false
    property bool gotList: false

    onQueryChanged: list.currentIndex = 0

    // --- what is kept between uses ------------------------------------------------

    FileView {
        id: memoryFile
        path: Quickshell.stateDir + "/state.json"
        watchChanges: true
        onFileChanged: memoryFile.reload()
        onAdapterUpdated: memoryFile.writeAdapter()
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound)
                memoryFile.writeAdapter();
        }

        JsonAdapter {
            id: memory
            // Snippet path → {count, last}.
            property var usage: ({})
            // Snippet path → {field: value} as last typed.
            property var values: ({})
        }
    }

    // --- the selection --------------------------------------------------------------
    // One line per change of the primary selection. wl-paste runs the command
    // once as it starts, for whatever was selected before: that change is not
    // new, so the first second is ignored. Restarted when it dies, like the
    // clipboard history's recorders.

    Process {
        id: selectionWatch
        property double startedAt: 0
        running: true
        command: ["wl-paste", "--primary", "--watch", "sh", "-c", "cat > /dev/null; echo"]
        onStarted: selectionWatch.startedAt = Date.now()
        stdout: SplitParser {
            onRead: _ => {
                const now = Date.now();
                if (now - selectionWatch.startedAt > 1000)
                    root.selectionChangedAt = now;
            }
        }
        onRunningChanged: {
            if (!selectionWatch.running)
                restartWatch.restart();
        }
    }

    Timer {
        id: restartWatch
        interval: 1000
        onTriggered: selectionWatch.running = true
    }

    // --- opening ----------------------------------------------------------------

    IpcHandler {
        target: "snippets"

        function toggle(): void {
            if (root.open)
                root.close();
            else
                root.summon("browse", "");
        }
        // Not `show`: `qs ipc call <target> show` lists the target instead.
        function open(): void {
            if (!root.open)
                root.summon("browse", "");
        }
        function close(): void {
            root.close();
        }
        function capture(): void {
            root.close();
            root.summon("capture", "");
        }
        function paste(name: string): void {
            root.close();
            root.summon("paste", name);
        }
        // From actions.sh, once the editor it opened is closed.
        function edited(path: string, before: string): void {
            root.settle(path, before);
        }
        function drafted(path: string, dir: string): void {
            root.fileDraft(path, dir);
        }
    }

    // Lets an overlay opened over this one take the keyboard (OverlayFocus.qml).
    OverlayFocus {
        id: overlayFocus
        name: "snippets"
        open: root.open
    }

    // Lets pick-to-bb (Super+Space b a) describe the overlay's elements.
    PickInspector {
        roots: [overlay]
    }

    function summon(mode, arg) {
        if (probe.running)
            return;
        root.mode = mode;
        root.modeArg = arg;
        root.gotProbe = false;
        root.gotList = false;
        probe.running = true;
        loader.running = true;
    }

    Process {
        id: probe
        command: ["sh", root.actions, "probe", String(Snip.SELECTION_LIMIT)]
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: root.probed(Snip.parseProbe(probeOut.text))
        }
    }

    Process {
        id: loader
        command: ["sh", root.actions, "list", root.snippetsDir]
        stdout: StdioCollector {
            id: loaderOut
            onStreamFinished: {
                root.snippets = Snip.parseListing(loaderOut.text);
                root.gotList = true;
                root.proceed();
            }
        }
        stderr: StdioCollector {
            id: loaderErr
        }
        onExited: code => {
            root.problem = code === 0 ? "" : (loaderErr.text.trim() || `listing snippets failed (exit ${code})`);
        }
    }

    // Opens on the output niri has focused rather than wherever Qt puts it.
    function probed(found) {
        root.targetScreen = Quickshell.screens.find(s => s.name === found.output) ?? Quickshell.screens[0];
        root.ctx = Snip.makeContext(found, root.selectionChangedAt, Date.now());
        root.gotProbe = true;
        root.proceed();
    }

    function proceed() {
        if (!root.gotProbe || !root.gotList || root.mode === "")
            return;
        const mode = root.mode;
        root.mode = "";
        if (mode === "capture") {
            root.startNew(true);
        } else if (mode === "paste") {
            const snippet = Snip.findSnippet(root.snippets, root.modeArg);
            if (snippet) {
                root.choose(snippet, "direct");
            } else {
                root.present();
                search.text = root.modeArg;
            }
        } else {
            root.present();
        }
    }

    function present() {
        root.stage = "search";
        root.formSnippet = null;
        search.text = "";
        list.currentIndex = 0;
        root.open = true;
    }

    function close() {
        root.open = false;
        root.stage = "search";
        root.formSnippet = null;
    }

    // --- using a snippet -------------------------------------------------------------

    // `how`: "paste" or "copy" once its fields are filled in, or "direct" to
    // paste at once when none is empty.
    function choose(snippet, how) {
        if (!snippet)
            return;
        const prep = Snip.prepare(snippet, root.ctx, memory.values[snippet.id]);
        const complete = prep.fields.every(f => f.value !== "");
        if (prep.fields.length === 0 || (how === "direct" && complete)) {
            root.finish(snippet, prep.values, prep.fields, how === "copy" ? "copy" : "paste");
            return;
        }
        if (!root.open)
            root.present();
        // Values first: the fields' editors start from them as they are made.
        root.formSnippet = snippet;
        root.values = prep.values;
        root.sources = prep.sources;
        root.fields = prep.fields;
        root.stage = "form";
        formFlick.contentY = 0;
        const empty = prep.fields.findIndex(f => f.value === "");
        root.focusField = Math.max(0, empty);
        Qt.callLater(() => root.focusOn(root.focusField));
    }

    function finish(snippet, values, fields, intent) {
        const out = Snip.plainText(Snip.renderSegments(snippet, values, {}, root.ctx));
        memory.usage = Snip.recordUse(memory.usage, snippet.id, Date.now());
        if (!snippet.sensitive)
            memory.values = Snip.rememberValues(memory.values, snippet.id, fields, values);
        root.close();
        if (out.text === "")
            return;
        const action = intent === "copy" ? "copy" : snippet.action;
        if (action === "open") {
            Quickshell.execDetached(["xdg-open", out.text.trim()]);
        } else if (action === "copy") {
            Quickshell.execDetached(["sh", root.actions, "copy", out.text, snippet.sensitive ? "sensitive" : ""]);
        } else {
            const terminal = Snip.isTerminal(root.ctx.app);
            const lefts = String(Snip.cursorLefts(out.text, out.cursor, terminal));
            Quickshell.execDetached(snippet.typed
                ? ["sh", root.actions, "type", out.text, lefts]
                : ["sh", root.actions, "paste", out.text, terminal ? "terminal" : "", lefts]);
        }
    }

    function edit(snippet) {
        if (!snippet)
            return;
        root.close();
        Quickshell.execDetached(["sh", root.actions, "edit", root.snippetsDir + "/" + snippet.id]);
    }

    // A draft saved in the editor, filed in `dir` under its keyword.
    function fileDraft(path, dir) {
        root.run(["cat", "--", path], text => {
            Quickshell.execDetached(["sh", root.actions, "move", path, dir, Snip.draftStem(path, text, Date.now())]);
        });
    }

    function trustSelection() {
        root.ctx = Snip.trustSelection(root.ctx);
    }

    // Once a snippet's editor is closed: a file named after its keyword
    // follows a new keyword, its usage and remembered values with it.
    function settle(path, before) {
        root.run(["sh", root.actions, "pair", before, path], out => {
            const pair = Snip.parseEditPair(out);
            const stem = Snip.afterEdit(path, pair.before, pair.after);
            if (stem === "")
                return;
            root.run(["sh", root.actions, "move", path, path.slice(0, path.lastIndexOf("/")), stem], moved => {
                const prefix = root.snippetsDir + "/";
                const to = moved.trim();
                if (!path.startsWith(prefix) || !to.startsWith(prefix))
                    return;
                const from = path.slice(prefix.length);
                memory.usage = Snip.renameEntry(memory.usage, from, to.slice(prefix.length));
                memory.values = Snip.renameEntry(memory.values, from, to.slice(prefix.length));
            });
        });
    }

    // --- background jobs ----------------------------------------------------------

    Component {
        id: jobComponent

        Process {
            id: job
            property var callback: null
            stdout: StdioCollector {
                id: jobOut
                onStreamFinished: {
                    if (job.callback)
                        job.callback(jobOut.text);
                    job.destroy();
                }
            }
        }
    }

    // Runs `command` and hands its stdout to `callback`, as the clipboard
    // overlay does. Not for anything that starts wl-copy or an editor: those
    // keep stdout open.
    function run(command, callback) {
        const job = jobComponent.createObject(root, { callback: callback ?? null });
        job.command = command;
        job.running = true;
    }

    // --- the form --------------------------------------------------------------------

    function setValue(name, value, source) {
        const values = Object.assign({}, root.values);
        values[name] = value;
        const sources = Object.assign({}, root.sources);
        sources[name] = source;
        root.values = values;
        root.sources = sources;
    }

    // From a field's own editing; a value set from outside comes back here too.
    function edited(name, text) {
        if (root.values[name] !== text)
            root.setValue(name, text, "typed");
    }

    function focusOn(index) {
        const count = root.fields.length;
        if (count === 0)
            return;
        fieldRepeater.itemAt((index + count) % count)?.focusIn();
    }

    // Scrolls `flick` so `item`, somewhere in its `column`, shows.
    function reveal(item, flick, column) {
        const y = item.mapToItem(column, 0, 0).y;
        if (y < flick.contentY)
            flick.contentY = y;
        else if (y + item.height > flick.contentY + flick.height)
            flick.contentY = y + item.height - flick.height;
    }

    // Enter: on to the next field still empty, or done.
    function advance(index) {
        const count = root.fields.length;
        for (let step = 1; step < count; step++) {
            const next = (index + step) % count;
            if ((root.values[root.fields[next].name] ?? "") === "") {
                root.focusOn(next);
                return;
            }
        }
        root.finish(root.formSnippet, root.values, root.fields, "paste");
    }

    function cycleChoice(field, step) {
        const options = field.modelData.options;
        const at = options.indexOf(field.value);
        root.setValue(field.modelData.name, options[(at + step + options.length) % options.length], "typed");
    }

    function selectionInto(field) {
        root.trustSelection();
        if (field.isChoice)
            return;
        const value = Snip.extract(root.ctx.selection, field.modelData.match);
        if (value === null)
            return;
        root.setValue(field.modelData.name, value, "selection");
        field.setText(value);
    }

    function backToSearch() {
        root.stage = "search";
        root.formSnippet = null;
        search.forceActiveFocus();
    }

    function sourceLabel(name, match) {
        const source = root.sources[name] ?? "";
        if ((source === "selection" || source === "clipboard") && match !== "")
            return source + " · " + match;
        return source;
    }

    // --- a new snippet --------------------------------------------------------------

    // The form for a new snippet, from a fresh selection and the focused app.
    function startNew(fromCapture) {
        const text = root.ctx.fresh ? Snip.trimSelection(root.ctx.selection) : "";
        const name = text.split("\n")[0].trim().slice(0, 60);
        root.newFromCapture = fromCapture;
        root.newBody = text;
        root.spotState = {};
        root.spots = Snip.spotFields(text, Date.now());
        root.keywordTyped = false;
        root.draft = { name: name, keyword: Snip.keywordFor(name), folder: "", tags: "", apps: Snip.appLabel(root.ctx.app) };
        for (let i = 0; i < root.newFields.length; i++)
            newFieldRepeater.itemAt(i)?.setText(root.draft[root.newFields[i].key]);
        if (!root.open)
            root.present();
        root.stage = "new";
        newFlick.contentY = 0;
        Qt.callLater(() => root.focusNew(0));
    }

    function setDraft(key, value) {
        const next = Object.assign({}, root.draft);
        next[key] = value;
        root.draft = next;
    }

    // From the form's own editing.
    function draftEdited(key, text) {
        if (root.draft[key] === text)
            return;
        root.setDraft(key, text);
        if (key === "keyword") {
            root.keywordTyped = true;
        } else if (key === "name" && !root.keywordTyped) {
            root.setDraft("keyword", Snip.keywordFor(text));
            newFieldRepeater.itemAt(1)?.setText(root.draft.keyword);
        }
    }

    function setSpot(spot, on, name) {
        const next = Object.assign({}, root.spotState);
        next[spot.key] = { on: on, name: name };
        root.spotState = next;
    }

    function toggleSpot(spot) {
        const was = root.spotState[spot.key] ?? { on: false, name: "" };
        root.setSpot(spot, !was.on, was.name);
    }

    // The front matter fields, then the spotted ones.
    function focusNew(index) {
        const count = root.newFields.length + root.spots.length;
        const at = (index + count) % count;
        const item = at < root.newFields.length ? newFieldRepeater.itemAt(at) : spotRepeater.itemAt(at - root.newFields.length);
        item?.focusIn();
    }

    // The line under a field: where the file goes, or what is wrong.
    function newHint(key) {
        const folder = Snip.cleanFolder(root.draft.folder);
        if (key === "keyword")
            return root.newKeywordProblem !== "" ? root.newKeywordProblem
                : "typed to find it · " + (folder !== "" ? folder + "/" : "") + Snip.slugOf(root.draft.keyword) + ".md";
        if (key === "folder" && folder !== "" && Snip.knownFolders(root.snippets).indexOf(folder) === -1)
            return "a new folder";
        return "";
    }

    // Greyed in a field left empty.
    readonly property var newPlaceholders: ({
        name: "shown in the list",
        keyword: "",
        folder: "empty for the top folder",
        tags: "separated by commas",
        apps: "ranked first while one of them has focus",
    })

    // Enter: a draft of it opened in nvim, filed once saved. Ctrl+Enter: saved
    // as it is, unless there is no body yet to save.
    function createNew(now) {
        if (root.newKeywordProblem !== "") {
            root.focusNew(1);
            return;
        }
        const folder = Snip.cleanFolder(root.draft.folder);
        const dir = root.snippetsDir + (folder !== "" ? "/" + folder : "");
        const body = Snip.applySpots(root.newBody, root.spots, root.spotState);
        const text = Snip.newSnippetFile(root.draft, body);
        root.close();
        Quickshell.execDetached(["sh", root.actions, now && body.trim() !== "" ? "save" : "draft", dir, Snip.slugOf(root.draft.keyword), text]);
    }

    function leaveNew() {
        if (root.newFromCapture)
            root.close();
        else
            root.backToSearch();
    }

    // --- keys ----------------------------------------------------------------------

    function move(step) {
        const count = root.shown.length;
        if (count === 0)
            return;
        let next = list.currentIndex + step;
        if (Math.abs(step) === 1)
            next = (next + count) % count;
        list.currentIndex = Math.max(0, Math.min(count - 1, next));
    }

    function handleSearchKey(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const alt = (event.modifiers & Qt.AltModifier) !== 0;
        const key = event.key;
        // The digit row by position, so Alt+1…9 also works on AZERTY.
        const digit = event.nativeScanCode - 9;

        if (key === Qt.Key_Escape) {
            if (search.text !== "")
                search.text = "";
            else
                root.close();
        } else if (key === Qt.Key_Down || (ctrl && key === Qt.Key_J)) {
            root.move(1);
        } else if (key === Qt.Key_Up || (ctrl && (key === Qt.Key_K || key === Qt.Key_P))) {
            root.move(-1);
        } else if (key === Qt.Key_PageDown) {
            root.move(list.pageSize);
        } else if (key === Qt.Key_PageUp) {
            root.move(-list.pageSize);
        } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            root.choose(root.current, ctrl ? "copy" : (shift ? "direct" : "paste"));
        } else if (alt && digit >= 1 && digit <= 9) {
            root.choose(root.shown[digit - 1] ?? null, shift ? "direct" : "paste");
        } else if (alt && key === Qt.Key_S) {
            root.trustSelection();
        } else if (ctrl && key === Qt.Key_E) {
            root.edit(root.current);
        } else if (ctrl && key === Qt.Key_N) {
            root.startNew(false);
        } else {
            event.accepted = false;
            return;
        }
        event.accepted = true;
    }

    function handleNewKey(event, index) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const key = event.key;

        if (key === Qt.Key_Escape) {
            root.leaveNew();
        } else if (key === Qt.Key_Tab || key === Qt.Key_Down) {
            root.focusNew(index + 1);
        } else if (key === Qt.Key_Backtab || key === Qt.Key_Up) {
            root.focusNew(index - 1);
        } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            root.createNew(ctrl);
        } else if (key === Qt.Key_Space && index >= root.newFields.length) {
            root.toggleSpot(root.spots[index - root.newFields.length]);
        } else {
            event.accepted = false;
            return;
        }
        event.accepted = true;
    }

    function handleFormKey(event, field) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const alt = (event.modifiers & Qt.AltModifier) !== 0;
        const key = event.key;

        if (key === Qt.Key_Escape) {
            root.backToSearch();
        } else if (key === Qt.Key_Tab) {
            root.focusOn(field.index + 1);
        } else if (key === Qt.Key_Backtab) {
            root.focusOn(field.index - 1);
        } else if (key === Qt.Key_Down && !field.isMulti) {
            root.focusOn(field.index + 1);
        } else if (key === Qt.Key_Up && !field.isMulti) {
            root.focusOn(field.index - 1);
        } else if ((key === Qt.Key_Left || key === Qt.Key_Right) && field.isChoice) {
            root.cycleChoice(field, key === Qt.Key_Right ? 1 : -1);
        } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            if (ctrl) {
                root.finish(root.formSnippet, root.values, root.fields, "copy");
            } else if (field.isMulti && !shift) {
                event.accepted = false;
                return;
            } else {
                root.advance(field.index);
            }
        } else if (alt && key === Qt.Key_S) {
            root.selectionInto(field);
        } else {
            event.accepted = false;
            return;
        }
        event.accepted = true;
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
        WlrLayershell.namespace: "snippets"
        WlrLayershell.keyboardFocus: overlayFocus.keyboardFocus
        color: "transparent"
        // niri blurs the windows behind the card: niri/config.kdl turns
        // xray off for the overlay layer.
        BackgroundEffect.blurRegion: Region {
            item: card
            radius: card.radius
        }

        onVisibleChanged: {
            if (overlay.visible) {
                if (root.stage === "search")
                    search.forceActiveFocus();
                openAnimation.restart();
            }
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
            width: Math.round(Math.min(980, overlay.width - 80))
            height: Math.round(Math.min(620, overlay.height - 80))
            x: Math.round((overlay.width - frame.width) / 2)
            y: Math.round((overlay.height - frame.height) / 2)

            // Translucent over niri's blur (BackgroundEffect on the overlay),
            // and without a drop shadow: a shadow is dark under the card too,
            // and would hide the blur.
            Rectangle {
                id: card
                anchors.fill: parent
                radius: 14
                color: Qt.alpha(root.bgColor, 0.75)
                border.color: root.lineColor
                clip: true

                // Swallows clicks, so only the backdrop closes.
                MouseArea {
                    anchors.fill: parent
                }

                // Search field.
                Item {
                    id: header
                    anchors {
                        top: parent.top
                        left: parent.left
                        right: parent.right
                    }
                    height: 56

                    // A magnifier drawn from two rectangles, so it needs no
                    // icon font.
                    Item {
                        id: magnifier
                        x: 22
                        anchors.verticalCenter: parent.verticalCenter
                        width: 16
                        height: 16

                        Rectangle {
                            width: 11
                            height: 11
                            radius: 5.5
                            color: "transparent"
                            border.width: 2
                            border.color: search.text !== "" ? root.accentColor : root.dimColor
                        }
                        Rectangle {
                            x: 9
                            y: 11
                            width: 7
                            height: 2
                            radius: 1
                            rotation: 45
                            color: search.text !== "" ? root.accentColor : root.dimColor
                        }
                    }

                    TextInput {
                        id: search
                        anchors {
                            left: magnifier.right
                            leftMargin: 14
                            right: chips.left
                            rightMargin: 12
                            verticalCenter: parent.verticalCenter
                        }
                        focus: true
                        color: root.fgColor
                        selectionColor: root.accentColor
                        selectedTextColor: root.bgColor
                        font.pixelSize: 16
                        clip: true
                        onTextChanged: root.query = search.text
                        Keys.onPressed: event => root.handleSearchKey(event)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: search.text === ""
                            text: "Search snippets"
                            color: root.dimColor
                            font.pixelSize: 16
                        }
                    }

                    // The window a paste goes to, and the selection.
                    Row {
                        id: chips
                        anchors {
                            right: parent.right
                            rightMargin: 18
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 6

                        Repeater {
                            model: [
                                { text: root.ctx.app.split(".").pop(), color: root.fgColor, line: root.lineColor },
                                {
                                    text: Snip.selectionLabel(root.ctx) === "" ? "" : Snip.selectionLabel(root.ctx) + (root.ctx.fresh ? "" : " · Alt S"),
                                    color: root.ctx.fresh ? root.goodColor : root.dimColor,
                                    line: root.ctx.fresh ? Qt.rgba(root.goodColor.r, root.goodColor.g, root.goodColor.b, 0.35) : root.lineColor,
                                },
                            ]

                            Rectangle {
                                id: chip
                                required property var modelData
                                anchors.verticalCenter: parent.verticalCenter
                                visible: chip.modelData.text !== ""
                                width: chipText.implicitWidth + 16
                                height: 22
                                radius: 11
                                color: "transparent"
                                border.color: chip.modelData.line

                                Text {
                                    id: chipText
                                    anchors.centerIn: parent
                                    text: chip.modelData.text
                                    textFormat: Text.PlainText
                                    color: chip.modelData.color
                                    font.family: root.monoFont
                                    font.features: root.noLigatures
                                    font.pixelSize: 11
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    id: headerRule
                    anchors {
                        top: header.bottom
                        left: parent.left
                        right: parent.right
                    }
                    height: 1
                    color: root.lineColor
                }

                // --- the list ---

                ListView {
                    id: list

                    readonly property int pageSize: Math.max(1, Math.floor(list.height / 48))

                    anchors {
                        top: headerRule.bottom
                        bottom: footerRule.top
                        left: parent.left
                        margins: 8
                    }
                    width: Math.round(parent.width * 0.38)
                    clip: true
                    model: root.shown
                    opacity: root.stage === "search" ? 1 : 0.55
                    boundsBehavior: Flickable.StopAtBounds
                    highlightMoveDuration: 90
                    highlightResizeDuration: 90
                    highlight: Rectangle {
                        radius: 8
                        color: root.selectColor

                        Rectangle {
                            x: 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: 3
                            height: parent.height - 16
                            radius: 1.5
                            color: root.accentColor
                        }
                    }

                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool isCurrent: row.ListView.isCurrentItem
                        readonly property string subtitle: [row.modelData.group].concat(row.modelData.tags.map(t => "#" + t))
                            .filter(s => s !== "").join("  ")

                        width: list.width
                        height: 48

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            // Moving the mouse selects; a list scrolling under a
                            // still mouse does not.
                            onPositionChanged: list.currentIndex = row.index
                            onClicked: root.choose(row.modelData, "paste")
                        }

                        Rectangle {
                            id: keyword
                            x: 14
                            anchors.verticalCenter: parent.verticalCenter
                            width: 76
                            height: 24
                            radius: 6
                            color: root.panelColor
                            border.color: row.isCurrent ? root.accentColor : root.lineColor

                            Text {
                                anchors {
                                    fill: parent
                                    leftMargin: 7
                                    rightMargin: 7
                                }
                                verticalAlignment: Text.AlignVCenter
                                // Escaped by highlight(): StyledText would
                                // otherwise render markup in a file name.
                                text: Snip.highlight(row.modelData.keyword, root.query, root.accentColor)
                                textFormat: Text.StyledText
                                elide: Text.ElideRight
                                color: row.isCurrent ? root.fgColor : root.dimColor
                                font.family: root.monoFont
                                font.features: root.noLigatures
                                font.pixelSize: 11
                            }
                        }

                        Column {
                            anchors {
                                left: keyword.right
                                leftMargin: 12
                                right: trailing.left
                                rightMargin: 8
                                verticalCenter: parent.verticalCenter
                            }
                            spacing: 2

                            Text {
                                width: parent.width
                                text: Snip.highlight(row.modelData.name, root.query, root.accentColor)
                                textFormat: Text.StyledText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                color: root.fgColor
                                font.pixelSize: 13
                            }
                            Text {
                                width: parent.width
                                visible: row.subtitle !== ""
                                text: row.subtitle
                                textFormat: Text.PlainText
                                elide: Text.ElideRight
                                color: root.dimColor
                                font.pixelSize: 11
                            }
                        }

                        Row {
                            id: trailing
                            anchors {
                                right: parent.right
                                rightMargin: 10
                                verticalCenter: parent.verticalCenter
                            }
                            spacing: 6

                            // Ranked up for the focused window.
                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                visible: Snip.forApp(row.modelData, root.ctx.app)
                                width: appText.implicitWidth + 12
                                height: 18
                                radius: 4
                                color: root.panelColor

                                Text {
                                    id: appText
                                    anchors.centerIn: parent
                                    text: root.ctx.app.split(".").pop()
                                    color: root.dimColor
                                    font.pixelSize: 10
                                }
                            }

                            // Alt+N hint.
                            Text {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 12
                                horizontalAlignment: Text.AlignRight
                                text: row.index < 9 ? String(row.index + 1) : ""
                                color: root.dimColor
                                font.family: root.monoFont
                                font.pixelSize: 11
                            }
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        visible: root.shown.length === 0
                        spacing: 6

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.problem !== "" ? "Could not read the snippets"
                                : root.snippets.length === 0 ? "No snippets yet"
                                : "Nothing matches"
                            color: root.fgColor
                            font.pixelSize: 14
                        }
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: Math.min(implicitWidth, list.width - 40)
                            horizontalAlignment: Text.AlignHCenter
                            wrapMode: Text.Wrap
                            textFormat: Text.PlainText
                            text: root.problem !== "" ? root.problem
                                : root.snippets.length === 0 ? "Add .md files to ~/.local/share/snippets, or press Ctrl+N to save the selection as one."
                                : "Esc clears the search."
                            color: root.dimColor
                            font.pixelSize: 12
                        }
                    }
                }

                Rectangle {
                    id: divider
                    anchors {
                        top: headerRule.bottom
                        bottom: footerRule.top
                        left: list.right
                        leftMargin: 8
                    }
                    width: 1
                    color: root.lineColor
                }

                // --- the preview ---

                Item {
                    id: previewPane

                    readonly property var snippet: root.current
                    readonly property bool masked: !!previewPane.snippet && previewPane.snippet.sensitive

                    anchors {
                        top: headerRule.bottom
                        bottom: footerRule.top
                        left: divider.right
                        right: parent.right
                        margins: 18
                    }
                    visible: root.stage === "search" && !!previewPane.snippet

                    onSnippetChanged: {
                        sourceFlick.contentY = 0;
                        renderFlick.contentY = 0;
                    }

                    Row {
                        id: titleRow
                        anchors {
                            top: parent.top
                            left: parent.left
                            right: parent.right
                        }
                        spacing: 10

                        Text {
                            width: Math.min(implicitWidth, titleRow.width - keywordChip.width - 10)
                            text: previewPane.snippet ? previewPane.snippet.name : ""
                            textFormat: Text.PlainText
                            elide: Text.ElideRight
                            color: root.fgColor
                            font.pixelSize: 15
                            font.bold: true
                        }
                        Rectangle {
                            id: keywordChip
                            anchors.verticalCenter: parent.verticalCenter
                            width: keywordChipText.implicitWidth + 12
                            height: 20
                            radius: 5
                            color: "transparent"
                            border.color: root.lineColor

                            Text {
                                id: keywordChipText
                                anchors.centerIn: parent
                                text: previewPane.snippet ? previewPane.snippet.keyword : ""
                                textFormat: Text.PlainText
                                color: root.accentColor
                                font.family: root.monoFont
                                font.pixelSize: 11
                            }
                        }
                    }

                    Text {
                        id: meta
                        anchors {
                            top: titleRow.bottom
                            topMargin: 6
                            left: parent.left
                            right: parent.right
                        }
                        text: previewPane.snippet ? Snip.describe(previewPane.snippet, memory.usage[previewPane.snippet.id], root.ctx.now) : ""
                        textFormat: Text.PlainText
                        elide: Text.ElideRight
                        color: root.dimColor
                        font.pixelSize: 11
                    }

                    // What is wrong with the file, if anything.
                    Item {
                        id: problems
                        anchors {
                            top: meta.bottom
                            topMargin: problemsText.visible ? 6 : 0
                            left: parent.left
                            right: parent.right
                        }
                        height: problemsText.visible ? problemsText.implicitHeight : 0

                        Text {
                            id: problemsText
                            width: parent.width
                            visible: problemsText.text !== ""
                            text: previewPane.snippet ? previewPane.snippet.problems.slice(0, 3).join("\n") : ""
                            textFormat: Text.PlainText
                            wrapMode: Text.Wrap
                            color: root.badColor
                            font.pixelSize: 11
                        }
                    }

                    Text {
                        id: templateLabel
                        anchors {
                            top: problems.bottom
                            topMargin: 14
                            left: parent.left
                        }
                        text: "TEMPLATE"
                        color: root.dimColor
                        font.pixelSize: 10
                        font.letterSpacing: 0.8
                    }

                    Rectangle {
                        id: sourceBox
                        anchors {
                            top: templateLabel.bottom
                            topMargin: 6
                            left: parent.left
                            right: parent.right
                        }
                        height: Math.min(sourceText.implicitHeight + 20, Math.round(previewPane.height * 0.42))
                        radius: 8
                        color: root.panelColor
                        border.color: root.lineColor

                        Flickable {
                            id: sourceFlick
                            anchors.fill: parent
                            anchors.margins: 10
                            clip: true
                            contentWidth: width
                            contentHeight: sourceText.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds

                            Text {
                                id: sourceText
                                width: sourceFlick.width
                                // Escaped by styledSource().
                                text: previewPane.masked ? "••••••  sensitive" : (previewPane.snippet ? Snip.styledSource(previewPane.snippet, root.colors) : "")
                                textFormat: Text.StyledText
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                color: root.fgColor
                                font.family: root.monoFont
                                font.features: root.noLigatures
                                font.pixelSize: 12
                                lineHeight: 1.15
                            }
                        }
                    }

                    Text {
                        id: renderLabel
                        anchors {
                            top: sourceBox.bottom
                            topMargin: 14
                            left: parent.left
                        }
                        text: previewPane.snippet && previewPane.snippet.each ? "RENDERS AS · ONCE PER SELECTED LINE" : "RENDERS AS"
                        color: root.dimColor
                        font.pixelSize: 10
                        font.letterSpacing: 0.8
                    }

                    Rectangle {
                        anchors {
                            top: renderLabel.bottom
                            topMargin: 6
                            left: parent.left
                            right: parent.right
                            bottom: parent.bottom
                        }
                        radius: 8
                        color: root.panelColor
                        border.color: root.lineColor

                        Flickable {
                            id: renderFlick
                            anchors.fill: parent
                            anchors.margins: 10
                            clip: true
                            contentWidth: width
                            contentHeight: renderText.implicitHeight
                            boundsBehavior: Flickable.StopAtBounds

                            Text {
                                id: renderText
                                width: renderFlick.width
                                // Escaped by styledSegments().
                                text: previewPane.masked ? "••••••" : Snip.styledSegments(root.previewSegments, root.colors)
                                textFormat: Text.StyledText
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                color: root.fgColor
                                font.family: root.monoFont
                                font.features: root.noLigatures
                                font.pixelSize: 12
                                lineHeight: 1.15
                            }
                        }
                    }
                }

                // --- the form ---

                Flickable {
                    id: formFlick
                    anchors {
                        top: headerRule.bottom
                        bottom: footerRule.top
                        left: divider.right
                        right: parent.right
                        margins: 18
                    }
                    visible: root.stage === "form"
                    clip: true
                    contentWidth: width
                    contentHeight: formColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: formColumn
                        width: formFlick.width
                        spacing: 8

                        Row {
                            spacing: 10

                            Text {
                                id: formTitle
                                text: root.formSnippet ? root.formSnippet.name : ""
                                textFormat: Text.PlainText
                                color: root.fgColor
                                font.pixelSize: 15
                                font.bold: true
                            }
                            Text {
                                anchors.baseline: formTitle.baseline
                                text: root.fields.length === 1 ? "1 field" : root.fields.length + " fields"
                                color: root.dimColor
                                font.pixelSize: 11
                            }
                        }

                        Item {
                            width: 1
                            height: 4
                        }

                        Repeater {
                            id: fieldRepeater
                            model: root.fields

                            Item {
                                id: field
                                required property var modelData
                                required property int index
                                readonly property bool isChoice: field.modelData.options.length > 0
                                readonly property bool isMulti: !field.isChoice && field.modelData.multiline
                                readonly property bool focused: lineInput.activeFocus || multiInput.activeFocus || choiceKeys.activeFocus
                                readonly property string value: root.values[field.modelData.name] ?? ""
                                readonly property string source: root.sources[field.modelData.name] ?? ""

                                function focusIn() {
                                    if (field.isChoice)
                                        choiceKeys.forceActiveFocus();
                                    else if (field.isMulti)
                                        multiInput.forceActiveFocus();
                                    else
                                        lineInput.forceActiveFocus();
                                }

                                function setText(text) {
                                    if (field.isMulti)
                                        multiInput.text = text;
                                    else if (!field.isChoice)
                                        lineInput.text = text;
                                }

                                width: formColumn.width
                                height: box.height

                                onFocusedChanged: {
                                    if (field.focused) {
                                        root.focusField = field.index;
                                        root.reveal(field, formFlick, formColumn);
                                    }
                                }
                                Component.onCompleted: field.setText(field.value)

                                Text {
                                    anchors {
                                        right: box.left
                                        rightMargin: 10
                                    }
                                    y: 8
                                    width: 96
                                    horizontalAlignment: Text.AlignRight
                                    text: field.modelData.name
                                    textFormat: Text.PlainText
                                    elide: Text.ElideLeft
                                    color: field.focused ? root.fgColor : root.dimColor
                                    font.family: root.monoFont
                                    font.features: root.noLigatures
                                    font.pixelSize: 12
                                }

                                Rectangle {
                                    id: box
                                    x: 106
                                    width: parent.width - 106 - badge.width - 10
                                    height: field.isMulti ? Math.min(140, Math.max(32, multiInput.contentHeight + 16)) : 32
                                    radius: 6
                                    color: root.panelColor
                                    border.color: field.focused ? root.accentColor : root.lineColor
                                    clip: true

                                    TextInput {
                                        id: lineInput
                                        anchors {
                                            left: parent.left
                                            right: parent.right
                                            leftMargin: 10
                                            rightMargin: 10
                                            verticalCenter: parent.verticalCenter
                                        }
                                        visible: !field.isChoice && !field.isMulti
                                        enabled: lineInput.visible
                                        color: root.fgColor
                                        selectionColor: root.accentColor
                                        selectedTextColor: root.bgColor
                                        font.family: root.monoFont
                                        font.features: root.noLigatures
                                        font.pixelSize: 13
                                        clip: true
                                        onTextChanged: {
                                            if (lineInput.visible)
                                                root.edited(field.modelData.name, lineInput.text);
                                        }
                                        Keys.onPressed: event => root.handleFormKey(event, field)
                                    }

                                    TextEdit {
                                        id: multiInput
                                        anchors {
                                            fill: parent
                                            margins: 8
                                            leftMargin: 10
                                            rightMargin: 10
                                        }
                                        visible: field.isMulti
                                        enabled: multiInput.visible
                                        wrapMode: TextEdit.Wrap
                                        color: root.fgColor
                                        selectionColor: root.accentColor
                                        selectedTextColor: root.bgColor
                                        font.family: root.monoFont
                                        font.features: root.noLigatures
                                        font.pixelSize: 13
                                        onTextChanged: {
                                            if (multiInput.visible)
                                                root.edited(field.modelData.name, multiInput.text);
                                        }
                                        Keys.onPressed: event => root.handleFormKey(event, field)
                                    }

                                    // A choice: one of its options, with ← →.
                                    Item {
                                        id: choiceKeys
                                        anchors.fill: parent
                                        visible: field.isChoice
                                        enabled: choiceKeys.visible
                                        Keys.onPressed: event => root.handleFormKey(event, field)

                                        MouseArea {
                                            anchors.fill: parent
                                            onClicked: choiceKeys.forceActiveFocus()
                                        }

                                        Row {
                                            x: 5
                                            anchors.verticalCenter: parent.verticalCenter
                                            spacing: 4

                                            Repeater {
                                                model: field.isChoice ? field.modelData.options : []

                                                Rectangle {
                                                    id: option
                                                    required property string modelData
                                                    readonly property bool picked: option.modelData === field.value
                                                    width: optionText.implicitWidth + 14
                                                    height: 22
                                                    radius: 4
                                                    color: option.picked ? root.accentColor : (optionMouse.containsMouse ? root.hoverColor : "transparent")

                                                    Text {
                                                        id: optionText
                                                        anchors.centerIn: parent
                                                        text: option.modelData
                                                        textFormat: Text.PlainText
                                                        color: option.picked ? root.bgColor : root.dimColor
                                                        font.family: root.monoFont
                                                        font.pixelSize: 12
                                                    }

                                                    MouseArea {
                                                        id: optionMouse
                                                        anchors.fill: parent
                                                        hoverEnabled: true
                                                        onClicked: {
                                                            root.setValue(field.modelData.name, option.modelData, "typed");
                                                            choiceKeys.forceActiveFocus();
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }

                                // Where the value came from.
                                Item {
                                    id: badge
                                    readonly property string label: root.sourceLabel(field.modelData.name, field.modelData.match)
                                    readonly property bool fromText: field.source === "selection" || field.source === "clipboard"
                                    anchors.right: parent.right
                                    y: 6
                                    width: 150
                                    height: 20

                                    Rectangle {
                                        visible: badge.label !== "" && badge.label !== "typed"
                                        width: Math.min(badge.width, badgeText.implicitWidth + 14)
                                        height: parent.height
                                        radius: 10
                                        color: "transparent"
                                        border.color: badge.fromText ? Qt.rgba(root.goodColor.r, root.goodColor.g, root.goodColor.b, 0.35) : root.lineColor

                                        Text {
                                            id: badgeText
                                            anchors {
                                                fill: parent
                                                leftMargin: 7
                                                rightMargin: 7
                                            }
                                            verticalAlignment: Text.AlignVCenter
                                            text: badge.label
                                            textFormat: Text.PlainText
                                            elide: Text.ElideRight
                                            color: badge.fromText ? root.goodColor : root.dimColor
                                            font.family: root.monoFont
                                            font.features: root.noLigatures
                                            font.pixelSize: 10
                                        }
                                    }
                                }
                            }
                        }

                        Item {
                            width: 1
                            height: 6
                        }

                        Text {
                            text: root.formSnippet && root.formSnippet.each ? "PREVIEW · ONCE PER SELECTED LINE" : "PREVIEW"
                            color: root.dimColor
                            font.pixelSize: 10
                            font.letterSpacing: 0.8
                        }

                        Rectangle {
                            width: formColumn.width
                            height: formPreview.implicitHeight + 20
                            radius: 8
                            color: root.panelColor
                            border.color: root.lineColor

                            Text {
                                id: formPreview
                                x: 10
                                y: 10
                                width: parent.width - 20
                                // Escaped by styledSegments().
                                text: root.formSnippet && root.formSnippet.sensitive ? "••••••" : Snip.styledSegments(root.formSegments, root.colors)
                                textFormat: Text.StyledText
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                color: root.fgColor
                                font.family: root.monoFont
                                font.features: root.noLigatures
                                font.pixelSize: 12
                                lineHeight: 1.15
                            }
                        }
                    }
                }

                // --- a new snippet ---

                Flickable {
                    id: newFlick
                    anchors {
                        top: headerRule.bottom
                        bottom: footerRule.top
                        left: divider.right
                        right: parent.right
                        margins: 18
                    }
                    visible: root.stage === "new"
                    clip: true
                    contentWidth: width
                    contentHeight: newColumn.implicitHeight
                    boundsBehavior: Flickable.StopAtBounds

                    Column {
                        id: newColumn
                        width: newFlick.width
                        spacing: 8

                        Row {
                            spacing: 10

                            Text {
                                id: newTitle
                                text: "New snippet"
                                color: root.fgColor
                                font.pixelSize: 15
                                font.bold: true
                            }
                            Text {
                                anchors.baseline: newTitle.baseline
                                text: root.newBody !== "" ? "from the selection" : "the selection is old: an empty one"
                                color: root.dimColor
                                font.pixelSize: 11
                            }
                        }

                        Item {
                            width: 1
                            height: 4
                        }

                        // The front matter, each with what the overlay knows
                        // of it: completions greyed after the caret, taken
                        // with →, and a line under it.
                        Repeater {
                            id: newFieldRepeater
                            model: root.newFields

                            Item {
                                id: newField
                                required property var modelData
                                required property int index
                                readonly property string key: newField.modelData.key
                                readonly property bool focused: newInput.activeFocus
                                readonly property bool isList: newField.key === "tags" || newField.key === "apps"
                                readonly property var options: newField.key === "folder" ? Snip.knownFolders(root.snippets)
                                    : newField.key === "tags" ? Snip.knownTags(root.snippets)
                                    : newField.key === "apps" ? Snip.knownApps(root.snippets, root.ctx.app)
                                    : []
                                readonly property string completion: newField.focused && newInput.cursorPosition === newInput.text.length
                                    ? Snip.complete(newInput.text, newField.options, newField.isList) : ""
                                readonly property bool bad: newField.key === "keyword" && root.newKeywordProblem !== ""
                                readonly property string hint: root.stage === "new" ? root.newHint(newField.key) : ""

                                function focusIn() {
                                    newInput.forceActiveFocus();
                                    newInput.cursorPosition = newInput.text.length;
                                }

                                // Shown from its start until the field is entered.
                                function setText(text) {
                                    newInput.text = text;
                                    newInput.cursorPosition = 0;
                                }

                                width: newColumn.width
                                height: newBox.height + (newField.hint !== "" ? newHintText.implicitHeight + 4 : 0)

                                onFocusedChanged: {
                                    if (newField.focused)
                                        root.reveal(newField, newFlick, newColumn);
                                }

                                Text {
                                    anchors {
                                        right: newBox.left
                                        rightMargin: 10
                                    }
                                    y: 8
                                    width: 96
                                    horizontalAlignment: Text.AlignRight
                                    text: newField.modelData.label
                                    color: newField.focused ? root.fgColor : root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 12
                                }

                                Rectangle {
                                    id: newBox
                                    x: 106
                                    width: parent.width - 106
                                    height: 32
                                    radius: 6
                                    color: root.panelColor
                                    border.color: newField.focused ? root.accentColor : (newField.bad ? root.badColor : root.lineColor)
                                    clip: true

                                    TextInput {
                                        id: newInput
                                        anchors {
                                            left: parent.left
                                            right: parent.right
                                            leftMargin: 10
                                            rightMargin: 10
                                            verticalCenter: parent.verticalCenter
                                        }
                                        color: root.fgColor
                                        selectionColor: root.accentColor
                                        selectedTextColor: root.bgColor
                                        font.family: root.monoFont
                                        font.features: root.noLigatures
                                        font.pixelSize: 13
                                        clip: true
                                        onTextChanged: root.draftEdited(newField.key, newInput.text)
                                        // Left, it shows from its start again.
                                        onActiveFocusChanged: {
                                            if (!newInput.activeFocus)
                                                newInput.cursorPosition = 0;
                                        }
                                        Keys.onPressed: event => {
                                            if (event.key === Qt.Key_Right && newField.completion !== "") {
                                                newInput.text += newField.completion;
                                                newInput.cursorPosition = newInput.text.length;
                                                event.accepted = true;
                                                return;
                                            }
                                            root.handleNewKey(event, newField.index);
                                        }

                                        Text {
                                            x: newInput.contentWidth
                                            anchors.verticalCenter: parent.verticalCenter
                                            text: newField.completion
                                            textFormat: Text.PlainText
                                            color: root.dimColor
                                            font: newInput.font
                                        }

                                        Text {
                                            anchors.verticalCenter: parent.verticalCenter
                                            visible: newInput.text === ""
                                            text: root.newPlaceholders[newField.key]
                                            color: root.dimColor
                                            font.pixelSize: 12
                                        }
                                    }
                                }

                                Text {
                                    id: newHintText
                                    anchors {
                                        top: newBox.bottom
                                        topMargin: 4
                                        left: newBox.left
                                        right: newBox.right
                                    }
                                    visible: newField.hint !== ""
                                    text: newField.hint
                                    textFormat: Text.PlainText
                                    elide: Text.ElideRight
                                    color: newField.bad ? root.badColor : root.dimColor
                                    font.pixelSize: 11
                                }
                            }
                        }

                        Item {
                            width: 1
                            height: 6
                            visible: root.spots.length > 0
                        }

                        Text {
                            visible: root.spots.length > 0
                            text: "LOOKS LIKE FIELDS · SPACE MAKES ONE A {{FIELD}}, TYPE TO NAME IT"
                            color: root.dimColor
                            font.pixelSize: 10
                            font.letterSpacing: 0.8
                        }

                        // Values spotted in the selection: each can become a
                        // field, filled from the selection or the clipboard
                        // when the snippet is used.
                        Repeater {
                            id: spotRepeater
                            model: root.spots

                            Item {
                                id: spotRow
                                required property var modelData
                                required property int index
                                readonly property var choice: root.spotState[spotRow.modelData.key] ?? ({ on: false, name: "" })
                                readonly property bool on: !!spotRow.choice.on
                                readonly property bool focused: spotInput.activeFocus

                                function focusIn() {
                                    spotInput.forceActiveFocus();
                                    spotInput.cursorPosition = spotInput.text.length;
                                }

                                width: newColumn.width
                                height: 32

                                onFocusedChanged: {
                                    if (spotRow.focused)
                                        root.reveal(spotRow, newFlick, newColumn);
                                }
                                Component.onCompleted: spotInput.text = spotRow.modelData.name

                                // The box to tick.
                                Rectangle {
                                    id: tick
                                    x: 84
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 16
                                    height: 16
                                    radius: 4
                                    color: spotRow.on ? root.accentColor : "transparent"
                                    border.color: spotRow.on || spotRow.focused ? root.accentColor : root.lineColor

                                    Text {
                                        anchors.centerIn: parent
                                        visible: spotRow.on
                                        text: "✓"
                                        color: root.bgColor
                                        font.pixelSize: 11
                                        font.bold: true
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -6
                                        onClicked: {
                                            root.toggleSpot(spotRow.modelData);
                                            spotRow.focusIn();
                                        }
                                    }
                                }

                                Text {
                                    id: spotText
                                    x: 106
                                    anchors.verticalCenter: parent.verticalCenter
                                    // What is left beside the name box and the source.
                                    width: parent.width - 106 - 34 - spotBox.width - 10 - 80
                                    text: spotRow.modelData.text
                                    textFormat: Text.PlainText
                                    elide: Text.ElideMiddle
                                    color: spotRow.on ? root.fgColor : root.dimColor
                                    font.family: root.monoFont
                                    font.features: root.noLigatures
                                    font.pixelSize: 12
                                }

                                Text {
                                    id: spotArrow
                                    anchors {
                                        left: spotText.right
                                        leftMargin: 10
                                        verticalCenter: parent.verticalCenter
                                    }
                                    text: "→"
                                    color: root.dimColor
                                    font.pixelSize: 12
                                }

                                Rectangle {
                                    id: spotBox
                                    anchors {
                                        left: spotArrow.right
                                        leftMargin: 10
                                        verticalCenter: parent.verticalCenter
                                    }
                                    width: 150
                                    height: 28
                                    radius: 6
                                    color: root.panelColor
                                    border.color: spotRow.focused ? root.accentColor : root.lineColor
                                    clip: true

                                    TextInput {
                                        id: spotInput
                                        anchors {
                                            left: parent.left
                                            right: parent.right
                                            leftMargin: 8
                                            rightMargin: 8
                                            verticalCenter: parent.verticalCenter
                                        }
                                        // Today's date is {{date}}, built in.
                                        readOnly: spotRow.modelData.kind === "today"
                                        validator: RegularExpressionValidator {
                                            regularExpression: /[A-Za-z_][\w-]*/
                                        }
                                        color: spotRow.on ? root.accentColor : root.dimColor
                                        selectionColor: root.accentColor
                                        selectedTextColor: root.bgColor
                                        font.family: root.monoFont
                                        font.features: root.noLigatures
                                        font.pixelSize: 12
                                        onTextChanged: {
                                            if (spotInput.text !== spotRow.modelData.name || spotRow.choice.name !== "")
                                                root.setSpot(spotRow.modelData, spotRow.on, spotInput.text);
                                        }
                                        Keys.onPressed: event => root.handleNewKey(event, root.newFields.length + spotRow.index)
                                    }
                                }

                                Text {
                                    id: spotWhere
                                    anchors {
                                        left: spotBox.right
                                        leftMargin: 10
                                        verticalCenter: parent.verticalCenter
                                    }
                                    width: 80
                                    text: spotRow.modelData.kind === "today" ? "today" : spotRow.modelData.attrs.indexOf("from=clipboard") !== -1 ? "clipboard" : "selection"
                                    color: root.dimColor
                                    font.pixelSize: 11
                                }
                            }
                        }

                        Item {
                            width: 1
                            height: 6
                        }

                        Text {
                            text: "BODY"
                            color: root.dimColor
                            font.pixelSize: 10
                            font.letterSpacing: 0.8
                        }

                        Rectangle {
                            width: newColumn.width
                            height: newBodyText.implicitHeight + 20
                            radius: 8
                            color: root.panelColor
                            border.color: root.lineColor

                            Text {
                                id: newBodyText
                                x: 10
                                y: 10
                                width: parent.width - 20
                                // Escaped by styledSpots().
                                text: root.newBody === "" ? "Nothing selected lately: ↵ opens nvim to write it."
                                    : Snip.styledSpots(Snip.spotSegments(root.newBody, root.spots, root.spotState), root.colors)
                                textFormat: root.newBody === "" ? Text.PlainText : Text.StyledText
                                wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                color: root.newBody === "" ? root.dimColor : root.fgColor
                                font.family: root.monoFont
                                font.features: root.noLigatures
                                font.pixelSize: 12
                                lineHeight: 1.15
                            }
                        }
                    }
                }

                // --- footer ---

                Rectangle {
                    id: footerRule
                    anchors {
                        bottom: footer.top
                        left: parent.left
                        right: parent.right
                    }
                    height: 1
                    color: root.lineColor
                }

                Item {
                    id: footer
                    anchors {
                        bottom: parent.bottom
                        left: parent.left
                        right: parent.right
                    }
                    height: 38

                    Row {
                        anchors {
                            left: parent.left
                            leftMargin: 18
                            verticalCenter: parent.verticalCenter
                        }
                        spacing: 16

                        Repeater {
                            model: root.stage === "new"
                                ? [["↵", "write the body in nvim"], ["^↵", "save as it is"], ["Tab", "field"], ["→", "complete"]]
                                    .concat(root.spots.length > 0 ? [["Space", "make a field"]] : [])
                                    .concat([["Esc", root.newFromCapture ? "cancel" : "back"]])
                                : root.stage === "form"
                                ? [["↵", "next empty, else " + Snip.actionLabel(root.formSnippet)], ["^↵", "copy"], ["Tab", "field"],
                                   ["←→", "choice"], ["Alt S", "selection"], ["Esc", "back"]]
                                : [["↵", Snip.actionLabel(root.current)], ["⇧↵", "skip the form"], ["^↵", "copy"], ["Alt 1–9", "pick"]]
                                    .concat(root.ctx.selection !== "" && !root.ctx.fresh ? [["Alt S", "use the old selection"]] : [])
                                    .concat([["^E", "edit"], ["^N", "new"], ["Esc", "close"]])

                            Row {
                                id: hint
                                required property var modelData
                                spacing: 6

                                Rectangle {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: keyText.implicitWidth + 10
                                    height: 18
                                    radius: 4
                                    color: root.panelColor
                                    border.color: root.lineColor

                                    Text {
                                        id: keyText
                                        anchors.centerIn: parent
                                        text: hint.modelData[0]
                                        color: root.fgColor
                                        font.family: root.monoFont
                                        font.pixelSize: 10
                                    }
                                }
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: hint.modelData[1]
                                    color: root.dimColor
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
