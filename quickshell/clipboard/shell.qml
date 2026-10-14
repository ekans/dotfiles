pragma ComponentBehavior: Bound

// Clipboard history for the niri session, on top of cliphist.
//
// This instance records — two `wl-paste --watch cliphist store`, one for text
// and one for images, as cliphist's README sets them up — and shows the history
// as an overlay toggled over IPC, from Super+Space v v in
// chauvenity's leader menu:
//
//     qs -c clipboard ipc call clipboard toggle
//
// It runs as clipboard-history.service, which niri.service pulls in through
// ~/.config/systemd/user/niri.service.d/50-clipboard-history.conf, the way the
// chauvenity-* units are pulled in: recording lasts the whole session and the
// overlay opens without Quickshell's start-up time.
//
// Binary data never passes through QML. Decoding, copying and deleting are sh
// pipelines, and images are decoded once into $XDG_RUNTIME_DIR.
//
// Keys: type to filter · ↑↓ or Ctrl+J/K select · Tab switch tab · Enter copy ·
// Shift+Enter copy and paste into the window that had focus · Alt+1…9 copy
// that row · Shift+Delete remove · Ctrl+O open a link · Ctrl+Shift+Delete twice
// wipe · Esc clear the filter, then close.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "clip.mjs" as Clip

ShellRoot {
    id: root

    // chauvenity's bar palette, so the overlay looks like part of it.
    readonly property color bgColor: "#1c1b22"
    readonly property color fgColor: "#deddda"
    readonly property color dimColor: "#77767b"
    readonly property color accentColor: "#62a0ea"
    readonly property color badColor: "#f66151"
    readonly property color panelColor: "#24232b"
    readonly property color lineColor: "#36353e"
    readonly property color hoverColor: "#2a2932"
    readonly property color selectColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.16)
    readonly property string monoFont: "JetBrains Mono"
    // JetBrains Mono's ligatures draw `<-` as an arrow: the clipboard has to be
    // shown as the characters it holds.
    readonly property var noLigatures: ({ liga: 0, calt: 0 })

    readonly property string cacheDir: (Quickshell.env("XDG_RUNTIME_DIR") || "/tmp") + "/clipboard-history"

    property bool open: false
    property var targetScreen: null
    // The window that had focus, which a paste goes back to.
    property string targetAppId: ""

    property var entries: []
    property string problem: ""
    property string query: ""
    property string category: "all"
    readonly property var shown: Clip.filterEntries(root.entries, root.query, root.category)
    readonly property var counts: Clip.categoryCounts(root.entries, root.query)
    readonly property var current: root.shown[list.currentIndex] ?? null

    // The selected text entry, decoded: {id, text, total, truncated}.
    property var detail: ({ id: "", text: "", total: 0, truncated: false })
    // Image id → "pending", "ready" or "failed".
    property var thumbs: ({})
    property bool wipeArmed: false

    onQueryChanged: list.currentIndex = 0
    onCategoryChanged: list.currentIndex = 0
    onCurrentChanged: detailDelay.restart()

    // --- recording ------------------------------------------------------------
    // Restarted when they die, like the bar's niri event stream: a recorder
    // that stopped silently would lose everything copied after it.

    Process {
        id: textRecorder
        running: true
        command: ["wl-paste", "--type", "text", "--watch", "cliphist", "store"]
        onRunningChanged: {
            if (!textRecorder.running)
                restartRecorders.restart();
        }
    }

    Process {
        id: imageRecorder
        running: true
        command: ["wl-paste", "--type", "image", "--watch", "cliphist", "store"]
        onRunningChanged: {
            if (!imageRecorder.running)
                restartRecorders.restart();
        }
    }

    Timer {
        id: restartRecorders
        interval: 1000
        onTriggered: {
            textRecorder.running = true;
            imageRecorder.running = true;
        }
    }

    // Copied images, hung on a line under the bar.
    Clothesline {
        id: clothesline
    }

    // --- opening ----------------------------------------------------------------

    IpcHandler {
        target: "clipboard"

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
        name: "clipboard-history"
        open: root.open
    }

    // Lets pick-to-bb (Super+Space b a) describe the overlay's elements.
    PickInspector {
        roots: [overlay]
    }

    function summon() {
        lister.running = true;
        probe.running = true;
    }

    // Opens on the output niri has focused rather than wherever Qt puts it.
    function present(where) {
        root.targetScreen = Quickshell.screens.find(s => s.name === where.output) ?? Quickshell.screens[0];
        root.targetAppId = where.appId;
        root.category = "all";
        root.wipeArmed = false;
        search.text = "";
        list.currentIndex = 0;
        root.open = true;
    }

    function close() {
        root.open = false;
    }

    Process {
        id: probe
        command: ["sh", "-c", "niri msg --json focused-output; niri msg --json focused-window"]
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: root.present(Clip.parseProbe(probeOut.text))
        }
    }

    Process {
        id: lister
        command: ["cliphist", "-preview-width", String(Clip.PREVIEW_WIDTH), "list"]
        stdout: StdioCollector {
            id: listOut
            onStreamFinished: root.load(Clip.parseList(listOut.text))
        }
        stderr: StdioCollector {
            id: listErr
        }
        onExited: code => {
            root.problem = code === 0 ? "" : (listErr.text.trim() || `cliphist list failed (exit ${code})`);
        }
    }

    function load(entries) {
        const images = entries.filter(e => e.kind === "image").map(e => e.id);
        const kept = {};
        for (const id of images) {
            if (root.thumbs[id] === "ready")
                kept[id] = "ready";
        }
        // Before the entries: their rows ask for thumbnails as they are made.
        root.thumbs = kept;
        root.entries = entries;
        // Drops the decoded images of entries cliphist no longer lists.
        root.run(["sh", "-c",
                  'cd "$1" 2>/dev/null || exit 0; shift; for f in *.*; do case "$f" in *.part) continue ;; esac; '
                  + 'case " $* " in *" ${f%%.*} "*) ;; *) rm -f -- "$f" ;; esac; done',
                  "sh", root.cacheDir].concat(images));
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

    // Runs `command` and hands its stdout to `callback`. Not for anything that
    // starts wl-copy: it keeps stdout open for as long as it owns the clipboard.
    function run(command, callback) {
        const job = jobComponent.createObject(root, { callback: callback ?? null });
        job.command = command;
        job.running = true;
    }

    function setThumb(id, state) {
        const next = Object.assign({}, root.thumbs);
        next[id] = state;
        root.thumbs = next;
    }

    function ensureThumb(entry) {
        if (!entry || entry.kind !== "image" || root.thumbs[entry.id])
            return;
        root.setThumb(entry.id, "pending");
        root.run(["sh", "-c",
                  '[ -s "$1" ] || { mkdir -p "${1%/*}" && cliphist decode "$2" > "$1.part" && mv "$1.part" "$1"; } && echo ok',
                  "sh", Clip.thumbPath(root.cacheDir, entry), entry.id],
                 out => root.setThumb(entry.id, out.trim() === "ok" ? "ready" : "failed"));
    }

    function thumbSource(entry) {
        return entry && root.thumbs[entry.id] === "ready" ? "file://" + Clip.thumbPath(root.cacheDir, entry) : "";
    }

    // Waits for the selection to settle, so holding ↓ does not decode every
    // entry on the way.
    Timer {
        id: detailDelay
        interval: 40
        onTriggered: root.loadDetail()
    }

    function loadDetail() {
        const entry = root.current;
        if (!entry)
            return;
        if (entry.kind === "image") {
            root.ensureThumb(entry);
            return;
        }
        if (root.detail.id === entry.id)
            return;
        root.run(["sh", "-c", 'printf "%s\\n" "$(cliphist decode "$1" | wc -c)"; cliphist decode "$1" | head -c "$2"',
                  "sh", entry.id, String(Clip.DETAIL_LIMIT)],
                 out => {
                     if (root.current?.id !== entry.id)
                         return;
                     const detail = Clip.parseDetail(out);
                     detail.id = entry.id;
                     root.detail = detail;
                 });
    }

    // --- actions --------------------------------------------------------------

    // Decoded into a file first, and handed to wl-copy only when that file is
    // not empty: a failed decode piped straight in would empty the clipboard.
    readonly property string copyScript: 'f=$(mktemp "${XDG_RUNTIME_DIR:-/tmp}/clipboard-copy.XXXXXX") || exit 1; '
        + 'trap \'rm -f "$f"\' EXIT; '
        + 'cliphist decode "$1" > "$f" && [ -s "$f" ] || exit 1; '
        + 'wl-copy --type "$2" < "$f" || exit 1; '
        + 'shift 2; [ $# -gt 0 ] || exit 0; '
        // Long enough for niri to give the keyboard back to the window.
        + 'sleep 0.15; wtype "$@"'

    function activate(entry, paste) {
        if (!entry)
            return;
        root.close();
        Quickshell.execDetached(["sh", "-c", root.copyScript, "sh", entry.id, entry.mime || "text/plain;charset=utf-8"]
            .concat(paste ? Clip.pasteKeys(root.targetAppId) : []));
    }

    function remove(entry) {
        if (!entry)
            return;
        const index = list.currentIndex;
        root.entries = root.entries.filter(e => e.id !== entry.id);
        list.currentIndex = Math.max(0, Math.min(index, root.shown.length - 1));
        Quickshell.execDetached(["sh", "-c", 'printf "%s\\t\\n" "$1" | cliphist delete; [ -z "$2" ] || rm -f -- "$2"',
                                 "sh", entry.id, entry.kind === "image" ? Clip.thumbPath(root.cacheDir, entry) : ""]);
    }

    function wipe() {
        if (!root.wipeArmed) {
            root.wipeArmed = true;
            disarm.restart();
            return;
        }
        root.wipeArmed = false;
        root.entries = [];
        root.thumbs = {};
        clothesline.clear();
        Quickshell.execDetached(["sh", "-c", 'cliphist wipe; rm -rf -- "$1"', "sh", root.cacheDir]);
    }

    Timer {
        id: disarm
        interval: 4000
        onTriggered: root.wipeArmed = false
    }

    function openCurrent() {
        const entry = root.current;
        if (!entry || (entry.kind !== "link" && entry.kind !== "path"))
            return;
        let target = root.detail.id === entry.id ? root.detail.text.trim() : entry.preview;
        if (target.startsWith("~/"))
            target = Quickshell.env("HOME") + target.slice(1);
        root.close();
        Quickshell.execDetached(["xdg-open", target]);
    }

    function move(step) {
        const count = root.shown.length;
        if (count === 0)
            return;
        let next = list.currentIndex + step;
        if (Math.abs(step) === 1)
            next = (next + count) % count;
        list.currentIndex = Math.max(0, Math.min(count - 1, next));
    }

    function cycleCategory(step) {
        const keys = Clip.CATEGORIES.map(c => c.key);
        root.category = keys[(keys.indexOf(root.category) + step + keys.length) % keys.length];
    }

    function handleKey(event) {
        const ctrl = (event.modifiers & Qt.ControlModifier) !== 0;
        const shift = (event.modifiers & Qt.ShiftModifier) !== 0;
        const alt = (event.modifiers & Qt.AltModifier) !== 0;
        const key = event.key;
        // The digit row by position, so Alt+1…9 also works on AZERTY.
        const digit = event.nativeScanCode - 9;

        if (key === Qt.Key_Escape) {
            if (search.text !== "")
                search.text = "";
            else if (root.category !== "all")
                root.category = "all";
            else
                root.close();
        } else if (key === Qt.Key_Down || (ctrl && (key === Qt.Key_J || key === Qt.Key_N))) {
            root.move(1);
        } else if (key === Qt.Key_Up || (ctrl && (key === Qt.Key_K || key === Qt.Key_P))) {
            root.move(-1);
        } else if (key === Qt.Key_PageDown) {
            root.move(list.pageSize);
        } else if (key === Qt.Key_PageUp) {
            root.move(-list.pageSize);
        } else if (key === Qt.Key_Tab) {
            root.cycleCategory(1);
        } else if (key === Qt.Key_Backtab) {
            root.cycleCategory(-1);
        } else if (key === Qt.Key_Return || key === Qt.Key_Enter) {
            root.activate(root.current, shift);
        } else if (key === Qt.Key_Delete && ctrl && shift) {
            root.wipe();
        } else if (key === Qt.Key_Delete && (shift || search.text === "")) {
            root.remove(root.current);
        } else if (ctrl && key === Qt.Key_O) {
            root.openCurrent();
        } else if (alt && digit >= 1 && digit <= 9) {
            root.activate(root.shown[digit - 1] ?? null, shift);
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
        WlrLayershell.namespace: "clipboard-history"
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
                            right: total.left
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
                        Keys.onPressed: event => root.handleKey(event)

                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: search.text === ""
                            text: "Search clipboard history"
                            color: root.dimColor
                            font.pixelSize: 16
                        }
                    }

                    Text {
                        id: total
                        anchors {
                            right: parent.right
                            rightMargin: 22
                            verticalCenter: parent.verticalCenter
                        }
                        text: root.shown.length === root.entries.length
                            ? Clip.count(root.entries.length, "entry", "entries")
                            : `${root.shown.length} of ${root.entries.length}`
                        color: root.dimColor
                        font.pixelSize: 12
                    }
                }

                // Tabs.
                Row {
                    id: tabs
                    anchors {
                        top: header.bottom
                        left: parent.left
                        leftMargin: 16
                    }
                    height: 34
                    spacing: 6

                    Repeater {
                        model: Clip.CATEGORIES

                        Rectangle {
                            id: tab
                            required property var modelData
                            readonly property bool selected: root.category === tab.modelData.key
                            readonly property int amount: root.counts[tab.modelData.key] ?? 0

                            anchors.verticalCenter: parent.verticalCenter
                            width: tabLabel.implicitWidth + 20
                            height: 24
                            radius: 12
                            color: tab.selected ? root.accentColor : (tabMouse.containsMouse ? root.hoverColor : "transparent")
                            border.color: tab.selected ? root.accentColor : root.lineColor

                            Text {
                                id: tabLabel
                                anchors.centerIn: parent
                                text: tab.modelData.label + "  " + tab.amount
                                color: tab.selected ? root.bgColor : (tab.amount > 0 ? root.fgColor : root.dimColor)
                                font.pixelSize: 12
                                font.bold: tab.selected
                            }

                            MouseArea {
                                id: tabMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.category = tab.modelData.key
                            }
                        }
                    }
                }

                Rectangle {
                    id: headerRule
                    anchors {
                        top: tabs.bottom
                        topMargin: 8
                        left: parent.left
                        right: parent.right
                    }
                    height: 1
                    color: root.lineColor
                }

                // --- the list ---

                ListView {
                    id: list

                    readonly property int pageSize: Math.max(1, Math.floor(list.height / 44))

                    anchors {
                        top: headerRule.bottom
                        bottom: footerRule.top
                        left: parent.left
                        margins: 8
                    }
                    width: Math.round(parent.width * 0.55)
                    clip: true
                    model: root.shown
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
                        readonly property bool isImage: row.modelData.kind === "image"
                        readonly property bool isCurrent: row.ListView.isCurrentItem

                        width: list.width
                        height: row.isImage ? 64 : 44

                        Component.onCompleted: root.ensureThumb(row.modelData)

                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.MiddleButton
                            // Moving the mouse selects; a list scrolling under a
                            // still mouse does not.
                            onPositionChanged: list.currentIndex = row.index
                            onClicked: mouse => root.activate(row.modelData, mouse.button === Qt.MiddleButton)
                        }

                        // Kind: a glyph, the colour itself, or the picture.
                        Rectangle {
                            id: badge
                            x: 14
                            anchors.verticalCenter: parent.verticalCenter
                            width: row.isImage ? 64 : 28
                            height: row.isImage ? 48 : 28
                            radius: 6
                            color: row.modelData.kind === "color" ? row.modelData.color : root.panelColor
                            border.color: root.lineColor
                            clip: true

                            Text {
                                anchors.centerIn: parent
                                visible: !row.isImage && row.modelData.kind !== "color"
                                text: ({ text: "¶", link: "↗", path: "/" })[row.modelData.kind] ?? ""
                                color: row.isCurrent ? root.accentColor : root.dimColor
                                font.pixelSize: 14
                                font.bold: true
                            }

                            Image {
                                anchors.fill: parent
                                anchors.margins: 1
                                visible: row.isImage
                                source: row.isImage ? root.thumbSource(row.modelData) : ""
                                sourceSize.width: 128
                                sourceSize.height: 96
                                fillMode: Image.PreserveAspectCrop
                                asynchronous: true
                            }
                        }

                        Column {
                            anchors {
                                left: badge.right
                                leftMargin: 12
                                right: trailing.left
                                rightMargin: 10
                                verticalCenter: parent.verticalCenter
                            }
                            spacing: 2

                            Text {
                                width: parent.width
                                // Escaped by highlight(): StyledText would
                                // otherwise render markup copied from anywhere.
                                text: row.isImage
                                    ? `${row.modelData.format.toUpperCase()} image`
                                    : Clip.highlight(row.modelData.preview, root.query, root.accentColor)
                                textFormat: row.isImage ? Text.PlainText : Text.StyledText
                                elide: Text.ElideRight
                                maximumLineCount: 1
                                color: root.fgColor
                                font.pixelSize: 13
                                font.family: row.modelData.kind === "color" || row.modelData.kind === "path"
                                    ? root.monoFont : Qt.application.font.family
                                font.features: root.noLigatures
                            }

                            Text {
                                visible: row.isImage
                                text: row.isImage ? `${row.modelData.width} × ${row.modelData.height} · ${row.modelData.size}` : ""
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

                            Rectangle {
                                anchors.verticalCenter: parent.verticalCenter
                                readonly property string tag: row.isImage ? "" : Clip.rowTag(row.modelData)
                                visible: tag !== ""
                                width: tagText.implicitWidth + 12
                                height: 18
                                radius: 4
                                color: root.panelColor

                                Text {
                                    id: tagText
                                    anchors.centerIn: parent
                                    text: parent.tag
                                    color: root.dimColor
                                    font.pixelSize: 10
                                }
                            }

                            // Alt+N hint, or the delete button on the selected row.
                            Item {
                                anchors.verticalCenter: parent.verticalCenter
                                width: 22
                                height: 22

                                Text {
                                    anchors.centerIn: parent
                                    visible: !row.isCurrent && row.index < 9
                                    text: String(row.index + 1)
                                    color: root.dimColor
                                    font.family: root.monoFont
                                    font.pixelSize: 11
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    visible: row.isCurrent
                                    radius: 5
                                    color: trashMouse.containsMouse ? Qt.rgba(root.badColor.r, root.badColor.g, root.badColor.b, 0.2) : "transparent"

                                    Text {
                                        anchors.centerIn: parent
                                        text: "×"
                                        color: trashMouse.containsMouse ? root.badColor : root.dimColor
                                        font.pixelSize: 16
                                    }

                                    MouseArea {
                                        id: trashMouse
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        onClicked: root.remove(row.modelData)
                                    }
                                }
                            }
                        }
                    }

                    Column {
                        anchors.centerIn: parent
                        visible: root.shown.length === 0
                        spacing: 6

                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.problem !== "" ? "cliphist is not answering"
                                : root.entries.length === 0 ? "Nothing copied yet"
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
                                : root.entries.length === 0 ? "Copy something and it shows up here."
                                : "Esc clears the filter."
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
                    id: preview

                    readonly property var entry: root.current
                    readonly property string kind: preview.entry ? preview.entry.kind : ""
                    readonly property bool loaded: !!preview.entry && root.detail.id === preview.entry.id

                    anchors {
                        top: headerRule.bottom
                        bottom: footerRule.top
                        left: divider.right
                        right: parent.right
                        margins: 18
                    }
                    visible: !!preview.entry

                    onEntryChanged: body.contentY = 0

                    Text {
                        id: previewTitle
                        anchors {
                            top: parent.top
                            left: parent.left
                            right: parent.right
                        }
                        text: preview.entry ? Clip.describe(preview.entry, root.detail) : ""
                        elide: Text.ElideRight
                        color: root.dimColor
                        font.pixelSize: 11
                        font.letterSpacing: 0.4
                    }

                    // Text, links and paths.
                    Flickable {
                        id: body
                        anchors {
                            top: previewTitle.bottom
                            topMargin: 12
                            bottom: actions.top
                            bottomMargin: 12
                            left: parent.left
                            right: parent.right
                        }
                        visible: preview.kind === "text" || preview.kind === "link" || preview.kind === "path"
                        clip: true
                        contentWidth: width
                        contentHeight: bodyText.implicitHeight
                        boundsBehavior: Flickable.StopAtBounds

                        Text {
                            id: bodyText
                            width: body.width - 8
                            text: !preview.entry ? "" : (preview.loaded ? root.detail.text : preview.entry.preview)
                            // Clipboard text is shown as it is, never as markup.
                            textFormat: Text.PlainText
                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                            color: preview.kind === "link" ? root.accentColor : root.fgColor
                            opacity: preview.loaded ? 1 : 0.5
                            font.family: root.monoFont
                            font.features: root.noLigatures
                            font.pixelSize: 12
                            lineHeight: 1.15
                        }

                        Rectangle {
                            visible: body.contentHeight > body.height
                            x: body.width - 3
                            y: body.contentY + body.visibleArea.yPosition * body.height
                            width: 3
                            height: Math.max(24, body.visibleArea.heightRatio * body.height)
                            radius: 1.5
                            color: root.lineColor
                        }
                    }

                    // Colours.
                    Column {
                        anchors {
                            top: previewTitle.bottom
                            topMargin: 12
                            left: parent.left
                            right: parent.right
                        }
                        visible: preview.kind === "color"
                        spacing: 12

                        Rectangle {
                            width: parent.width
                            height: 160
                            radius: 10
                            color: preview.kind === "color" ? preview.entry.color : "transparent"
                            border.color: root.lineColor
                        }
                        Repeater {
                            model: preview.kind === "color" ? Object.values(Clip.colorFormats(preview.entry.color)) : []

                            Text {
                                required property string modelData
                                text: modelData
                                textFormat: Text.PlainText
                                color: root.fgColor
                                font.family: root.monoFont
                                font.features: root.noLigatures
                                font.pixelSize: 15
                            }
                        }
                    }

                    // Images.
                    Rectangle {
                        anchors {
                            top: previewTitle.bottom
                            topMargin: 12
                            bottom: actions.top
                            bottomMargin: 12
                            left: parent.left
                            right: parent.right
                        }
                        visible: preview.kind === "image"
                        radius: 8
                        color: root.panelColor

                        Image {
                            anchors.fill: parent
                            anchors.margins: 8
                            source: preview.kind === "image" ? root.thumbSource(preview.entry) : ""
                            sourceSize.width: 2 * width
                            sourceSize.height: 2 * height
                            fillMode: Image.PreserveAspectFit
                            asynchronous: true
                        }
                    }

                    Row {
                        id: actions
                        anchors {
                            bottom: parent.bottom
                            left: parent.left
                        }
                        spacing: 8

                        Repeater {
                            model: [
                                { label: "Copy", show: true },
                                { label: "Paste", show: true },
                                { label: "Open", show: preview.kind === "link" || preview.kind === "path" },
                                { label: "Delete", show: true },
                            ]

                            Rectangle {
                                id: action
                                required property var modelData
                                visible: action.modelData.show
                                width: actionLabel.implicitWidth + 24
                                height: 28
                                radius: 6
                                color: actionMouse.containsMouse ? root.hoverColor : root.panelColor
                                border.color: root.lineColor

                                Text {
                                    id: actionLabel
                                    anchors.centerIn: parent
                                    text: action.modelData.label
                                    color: action.modelData.label === "Delete" && actionMouse.containsMouse ? root.badColor : root.fgColor
                                    font.pixelSize: 12
                                }

                                MouseArea {
                                    id: actionMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        switch (action.modelData.label) {
                                        case "Copy":
                                            root.activate(preview.entry, false);
                                            break;
                                        case "Paste":
                                            root.activate(preview.entry, true);
                                            break;
                                        case "Open":
                                            root.openCurrent();
                                            break;
                                        case "Delete":
                                            root.remove(preview.entry);
                                            break;
                                        }
                                    }
                                }
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
                        visible: !root.wipeArmed
                        spacing: 16

                        Repeater {
                            model: [
                                ["↵", "copy"], ["⇧↵", "paste"], ["Tab", "filter"], ["Alt 1–9", "pick"],
                                ["⇧Del", "remove"], ["^O", "open"], ["Esc", "close"],
                            ]

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

                    Text {
                        anchors {
                            left: parent.left
                            leftMargin: 18
                            verticalCenter: parent.verticalCenter
                        }
                        visible: root.wipeArmed
                        text: `Press Ctrl+Shift+Delete again to wipe all ${Clip.count(root.entries.length, "entry", "entries")}`
                        color: root.badColor
                        font.pixelSize: 12
                        font.bold: true
                    }
                }
            }
        }
    }
}
