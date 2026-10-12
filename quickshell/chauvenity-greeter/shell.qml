pragma ComponentBehavior: Bound

// The login screen: greetd's greeter, drawn as the niri session's lock screen
// (../chauvenity-lock/LockFace.qml), prototype "01 · same face". The time, a
// dot per character typed, `ducatore · niri` under them; Tab picks the
// session, Enter logs in.
//
// greetd runs it inside a compositor of its own, as the greeter user:
//
//     qs -c chauvenity-greeter
//
// There is no fingerprint here on purpose: a finger cannot unlock
// gnome-keyring, a password can, and PAM's greetd service does it with the
// password this screen sends.
//
// Try it without greetd, against a fake one, inside niri-sandbox:
// tests/proof.sh. Logic in greeter.mjs; tests:
// node --test ~/.config/quickshell/chauvenity-greeter/tests/

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Greetd
import "greeter.mjs" as Logic
import "lock/lock.mjs" as Lock

ShellRoot {
    id: root

    // The lock screen's palette (../chauvenity-lock/shell.qml), which
    // LockFace reads from whatever it is given as `lock`.
    readonly property color backgroundColor: "#141318"
    readonly property color fgColor: "#deddda"
    readonly property color dimColor: "#77767b"
    readonly property color accentColor: "#62a0ea"
    readonly property color goodColor: "#57e389"
    readonly property color warnColor: "#ffa348"
    readonly property color badColor: "#f66151"

    readonly property string user: Quickshell.env("CHAUVENITY_GREETER_USER") || Logic.USER
    readonly property string sessionsDir: Quickshell.env("CHAUVENITY_GREETER_SESSIONS") || "/usr/share/wayland-sessions"

    // --- what LockFace reads -----------------------------------------------

    property var login: Logic.INITIAL
    readonly property string buffer: root.login.buffer
    readonly property string passwordState: root.login.phase
    readonly property string fingerState: "unavailable"
    readonly property int fingerTriesLeft: 0
    property bool capsLock: false
    readonly property string clockText: Lock.clockLine(clock.date)

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    function edit(text) {
        // Escape, with the power menu open, closes it.
        if (root.powerOpen) {
            if (text === "")
                root.powerOpen = false;
            return;
        }
        root.dispatch({ type: "edit", text: text });
    }

    function submit() {
        // Enter with the power menu open is not a login; the letters that
        // follow would be power actions.
        if (root.powerOpen)
            return;
        root.dispatch({ type: "submit", available: Greetd.available });
    }

    // --- the login ----------------------------------------------------------

    function dispatch(event) {
        const result = Logic.step(root.login, event);
        root.login = result.state;
        for (const effect of result.effects)
            root.perform(effect);
    }

    function perform(effect) {
        switch (effect.type) {
        case "createSession":
            Greetd.createSession(root.user);
            break;
        case "respond":
            Greetd.respond(effect.text);
            break;
        case "cancelSession":
            if (Greetd.state !== GreetdState.Inactive)
                Greetd.cancelSession();
            break;
        case "settleLater":
            settle.restart();
            break;
        case "launchSoon":
            launch.start();
            break;
        }
    }

    Connections {
        target: Greetd

        function onAuthMessage(message, error, responseRequired, echoResponse) {
            root.dispatch({ type: "authMessage", responseRequired: responseRequired });
        }
        function onAuthFailure(message) {
            root.dispatch({ type: "authFailure" });
        }
        function onReadyToLaunch() {
            root.dispatch({ type: "readyToLaunch" });
        }
        function onError(error) {
            console.warn(`chauvenity-greeter: greetd: ${error}`);
            root.dispatch({ type: "error" });
        }
    }

    Timer {
        id: settle
        interval: 1500
        onTriggered: root.dispatch({ type: "settle" })
    }

    // The green dots a moment, then the session. greetd ends this process
    // once it has started it: launch() quits Quickshell too.
    Timer {
        id: launch
        interval: 280
        onTriggered: {
            const spec = Logic.launchSpec(root.session);
            console.log(`chauvenity-greeter: launching ${spec.command.join(" ")}`);
            Greetd.launch(spec.command, spec.environment);
        }
    }

    // --- sessions -----------------------------------------------------------

    property var sessions: [Logic.FALLBACK_SESSION]
    property int sessionIndex: 0
    readonly property var session: root.sessions[root.sessionIndex]

    function nextSession(step) {
        if (root.passwordState === "checking" || root.passwordState === "unlocked")
            return;
        root.sessionIndex = Logic.cycle(root.sessionIndex, root.sessions.length, step);
    }

    Process {
        running: true
        // Each file behind a line "@@<path>", which parseSessions splits on.
        command: ["sh", "-c", "for f in \"$1\"/*.desktop; do [ -f \"$f\" ] && { printf '@@%s\\n' \"$f\"; cat \"$f\"; echo; }; done", "sh", root.sessionsDir]
        stdout: StdioCollector {
            onStreamFinished: {
                root.sessions = Logic.loadSessions(text, Logic.DEFAULT_SESSION);
                root.sessionIndex = 0;
            }
        }
    }

    // --- power --------------------------------------------------------------

    property bool powerOpen: false

    function togglePower() {
        if (root.passwordState === "checking" || root.passwordState === "unlocked")
            return;
        root.powerOpen = !root.powerOpen;
    }

    // Whether `text` was one of the power menu's letters.
    function choosePower(text) {
        const action = Logic.powerAction(text);
        if (action === null)
            return false;
        root.powerOpen = false;
        Quickshell.execDetached(action.command);
        return true;
    }

    // --- Caps Lock ----------------------------------------------------------

    Process {
        id: capsProbe
        command: ["sh", "-c", "cat /sys/class/leds/*::capslock/brightness 2>/dev/null"]
        stdout: StdioCollector {
            id: capsOutput
            onStreamFinished: root.capsLock = Lock.capsLockOn(capsOutput.text)
        }
    }

    Timer {
        interval: 400
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: capsProbe.running = true
    }

    // --- the screen -----------------------------------------------------------

    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: window
            required property var modelData
            screen: window.modelData
            anchors { top: true; bottom: true; left: true; right: true }
            exclusionMode: ExclusionMode.Ignore
            color: root.backgroundColor
            WlrLayershell.namespace: "chauvenity-greeter"
            WlrLayershell.layer: WlrLayer.Overlay
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

            GreeterFace {
                anchors.fill: parent
                greeter: root
            }
        }
    }
}
