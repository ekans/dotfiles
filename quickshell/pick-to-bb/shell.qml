pragma ComponentBehavior: Bound

// pick-to-bb: freeze the screen, pick what to ask about, write a prompt, and
// start a bb thread (the newest Opus, high reasoning, personal workspace) with
// it as context. Started by ~/.local/bin/pick-to-bb from a niri keybind.
//
// A bar at the top switches what a click on the frozen screen picks; Tab
// cycles it:
//   Element  a UI element: through AT-SPI for app windows, through
//            PickInspector.qml for Quickshell shells
//   Region   a rectangle dragged on the frozen screen
//   Window   a whole window, as niri captures it (parts off screen included)
//   Screen   the whole output
//
// niri's IPC has no on-screen position for tiled windows, and its own window
// picker holds the pointer until a click with no way to call it off, which
// would trap Tab. So the first element or window click has picktobb.py capture
// each window of the workspace and find where it sits on the frozen screen;
// later clicks only look the window up. Not before: each niri capture posts a
// "Screenshot captured" notification and lands in the clipboard history, which
// a region, the whole screen or Escape must not leave behind. The frozen screen
// takes every click, so the app under it never sees one.

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property color bgColor: "#1c1b22"
    readonly property color fgColor: "#deddda"
    readonly property color dimColor: "#77767b"
    readonly property color accentColor: "#62a0ea"
    readonly property color selectColor: "#ed333b"
    readonly property color badColor: "#f66151"
    readonly property color panelColor: "#24232b"
    readonly property color lineColor: "#36353e"

    readonly property string runDir: Quickshell.env("PICK_TO_BB_RUN_DIR") ?? ""
    readonly property string helper: Quickshell.shellPath("picktobb.py")
    readonly property string python: "/usr/bin/python3"

    // starting -> capturing -> ready -> sending
    property string phase: "starting"
    property var targetScreen: null
    property bool screenSaved: false
    // picktobb.py knows where the windows are on the frozen screen.
    property bool windowsReady: false
    property bool sendQueued: false
    property string error: ""

    readonly property var modes: ["element", "region", "window", "screen"]
    property string mode: "element"

    // Element: the last click, and the answer for it.
    property point point: Qt.point(-1, -1)
    property var located: null
    readonly property bool locating: point.x >= 0 && !(located && located.point[0] === point.x && located.point[1] === point.y)
    readonly property var element: located ? located.element : null

    // Region: the rectangle framed, in output-local logical px.
    property rect region: Qt.rect(0, 0, 0, 0)
    property point dragFrom: Qt.point(-1, -1)
    readonly property bool dragging: dragFrom.x >= 0

    // Window: the last click, and the window found under it: niri's
    // description plus `png`, its capture, and `rect`, where it is.
    property point windowPoint: Qt.point(-1, -1)
    property point shotPoint: Qt.point(-1, -1)
    property var shotWindow: null
    readonly property bool findingWindow: windowPoint.x >= 0 && (windowPoint.x !== shotPoint.x || windowPoint.y !== shotPoint.y)

    // Whether this mode has something to ask about, found yet or not.
    readonly property bool hasTarget: {
        switch (mode) {
        case "element":
            return point.x >= 0;
        case "region":
            return region.width > 0 && !dragging;
        case "window":
            return findingWindow || shotWindow !== null;
        }
        return true;
    }
    readonly property bool finding: mode === "element" ? locating : mode === "window" && findingWindow

    readonly property rect selection: {
        switch (mode) {
        case "region":
            return region;
        case "screen":
            return targetScreen ? Qt.rect(0, 0, targetScreen.width, targetScreen.height) : Qt.rect(0, 0, 0, 0);
        case "window":
            return shotWindow && !findingWindow ? onScreen(shotWindow.rect) : Qt.rect(0, 0, 0, 0);
        }
        if (element && element.rect && !locating)
            return onScreen(element.rect);
        if (point.x < 0)
            return Qt.rect(0, 0, 0, 0);
        // Same fallback box as picktobb.py's crop.
        const w = 320, h = 200;
        const sw = targetScreen ? targetScreen.width : w;
        const sh = targetScreen ? targetScreen.height : h;
        return Qt.rect(Math.min(Math.max(point.x - w / 2, 0), Math.max(sw - w, 0)),
                       Math.min(Math.max(point.y - h / 2, 0), Math.max(sh - h, 0)), w, h);
    }
    readonly property string elementLabel: {
        if (!element)
            return "";
        const name = element.name || (element.text || "").split("\n")[0];
        const short = name.length > 60 ? name.slice(0, 57) + "…" : name;
        return short ? `${element.role} · ${short}` : element.role;
    }

    function quit() {
        Qt.quit();
    }

    // [x, y, w, h] clipped to the output, as a rect.
    function onScreen(r) {
        const sw = targetScreen ? targetScreen.width : r[0] + r[2];
        const sh = targetScreen ? targetScreen.height : r[1] + r[3];
        const left = Math.max(r[0], 0), top = Math.max(r[1], 0);
        return Qt.rect(left, top, Math.max(Math.min(r[0] + r[2], sw) - left, 0), Math.max(Math.min(r[1] + r[3], sh) - top, 0));
    }

    function pick(x, y) {
        error = "";
        if (mode === "element")
            point = Qt.point(x, y);
        else if (mode === "window")
            windowPoint = Qt.point(x, y);
        pump();
    }

    // Start the lookups the last clicks wait for, once the frozen screen and
    // the windows on it are known; a click while one runs waits for it.
    function pump() {
        if (!screenSaved)
            return;
        if ((locating || findingWindow) && !windowsReady) {
            windowsProc.running = true;
            return;
        }
        if (locating && !locateProc.running) {
            locateProc.asked = point;
            locateProc.exec([python, helper, "locate", runDir, String(point.x), String(point.y)]);
        }
        if (findingWindow && !windowAtProc.running) {
            windowAtProc.asked = windowPoint;
            windowAtProc.exec([python, helper, "window-at", runDir, String(windowPoint.x), String(windowPoint.y)]);
        }
        if (sendQueued && !finding) {
            sendQueued = false;
            send();
        }
    }

    function send() {
        const prompt = promptInput.text.trim();
        if (!prompt || phase === "sending" || !hasTarget)
            return;
        if (phase !== "ready" || finding) {
            sendQueued = true;
            return;
        }
        if (mode === "window" && !shotWindow)
            return;
        phase = "sending";
        error = "";
        sendProc.exec(mode === "element" ? [python, helper, "send", runDir, prompt] : [python, helper, "send-shot", runDir, mode, prompt, String(region.x), String(region.y), String(region.width), String(region.height)]);
    }

    function setMode(next) {
        if (phase === "sending")
            return;
        error = "";
        mode = next;
        Qt.callLater(focusInput);
    }

    function cycleMode(step) {
        setMode(modes[(modes.indexOf(mode) + step + modes.length) % modes.length]);
    }

    function spanTo(x, y) {
        x = Math.min(Math.max(x, 0), ui.width);
        y = Math.min(Math.max(y, 0), ui.height);
        return Qt.rect(Math.min(dragFrom.x, x), Math.min(dragFrom.y, y), Math.abs(x - dragFrom.x), Math.abs(y - dragFrom.y));
    }

    // The prompt when it is up, else the overlay, so Escape and Tab still work.
    function focusInput() {
        if (panel.visible)
            promptInput.forceActiveFocus();
        else
            ui.forceActiveFocus();
    }

    // Escape cancels; Tab and Shift+Tab cycle the modes.
    function handleKey(event) {
        if (event.key === Qt.Key_Escape)
            quit();
        else if (event.key === Qt.Key_Tab)
            cycleMode(1);
        else if (event.key === Qt.Key_Backtab)
            cycleMode(-1);
        else
            return false;
        return true;
    }

    Component.onCompleted: {
        if (!runDir) {
            console.warn("pick-to-bb: PICK_TO_BB_RUN_DIR is not set; start it with ~/.local/bin/pick-to-bb");
            // Quitting while the config is still loading is ignored.
            Qt.callLater(quit);
        }
    }

    // The focused output, which the overlay freezes.
    Process {
        id: startProc
        running: root.runDir !== ""
        command: [root.python, root.helper, "start", root.runDir]
        stdout: StdioCollector {
            id: startOut
        }
        onExited: code => {
            let output = null;
            try {
                output = JSON.parse(startOut.text);
            } catch (e) {}
            if (code !== 0 || !output) {
                root.quit();
                return;
            }
            root.targetScreen = Quickshell.screens.find(s => s.name === output.name) ?? Quickshell.screens[0];
            root.phase = "capturing";
        }
    }

    // Capture the windows and find them on the frozen screen.
    Process {
        id: windowsProc
        command: [root.python, root.helper, "windows", root.runDir]
        stderr: StdioCollector {
            id: windowsErr
        }
        onExited: code => {
            if (code !== 0)
                root.error = "Could not find the windows: " + (windowsErr.text.trim().split("\n").pop() || `exit ${code}`);
            root.windowsReady = true;
            root.pump();
        }
    }

    Process {
        id: locateProc

        property point asked

        stdout: StdioCollector {
            id: locateOut
        }
        stderr: StdioCollector {
            id: locateErr
        }
        onExited: code => {
            try {
                root.located = JSON.parse(locateOut.text);
            } catch (e) {
                root.located = {
                    "point": [locateProc.asked.x, locateProc.asked.y],
                    "element": null,
                    "note": locateErr.text.trim().split("\n").pop() || `helper exited with ${code}`
                };
            }
            root.pump();
        }
    }

    Process {
        id: windowAtProc

        property point asked

        stdout: StdioCollector {
            id: windowAtOut
        }
        onExited: code => {
            let answer = null;
            try {
                answer = JSON.parse(windowAtOut.text);
            } catch (e) {}
            root.shotPoint = windowAtProc.asked;
            root.shotWindow = answer ? answer.window : null;
            if (!root.shotWindow)
                root.error = answer ? "No window there" : `The window lookup failed (exit ${code})`;
            root.focusInput();
            root.pump();
        }
    }

    Process {
        id: sendProc
        stdout: StdioCollector {
            id: sendOut
        }
        stderr: StdioCollector {
            id: sendErr
        }
        onExited: code => {
            let answer = null;
            try {
                answer = JSON.parse(sendOut.text);
            } catch (e) {}
            if (code === 0 && answer && answer.ok) {
                root.quit();
                return;
            }
            root.error = (answer && answer.error) || sendErr.text.trim().split("\n").pop() || `bb exited with ${code}`;
            root.phase = "ready";
        }
    }

    PanelWindow {
        id: overlay

        visible: root.targetScreen !== null
        screen: root.targetScreen
        anchors {
            top: true
            bottom: true
            left: true
            right: true
        }
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "pick-to-bb"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
        color: "transparent"

        // The frozen output. It is also what gets cropped for the thread, so
        // the element is sent as it looked when it was clicked. Captured once:
        // Quickshell 0.2.1 crashes when a capture source is dropped and set
        // again.
        ScreencopyView {
            id: frozen
            anchors.fill: parent
            captureSource: overlay.visible ? overlay.screen : null
            live: false
            onHasContentChanged: {
                if (!hasContent)
                    return;
                grabToImage(result => {
                    result.saveToFile(root.runDir + "/screen.png");
                    root.screenSaved = true;
                    root.phase = "ready";
                    root.pump();
                    root.focusInput();
                });
            }
        }

        // A click picks an element or a window, a drag frames a region; the
        // bar and the prompt panel sit above this and keep their own clicks.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton | Qt.RightButton
            cursorShape: root.mode === "screen" ? Qt.ArrowCursor : Qt.CrossCursor
            onPressed: mouse => {
                if (root.mode === "region" && root.phase === "ready" && mouse.button === Qt.LeftButton) {
                    root.dragFrom = Qt.point(mouse.x, mouse.y);
                    root.region = Qt.rect(mouse.x, mouse.y, 0, 0);
                }
            }
            onPositionChanged: mouse => {
                if (root.dragging)
                    root.region = root.spanTo(mouse.x, mouse.y);
            }
            onReleased: {
                if (!root.dragging)
                    return;
                root.dragFrom = Qt.point(-1, -1);
                // A click rather than a drag frames nothing.
                if (root.region.width < 4 || root.region.height < 4)
                    root.region = Qt.rect(0, 0, 0, 0);
            }
            onClicked: mouse => {
                if (mouse.button === Qt.RightButton)
                    root.quit();
                else if (root.mode === "element" || root.mode === "window")
                    root.pick(mouse.x, mouse.y);
                root.focusInput();
            }
        }

        Item {
            id: ui
            anchors.fill: parent
            visible: frozen.hasContent
            Keys.onPressed: event => {
                if (root.handleKey(event))
                    event.accepted = true;
            }

            // Everything but the selection is dimmed: four bands around it.
            Repeater {
                model: [
                    Qt.rect(0, 0, ui.width, root.selection.y),
                    Qt.rect(0, root.selection.y + root.selection.height, ui.width, ui.height - root.selection.y - root.selection.height),
                    Qt.rect(0, root.selection.y, root.selection.x, root.selection.height),
                    Qt.rect(root.selection.x + root.selection.width, root.selection.y, ui.width - root.selection.x - root.selection.width, root.selection.height)
                ]
                delegate: Rectangle {
                    required property rect modelData
                    x: modelData.x
                    y: modelData.y
                    width: Math.max(modelData.width, 0)
                    height: Math.max(modelData.height, 0)
                    color: "#99000000"
                }
            }

            // The window the element was found in.
            Rectangle {
                readonly property var area: root.mode === "element" && !root.locating && root.located ? root.located.window_rect : null

                visible: !!area
                x: visible ? area[0] : 0
                y: visible ? area[1] : 0
                width: visible ? area[2] : 0
                height: visible ? area[3] : 0
                color: "transparent"
                border.color: Qt.rgba(1, 1, 1, 0.35)
                border.width: 1
                radius: 8
            }

            Rectangle {
                visible: root.selection.width > 0 && root.mode !== "screen"
                x: root.selection.x - 2
                y: root.selection.y - 2
                width: root.selection.width + 4
                height: root.selection.height + 4
                color: "transparent"
                border.color: root.mode !== "element" ? root.accentColor : root.element && !root.locating ? root.selectColor : root.dimColor
                border.width: 2
                radius: 3
            }

            Rectangle {
                id: panel

                readonly property real gap: 12
                readonly property bool below: root.selection.y + root.selection.height + gap + height <= ui.height - gap
                // A window or the whole screen has no spot to sit next to.
                readonly property bool centered: root.mode === "window" || root.mode === "screen"
                // Clear of the mode bar.
                readonly property real topLimit: modeBar.y + modeBar.height + gap

                visible: root.hasTarget
                width: Math.min(600, ui.width - 2 * gap)
                height: column.implicitHeight + 24
                x: centered ? (ui.width - width) / 2 : Math.min(Math.max(root.selection.x, gap), ui.width - width - gap)
                y: centered || root.selection.width === 0 ? (ui.height - height) / 2 : below ? root.selection.y + root.selection.height + gap : Math.max(root.selection.y - height - gap, topLimit)
                radius: 10
                color: root.panelColor
                border.color: root.lineColor
                border.width: 1

                // Keep clicks on the panel from reaching the frozen screen.
                MouseArea {
                    anchors.fill: parent
                    onClicked: promptInput.forceActiveFocus()
                }

                Column {
                    id: column
                    anchors {
                        left: parent.left
                        right: parent.right
                        top: parent.top
                        margins: 12
                    }
                    spacing: 8

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        color: root.dimColor
                        font.pixelSize: 12
                        text: {
                            if (root.phase === "sending")
                                return "Starting the bb thread…";
                            switch (root.mode) {
                            case "element":
                                {
                                    if (root.locating)
                                        return "Finding the element…";
                                    if (root.element)
                                        return root.elementLabel;
                                    const window = root.located ? root.located.window : null;
                                    return `${window && window.app_id ? window.app_id : "screen"} · screenshot only` + (root.located && root.located.note ? ` (${root.located.note})` : "");
                                }
                            case "region":
                                return `Region · ${Math.round(root.region.width)}×${Math.round(root.region.height)}`;
                            case "window":
                                if (root.findingWindow)
                                    return "Finding the window…";
                                return root.shotWindow ? `Window · ${root.shotWindow.app_id || "?"} · ${root.shotWindow.title || ""}` : "Window";
                            }
                            return root.targetScreen ? `Screen · ${root.targetScreen.name} · ${root.targetScreen.width}×${root.targetScreen.height}` : "Screen";
                        }
                    }

                    // What a window screenshot sends: niri's capture, parts
                    // off screen included.
                    Image {
                        visible: root.mode === "window" && root.shotWindow !== null && !root.findingWindow
                        width: parent.width
                        height: visible ? Math.min(200, width * implicitHeight / Math.max(implicitWidth, 1)) : 0
                        fillMode: Image.PreserveAspectFit
                        asynchronous: true
                        mipmap: true
                        source: root.shotWindow ? "file://" + root.shotWindow.png : ""
                    }

                    Rectangle {
                        width: parent.width
                        height: Math.min(Math.max(promptInput.contentHeight, 20), 200) + 16
                        radius: 6
                        color: root.bgColor
                        border.color: promptInput.activeFocus ? root.accentColor : root.lineColor
                        border.width: 1
                        clip: true

                        TextEdit {
                            id: promptInput
                            anchors {
                                fill: parent
                                margins: 8
                            }
                            color: root.fgColor
                            selectionColor: root.accentColor
                            font.pixelSize: 14
                            wrapMode: TextEdit.Wrap
                            readOnly: root.phase === "sending"
                            Keys.onPressed: event => {
                                if (root.handleKey(event)) {
                                    event.accepted = true;
                                } else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && !(event.modifiers & Qt.ShiftModifier)) {
                                    root.send();
                                    event.accepted = true;
                                }
                            }

                            Text {
                                visible: promptInput.text.length === 0
                                color: root.dimColor
                                font: promptInput.font
                                text: "What should the agent do with this?"
                            }
                        }
                    }

                    Text {
                        visible: root.error !== ""
                        width: parent.width
                        wrapMode: Text.Wrap
                        color: root.badColor
                        font.pixelSize: 12
                        text: root.error
                    }

                    Text {
                        width: parent.width
                        elide: Text.ElideRight
                        color: root.dimColor
                        font.pixelSize: 11
                        text: (root.sendQueued ? "Sends once it is found · " : "") + "Opus · high · personal workspace    Enter send · Shift+Enter newline · Tab mode · Esc cancel"
                    }
                }
            }

            // What a click picks; Tab cycles it.
            Rectangle {
                id: modeBar

                anchors.horizontalCenter: parent.horizontalCenter
                y: 12
                width: modeColumn.implicitWidth + 12
                height: modeColumn.implicitHeight + 12
                radius: 10
                color: root.panelColor
                border.color: root.lineColor
                border.width: 1

                Column {
                    id: modeColumn
                    anchors.centerIn: parent
                    spacing: 6

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 4

                        Repeater {
                            model: root.modes
                            delegate: Rectangle {
                                id: modeButton

                                required property string modelData
                                readonly property bool current: modelData === root.mode

                                width: modeLabel.implicitWidth + 28
                                height: 30
                                radius: 6
                                color: current ? root.accentColor : modeHover.containsMouse ? root.lineColor : "transparent"

                                Text {
                                    id: modeLabel
                                    anchors.centerIn: parent
                                    color: modeButton.current ? root.bgColor : root.fgColor
                                    font.pixelSize: 13
                                    text: modeButton.modelData.charAt(0).toUpperCase() + modeButton.modelData.slice(1)
                                }

                                MouseArea {
                                    id: modeHover
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: root.setMode(modeButton.modelData)
                                }
                            }
                        }
                    }

                    Text {
                        visible: text !== ""
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: Math.min(implicitWidth, 560)
                        elide: Text.ElideRight
                        color: root.error && !panel.visible ? root.badColor : root.dimColor
                        font.pixelSize: 11
                        text: {
                            if (root.error && !panel.visible)
                                return root.error;
                            if (panel.visible || root.dragging)
                                return "";
                            const hints = {
                                "element": "Click the element to ask about",
                                "region": "Drag to frame a region",
                                "window": "Click the window to capture"
                            };
                            return hints[root.mode] ? hints[root.mode] + " · Tab mode · Esc cancel" : "";
                        }
                    }
                }
            }
        }
    }
}
