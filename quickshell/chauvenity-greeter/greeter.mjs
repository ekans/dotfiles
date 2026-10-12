// What the login greeter (shell.qml, GreeterFace.qml) decides: the login as a
// small state machine over greetd's messages, which sessions there are and
// what launching one means, and the words on screen.
//
// Plain ECMAScript, no QML: the greeter imports it and tests/greeter.test.mjs
// runs it under node. Keep to what Qt's JavaScript engine parses.

// Single user for now; shell.qml reads CHAUVENITY_GREETER_USER first.
export const USER = "ducatore";

// The session Tab starts from; the others follow in alphabetical order.
export const DEFAULT_SESSION = "niri";

// Names that read better than the .desktop file's Name=, which says "Niri".
const LABELS = { niri: "niri" };

// Used when /usr/share/wayland-sessions has nothing to offer.
export const FALLBACK_SESSION = {
    id: "niri",
    label: "niri",
    command: ["niri-session"],
    desktopNames: ["niri"],
};

// Ctrl+Alt+Del opens these; the letter picks one.
export const POWER_ACTIONS = [
    { key: "s", label: "suspend", command: ["systemctl", "suspend"] },
    { key: "r", label: "reboot", command: ["systemctl", "reboot"] },
    { key: "p", label: "power off", command: ["systemctl", "poweroff"] },
];

export function powerAction(text) {
    const key = String(text ?? "").toLowerCase();
    return POWER_ACTIONS.find(a => a.key === key) ?? null;
}

// The dim line near the bottom.
export function hintText(powerOpen) {
    if (powerOpen)
        return POWER_ACTIONS.map(a => `${a.key.toUpperCase()} ${a.label}`).join(" · ") + " · Esc back";
    return "Tab session · Ctrl+Alt+Del power";
}

// --- sessions ---------------------------------------------------------------

// A .desktop file's [Desktop Entry] group, as {Key: value}, localised keys
// (Name[fr]) left out.
function desktopEntry(text) {
    const entry = {};
    let inEntry = false;
    for (const raw of String(text).split("\n")) {
        const line = raw.trim();
        if (line.startsWith("[")) {
            inEntry = line === "[Desktop Entry]";
        } else if (inEntry) {
            const eq = line.indexOf("=");
            if (eq > 0 && !line.startsWith("#") && !line.slice(0, eq).includes("["))
                entry[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
        }
    }
    return entry;
}

// An Exec= line as an argument list: quotes group, a backslash escapes, and
// the %f, %u, … field codes mean nothing to a session.
export function execArgs(exec) {
    const args = [];
    let current = null;
    let quote = null;
    const text = String(exec).replace(/%[a-zA-Z]/g, "");
    for (let i = 0; i < text.length; i++) {
        const c = text[i];
        if (c === "\\" && i + 1 < text.length) {
            current = (current ?? "") + text[++i];
        } else if (quote) {
            if (c === quote)
                quote = null;
            else
                current += c;
        } else if (c === '"' || c === "'") {
            quote = c;
            current = current ?? "";
        } else if (/\s/.test(c)) {
            if (current !== null)
                args.push(current);
            current = null;
        } else {
            current = (current ?? "") + c;
        }
    }
    if (current !== null)
        args.push(current);
    return args;
}

// The files of a sessions directory, each behind a line "@@<path>" (what
// shell.qml's `cat` loop prints), as sessions.
export function parseSessions(dump) {
    const sessions = [];
    for (const chunk of String(dump).split(/^@@/m).slice(1)) {
        const newline = chunk.indexOf("\n");
        const path = chunk.slice(0, newline);
        const entry = desktopEntry(chunk.slice(newline + 1));
        const id = path.split("/").pop().replace(/\.desktop$/, "");
        const command = execArgs(entry.Exec ?? "");
        if (command.length === 0 || entry.Hidden === "true" || entry.NoDisplay === "true")
            continue;
        sessions.push({
            id,
            label: LABELS[id] ?? entry.Name ?? id,
            command,
            desktopNames: (entry.DesktopNames ?? "").split(";").filter(n => n !== ""),
        });
    }
    return sessions;
}

// What Tab walks through: `preferred` first, the rest by id; the fallback
// when there are none.
export function loadSessions(dump, preferred) {
    const sessions = parseSessions(dump);
    if (sessions.length === 0)
        return [FALLBACK_SESSION];
    return sessions.sort((a, b) => (b.id === preferred) - (a.id === preferred) || (a.id < b.id ? -1 : 1));
}

// The index Tab (step 1) or Shift+Tab (step -1) moves to.
export function cycle(index, count, step) {
    return count === 0 ? 0 : (((index + step) % count) + count) % count;
}

// What greetd is asked to start: the command and the environment a display
// manager would give it.
export function launchSpec(session) {
    return {
        command: session.command,
        environment: [
            "XDG_SESSION_TYPE=wayland",
            `XDG_SESSION_DESKTOP=${session.id}`,
            `XDG_CURRENT_DESKTOP=${session.desktopNames.join(":")}`,
        ],
    };
}

// --- the login ----------------------------------------------------------------

// One login attempt, as greetd sees it: create a session, answer its password
// question, then start the session. greetd ends a session whose password was
// refused, so a new attempt starts from create again.
//
//   phase     "idle", "typing", "checking", "wrong", "error" or "unlocked": the
//             names the lock screen's face draws
//   buffer    what is typed
//   answered  whether this attempt's password went to greetd; a second
//             question (an expired password asking for a new one) is not one
//             this screen can answer
export const INITIAL = { phase: "idle", buffer: "", answered: false };

// Qt's JavaScript engine has no object spread.
const update = (state, changes) => Object.assign({}, state, changes);

// Where an attempt that got nowhere settles after a moment.
function settled(state) {
    return update(state, { phase: state.buffer === "" ? "idle" : "typing" });
}

const failed = (state, phase, effects) => ({
    state: update(state, { phase, buffer: "", answered: false }),
    effects: [...effects, { type: "settleLater" }],
});

// The next state, and what the shell is to do about it. Events:
//
//   {type: "edit", text}        the buffer changed; "" while checking is Escape
//   {type: "submit", available} Enter; `available`: greetd's socket is there
//   {type: "authMessage", responseRequired, ...}   from greetd
//   {type: "authFailure"}       greetd refused the password
//   {type: "readyToLaunch"}     greetd accepted it
//   {type: "error"}             the connection to greetd broke
//   {type: "settle"}            the timer settleLater set
//
// Effects: createSession, respond {text}, cancelSession, settleLater and
// launchSoon.
export function step(state, event) {
    const busy = state.phase === "checking" || state.phase === "unlocked";
    switch (event.type) {
    case "edit":
        // Escape while greetd is thinking: give up on the attempt.
        if (state.phase === "checking" && event.text === "")
            return { state: update(state, { phase: "idle", buffer: "", answered: false }), effects: [{ type: "cancelSession" }] };
        if (busy)
            return { state, effects: [] };
        return { state: update(state, { buffer: event.text, phase: event.text === "" ? "idle" : "typing" }), effects: [] };
    case "submit":
        if (state.buffer === "" || busy)
            return { state, effects: [] };
        if (!event.available)
            return failed(state, "error", []);
        return { state: update(state, { phase: "checking", answered: false }), effects: [{ type: "createSession" }] };
    case "authMessage":
        if (state.phase !== "checking" || !event.responseRequired)
            return { state, effects: [] };
        if (state.answered)
            return failed(state, "error", [{ type: "cancelSession" }]);
        return { state: update(state, { answered: true }), effects: [{ type: "respond", text: state.buffer }] };
    case "authFailure":
        return state.phase === "checking" ? failed(state, "wrong", [{ type: "cancelSession" }]) : { state, effects: [] };
    case "readyToLaunch":
        return state.phase === "checking"
            ? { state: update(state, { phase: "unlocked" }), effects: [{ type: "launchSoon" }] }
            : { state, effects: [] };
    case "error":
        return failed(state, "error", [{ type: "cancelSession" }]);
    case "settle":
        return {
            state: state.phase === "wrong" || state.phase === "error" ? settled(state) : state,
            effects: [],
        };
    default:
        return { state, effects: [] };
    }
}
