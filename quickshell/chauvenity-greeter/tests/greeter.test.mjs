// Unit tests for the login greeter.
//
//   node --test ~/.config/quickshell/chauvenity-greeter/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    INITIAL, step, execArgs, parseSessions, loadSessions, cycle, launchSpec, hintText, powerAction,
    FALLBACK_SESSION,
} from "../greeter.mjs";

const GNOME = `@@/usr/share/wayland-sessions/gnome.desktop
[Desktop Entry]
Name[fr]=GNOME
Name=GNOME
Exec=/usr/bin/gnome-session
Type=Application
DesktopNames=GNOME
`;
const CLASSIC = `@@/usr/share/wayland-sessions/gnome-classic.desktop
[Desktop Entry]
Name=GNOME Classic
Exec=gnome-session --session gnome-classic
DesktopNames=GNOME-Classic;GNOME;
`;
const NIRI = `@@/usr/share/wayland-sessions/niri.desktop
[Desktop Entry]
Name=Niri
Exec=niri-session
DesktopNames=niri
`;

test("loadSessions puts the preferred session first and the rest in order", () => {
    const sessions = loadSessions(GNOME + CLASSIC + NIRI, "niri");
    assert.deepEqual(sessions.map(s => s.id), ["niri", "gnome", "gnome-classic"]);
    assert.deepEqual(sessions.map(s => s.label), ["niri", "GNOME", "GNOME Classic"]);
});

test("a session is its Exec line and its DesktopNames", () => {
    const [classic] = parseSessions(CLASSIC);
    assert.deepEqual(classic.command, ["gnome-session", "--session", "gnome-classic"]);
    assert.deepEqual(classic.desktopNames, ["GNOME-Classic", "GNOME"]);
});

test("sessions that are hidden, or have nothing to run, are not offered", () => {
    const hidden = "@@/x/a.desktop\n[Desktop Entry]\nExec=a\nNoDisplay=true\n";
    const empty = "@@/x/b.desktop\n[Desktop Entry]\nName=b\n";
    assert.deepEqual(parseSessions(hidden + empty + NIRI).map(s => s.id), ["niri"]);
});

test("with no sessions at all, niri-session", () => {
    assert.deepEqual(loadSessions("", "niri"), [FALLBACK_SESSION]);
    assert.deepEqual(FALLBACK_SESSION.command, ["niri-session"]);
});

test("execArgs splits like a shell would and drops field codes", () => {
    assert.deepEqual(execArgs('sh -c "echo hi there" %U'), ["sh", "-c", "echo hi there"]);
    assert.deepEqual(execArgs("a\\ b 'c d'"), ["a b", "c d"]);
});

test("cycle wraps both ways", () => {
    assert.equal(cycle(0, 3, 1), 1);
    assert.equal(cycle(2, 3, 1), 0);
    assert.equal(cycle(0, 3, -1), 2);
    assert.equal(cycle(0, 0, 1), 0);
});

test("launchSpec gives the session the environment a display manager would", () => {
    const [classic] = parseSessions(CLASSIC);
    assert.deepEqual(launchSpec(classic), {
        command: ["gnome-session", "--session", "gnome-classic"],
        environment: [
            "XDG_SESSION_TYPE=wayland",
            "XDG_SESSION_DESKTOP=gnome-classic",
            "XDG_CURRENT_DESKTOP=GNOME-Classic:GNOME",
        ],
    });
});

test("the hint follows what Ctrl+Alt+Del opened", () => {
    assert.equal(hintText(false), "Tab session · Ctrl+Alt+Del power");
    assert.equal(hintText(true), "S suspend · R reboot · P power off · Esc back");
    assert.equal(powerAction("P").command[1], "poweroff");
    assert.equal(powerAction("x"), null);
});

// Plays events through the machine; the last state and every effect, in order.
function run(events, from = INITIAL) {
    let state = from;
    const effects = [];
    for (const event of events) {
        const result = step(state, event);
        state = result.state;
        effects.push(...result.effects);
    }
    return { state, effects };
}

const typed = text => ({ type: "edit", text });
const submit = { type: "submit", available: true };
const askForPassword = { type: "authMessage", responseRequired: true };

test("typing fills the buffer, emptying it goes back to idle", () => {
    assert.equal(run([typed("abc")]).state.phase, "typing");
    assert.equal(run([typed("abc"), typed("")]).state.phase, "idle");
});

test("Enter on nothing does nothing", () => {
    assert.deepEqual(run([submit]), { state: INITIAL, effects: [] });
});

test("a right password: create, answer with it, then launch", () => {
    const { state, effects } = run([typed("hunter2"), submit, askForPassword, { type: "readyToLaunch" }]);
    assert.deepEqual(effects, [
        { type: "createSession" },
        { type: "respond", text: "hunter2" },
        { type: "launchSoon" },
    ]);
    assert.equal(state.phase, "unlocked");
    assert.equal(state.buffer, "hunter2");
});

test("a wrong password empties the buffer, cancels, and settles back to idle", () => {
    const wrong = run([typed("nope"), submit, askForPassword, { type: "authFailure" }]);
    assert.equal(wrong.state.phase, "wrong");
    assert.equal(wrong.state.buffer, "");
    assert.deepEqual(wrong.effects.slice(-2), [{ type: "cancelSession" }, { type: "settleLater" }]);
    assert.equal(step(wrong.state, { type: "settle" }).state.phase, "idle");
});

test("typing during the wrong-password moment is kept when it settles", () => {
    const wrong = run([typed("nope"), submit, askForPassword, { type: "authFailure" }, typed("a")]);
    assert.equal(step(wrong.state, { type: "settle" }).state.phase, "typing");
});

test("a second question in one attempt is an error, not a second answer", () => {
    const { state, effects } = run([typed("x"), submit, askForPassword, askForPassword]);
    assert.equal(state.phase, "error");
    assert.deepEqual(effects.filter(e => e.type === "respond").length, 1);
    assert.ok(effects.some(e => e.type === "cancelSession"));
});

test("messages that ask for nothing are not answered", () => {
    const { effects } = run([typed("x"), submit, { type: "authMessage", responseRequired: false }]);
    assert.deepEqual(effects, [{ type: "createSession" }]);
});

test("no greetd to talk to: an error, nothing sent", () => {
    const { state, effects } = run([typed("x"), { type: "submit", available: false }]);
    assert.equal(state.phase, "error");
    assert.deepEqual(effects, [{ type: "settleLater" }]);
});

test("typing is ignored while greetd checks and after it accepted", () => {
    const checking = run([typed("abc"), submit]).state;
    assert.equal(step(checking, typed("abcd")).state.buffer, "abc");
    const accepted = run([typed("abc"), submit, askForPassword, { type: "readyToLaunch" }]).state;
    assert.equal(step(accepted, typed("")).state.buffer, "abc");
});

test("a broken connection after the session was accepted is an error, not a screen that never answers", () => {
    const accepted = run([typed("abc"), submit, askForPassword, { type: "readyToLaunch" }]).state;
    const broken = step(accepted, { type: "error" });
    assert.equal(broken.state.phase, "error");
    assert.deepEqual(broken.effects, [{ type: "cancelSession" }, { type: "settleLater" }]);
});

test("Escape while greetd is checking cancels the attempt", () => {
    const checking = run([typed("abc"), submit]).state;
    const { state, effects } = step(checking, typed(""));
    assert.equal(state.phase, "idle");
    assert.equal(state.buffer, "");
    assert.deepEqual(effects, [{ type: "cancelSession" }]);
    assert.deepEqual(step(state, { type: "readyToLaunch" }), { state, effects: [] });
});

test("Escape after the session was accepted changes nothing", () => {
    const accepted = run([typed("abc"), submit, askForPassword, { type: "readyToLaunch" }]).state;
    assert.deepEqual(step(accepted, typed("")), { state: accepted, effects: [] });
});

test("a stray authFailure or readyToLaunch outside an attempt is ignored", () => {
    assert.deepEqual(step(INITIAL, { type: "authFailure" }), { state: INITIAL, effects: [] });
    assert.deepEqual(step(INITIAL, { type: "readyToLaunch" }), { state: INITIAL, effects: [] });
});
