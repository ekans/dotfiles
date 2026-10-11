pragma ComponentBehavior: Bound

// The niri session's lock screen: prototype "08 · Just dots" — the time, a
// dot per character typed, and the fingerprint sensor, live alongside the
// password.
//
// It is a process of its own, the way swaylock is, rather than part of the
// bar: a bar that crashes, restarts or reloads half-edited QML must not take
// the lock down with it. Starting it locks; unlocking ends it.
//
//     ~/.config/quickshell/chauvenity-lock/lock.sh     what swayidle runs
//
// lock.sh starts it as the transient unit chauvenity-lock.service, with
// Restart=on-failure, and returns once niri has confirmed every output is
// covered — swayidle's before-sleep waits on that. If it ever dies while
// locked, niri keeps the screen locked and painted red, systemd starts it
// again, and the new one takes the lock back.
//
// Two PAM conversations run side by side, so a finger or a password unlocks,
// whichever comes first:
//
//     /etc/pam.d/password-auth      pam_unix only, started on Enter
//     /etc/pam.d/fingerprint-auth   pam_fprintd only, from the start
//
// /etc/pam.d/system-auth would ask for the finger *before* the password, and
// sit there for fprintd's 30 s timeout first. Both files are authselect's.
//
// Try it without locking anything — a window instead of the lock, with real
// PAM behind it; a finger or the password closes it:
//
//     CHAUVENITY_LOCK_PREVIEW=1 qs -c chauvenity-lock
//
// Logic in lock.mjs; tests: node --test ~/.config/quickshell/chauvenity-lock/tests/

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Services.Pam
import "lock.mjs" as Logic

ShellRoot {
    id: root

    // chauvenity's bar palette; the background is the prototype's, a shade
    // under the bar's.
    readonly property color backgroundColor: "#141318"
    readonly property color fgColor: "#deddda"
    readonly property color dimColor: "#77767b"
    readonly property color accentColor: "#62a0ea"
    readonly property color goodColor: "#57e389"
    readonly property color warnColor: "#ffa348"
    readonly property color badColor: "#f66151"

    readonly property bool preview: Quickshell.env("CHAUVENITY_LOCK_PREVIEW") === "1"

    // --- state, shown by LockFace on every output ---------------------------

    // What is typed so far. Shared, so that every output's dots agree.
    property string buffer: ""
    // "idle", "typing", "checking", "wrong", "error" or "unlocked".
    property string passwordState: "idle"
    // "ready", "retry", "nomatch", "match", "off" or "unavailable".
    property string fingerState: "ready"
    property int fingerNoMatches: 0
    readonly property int fingerTriesLeft: Math.max(0, Logic.FINGER_TRIES - root.fingerNoMatches)
    property bool capsLock: false
    readonly property string clockText: Logic.clockLine(clock.date)

    SystemClock {
        id: clock
        precision: SystemClock.Minutes
    }

    function edit(text) {
        if (root.passwordState === "checking" || root.passwordState === "unlocked")
            return;
        root.buffer = text;
        root.passwordState = text === "" ? "idle" : "typing";
    }

    function unlock() {
        if (root.passwordState === "unlocked")
            return;
        root.passwordState = "unlocked";
        passwordPam.abort();
        fingerPam.abort();
        fingerRestart.stop();
        // The fade, then the lock goes.
        release.start();
    }

    Timer {
        id: release
        interval: 280
        onTriggered: {
            root.buffer = "";
            if (!root.preview)
                sessionLock.locked = false;
            // Unlocked, the process has nothing left to do; lock.sh starts a
            // new one for the next lock.
            quitAfterUnlock.start();
        }
    }

    // --- password -----------------------------------------------------------

    // Whether this attempt's password has gone to PAM. A second question in
    // the same attempt (an expired password wanting a new one) is not one
    // this screen can answer.
    property bool answered: false

    function submit() {
        if (root.buffer === "" || root.passwordState === "checking" || root.passwordState === "unlocked")
            return;
        root.passwordState = "checking";
        root.answered = false;
        if (!passwordPam.start())
            root.passwordFailed("error");
    }

    function passwordFailed(state) {
        root.buffer = "";
        root.passwordState = state;
        backToIdle.restart();
    }

    PamContext {
        id: passwordPam
        config: "password-auth"

        onResponseRequiredChanged: {
            if (!passwordPam.responseRequired)
                return;
            if (root.answered) {
                console.warn(`chauvenity-lock: PAM asked a second question: ${passwordPam.message}`);
                passwordPam.abort();
                root.passwordFailed("error");
                return;
            }
            root.answered = true;
            passwordPam.respond(root.buffer);
        }
        onCompleted: result => {
            if (root.passwordState === "unlocked")
                return;
            if (result === PamResult.Success)
                root.unlock();
            else
                root.passwordFailed(result === PamResult.Failed ? "wrong" : "error");
        }
        onError: error => console.warn(`chauvenity-lock: password PAM: ${PamError.toString(error)}`)
    }

    Timer {
        id: backToIdle
        interval: 1500
        onTriggered: {
            if (root.passwordState === "wrong" || root.passwordState === "error")
                root.passwordState = root.buffer === "" ? "idle" : "typing";
        }
    }

    // --- fingerprint --------------------------------------------------------

    // Whether this run has asked for a finger, and how many runs in a row
    // before it never did: fprintd missing, no sensor, no finger enrolled.
    property bool fingerPrompted: false
    property int fingerDeadRuns: 0

    function startFinger() {
        if (root.passwordState === "unlocked" || root.fingerState === "off" || root.fingerState === "unavailable")
            return;
        root.fingerPrompted = false;
        if (!fingerPam.start())
            root.fingerFinished("error");
    }

    function fingerFinished(result) {
        if (root.passwordState === "unlocked")
            return;
        const action = Logic.fingerAfter({
            result: result,
            sawPrompt: root.fingerPrompted,
            noMatches: root.fingerNoMatches,
            deadRuns: root.fingerDeadRuns
        });
        root.fingerDeadRuns = root.fingerPrompted ? 0 : root.fingerDeadRuns + 1;
        if (action === "unlock") {
            root.fingerState = "match";
            root.unlock();
        } else if (action === "off") {
            fingerShowNoMatch.stop();
            root.fingerState = "off";
        } else if (action === "unavailable") {
            console.warn("chauvenity-lock: the fingerprint sensor never asked for a finger; password only");
            root.fingerState = "unavailable";
        } else {
            fingerRestart.interval = action === "later" ? 5000 : 200;
            fingerRestart.restart();
        }
    }

    PamContext {
        id: fingerPam
        config: "fingerprint-auth"

        onPamMessage: {
            const kind = Logic.fingerEvent(fingerPam.message, fingerPam.messageIsError);
            if (kind === "prompt") {
                root.fingerPrompted = true;
                // An unrecognised finger stays on screen for its moment.
                if (!fingerShowNoMatch.running)
                    root.fingerState = "ready";
            } else if (kind === "nomatch") {
                root.fingerNoMatches += 1;
                root.fingerState = "nomatch";
                fingerShowNoMatch.restart();
            } else if (kind === "retry") {
                root.fingerState = "retry";
            }
        }
        onCompleted: result => root.fingerFinished(Logic.resultName(result, PamResult))
        onError: error => console.warn(`chauvenity-lock: fingerprint PAM: ${PamError.toString(error)}`)
    }

    Timer {
        id: fingerShowNoMatch
        interval: 1500
        onTriggered: {
            if (root.fingerState === "nomatch")
                root.fingerState = "ready";
        }
    }

    Timer {
        id: fingerRestart
        onTriggered: root.startFinger()
    }

    // --- Caps Lock ----------------------------------------------------------
    // Qt does not say whether it is on, only that the key went down; the
    // keyboards' LEDs do.

    Process {
        id: capsProbe
        command: ["sh", "-c", "cat /sys/class/leds/*::capslock/brightness 2>/dev/null"]
        stdout: StdioCollector {
            id: capsOutput
            onStreamFinished: root.capsLock = Logic.capsLockOn(capsOutput.text)
        }
    }

    Timer {
        interval: 400
        running: true
        repeat: true
        triggeredOnStart: true
        onTriggered: capsProbe.running = true
    }

    // --- the lock -----------------------------------------------------------

    WlSessionLock {
        id: sessionLock
        locked: !root.preview

        WlSessionLockSurface {
            color: root.backgroundColor

            LockFace {
                anchors.fill: parent
                lock: root
            }
        }
    }

    // Long enough for the unlock to reach niri before the connection goes.
    Timer {
        id: quitAfterUnlock
        interval: 150
        onTriggered: Qt.quit()
    }

    // Locks again from scratch: for a process that is still up after an
    // unlock, which lock.sh would otherwise wait on for nothing.
    function relock() {
        if (root.preview || sessionLock.locked)
            return;
        release.stop();
        quitAfterUnlock.stop();
        root.buffer = "";
        root.passwordState = "idle";
        root.fingerState = "ready";
        root.fingerNoMatches = 0;
        root.fingerDeadRuns = 0;
        sessionLock.locked = true;
        root.startFinger();
    }

    Component.onCompleted: root.startFinger()

    // --- preview --------------------------------------------------------------

    LazyLoader {
        active: root.preview

        FloatingWindow {
            title: "chauvenity-lock preview"
            implicitWidth: 1280
            implicitHeight: 800
            color: root.backgroundColor
            onVisibleChanged: if (!visible) Qt.quit()

            LockFace {
                id: previewFace
                anchors.fill: parent
                lock: root
            }

            // For checking the preview from a script; nothing like it exists
            // while actually locked.
            IpcHandler {
                target: "lockpreview"

                function type(text: string): void {
                    root.edit(root.buffer + text);
                }
                function enter(): void {
                    root.submit();
                }
                function shot(path: string): void {
                    previewFace.grabToImage(result => result.saveToFile(path));
                }
            }
        }
    }

    // --- IPC ------------------------------------------------------------------
    //
    //     qs -c chauvenity-lock ipc call lock secure     true once niri confirmed
    //     qs -c chauvenity-lock ipc call lock lock       locks again, if it is not

    IpcHandler {
        target: "lock"

        function lock(): void {
            root.relock();
        }

        function secure(): bool {
            return sessionLock.secure;
        }
    }
}
