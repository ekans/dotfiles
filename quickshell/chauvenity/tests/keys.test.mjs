// Unit tests for the keyboard shortcuts panel's logic.
//
//   node --test ~/.config/quickshell/chauvenity/tests/

import { test } from "node:test";
import assert from "node:assert/strict";
import {
    parseKdl,
    resolveBinds,
    chord,
    bindId,
    describe,
    groupBinds,
    filterGroups,
    packColumns,
} from "../keys.mjs";

const ENV = { HOME: "/home/me" };
const USER = "/home/me/.config/niri/config.kdl";
const SYSTEM = "/etc/niri/config.kdl";

// Resolves with every file it asks for answered from `files`, a missing one
// as unreadable: what the panel does, one read at a time.
function resolveAll(files, env = ENV) {
    const known = {};
    for (let step = 0; step < 50; step++) {
        const result = resolveBinds(known, env);
        if (!result.need)
            return result;
        known[result.need] = files[result.need] ?? null;
    }
    throw new Error("resolveBinds kept asking");
}

function bind(key, action, args = [], title) {
    return { key, action, args, title };
}

// The rows of a group, as "text = keys" lines, which is how they read.
function lines(groups, name) {
    const group = groups.find(g => g.name === name);
    if (!group)
        return undefined;
    return group.rows.map(row => `${row.text} = ${row.chords
        .map(c => [...c.mods, c.keys.join(" | ")].join("+")).join(" , ")}`);
}

// --- parseKdl ---------------------------------------------------------------

test("parseKdl reads nodes, arguments, properties and children", () => {
    const nodes = parseKdl(`
        include "/etc/niri/config.kdl"
        binds {
            Mod+Q repeat=false { close-window; }
            Mod+1 { focus-workspace 1; }
            Mod+Return hotkey-overlay-title="Open a Terminal: ghostty" { spawn "ghostty" "-e" "fish"; }
        }
    `);
    assert.deepEqual(nodes.map(n => n.name), ["include", "binds"]);
    assert.deepEqual(nodes[0].args, ["/etc/niri/config.kdl"]);

    const [q, one, ret] = nodes[1].children;
    assert.equal(q.name, "Mod+Q");
    assert.deepEqual(q.props, { repeat: false });
    assert.equal(q.children[0].name, "close-window");
    assert.deepEqual(one.children[0].args, [1]);
    assert.equal(ret.props["hotkey-overlay-title"], "Open a Terminal: ghostty");
    assert.deepEqual(ret.children[0].args, ["ghostty", "-e", "fish"]);
});

test("parseKdl tells a null from the string \"null\"", () => {
    const [a, b, c] = parseKdl(`
        a title=null
        b title=#null
        c title="null"
    `);
    assert.equal(a.props.title, null);
    assert.equal(b.props.title, null);
    assert.equal(c.props.title, "null");
});

test("parseKdl skips line, block and slashdash comments", () => {
    const nodes = parseKdl(`
        // a line comment
        /* a block /* nested */ comment */
        binds {
            /-Mod+X { quit; }
            Mod+Y /* inline */ { quit; } // trailing
            Mod+Z /-repeat=false { quit; }
        }
        /-binds { Mod+W { quit; } }
    `);
    assert.equal(nodes.length, 1);
    const keys = nodes[0].children.map(n => n.name);
    assert.deepEqual(keys, ["Mod+Y", "Mod+Z"]);
    assert.deepEqual(nodes[0].children[1].props, {});
});

test("parseKdl reads escapes and raw strings", () => {
    const [node] = parseKdl(String.raw`n "a\"b\\c\n" r"C:\path" r#"say "hi""#`);
    assert.deepEqual(node.args, ['a"b\\c\n', "C:\\path", 'say "hi"']);
});

test("parseKdl reads children spread over lines, and nodes ended by ;", () => {
    const [binds] = parseKdl(`binds {
        Mod+T {
            spawn "foot"
        }
        Mod+A { quit; }; Mod+B { quit; }
    }`);
    assert.deepEqual(binds.children.map(n => n.name), ["Mod+T", "Mod+A", "Mod+B"]);
    assert.deepEqual(binds.children[0].children[0].args, ["foot"]);
});

test("parseKdl says where an unclosed block starts going wrong", () => {
    assert.throws(() => parseKdl("binds {\n Mod+Q { quit; }\n"), /line 3/);
});

// --- resolveBinds -----------------------------------------------------------

test("resolveBinds asks for one file at a time, the user's config first", () => {
    assert.deepEqual(resolveBinds({}, ENV), { need: USER });
    assert.deepEqual(resolveBinds({ [USER]: null }, ENV), { need: SYSTEM });
});

test("resolveBinds falls back to /etc when the user has no config", () => {
    const result = resolveAll({ [SYSTEM]: "binds { Mod+Q { close-window; } }" });
    assert.equal(result.root, SYSTEM);
    assert.deepEqual(result.binds.map(b => b.action), ["close-window"]);
    assert.deepEqual(result.problems, []);
});

test("resolveBinds honours NIRI_CONFIG and XDG_CONFIG_HOME", () => {
    assert.deepEqual(resolveBinds({}, { ...ENV, NIRI_CONFIG: "/tmp/n.kdl" }), { need: "/tmp/n.kdl" });
    assert.deepEqual(resolveBinds({}, { ...ENV, XDG_CONFIG_HOME: "/cfg" }), { need: "/cfg/niri/config.kdl" });
});

test("a later bind overrides an included one and keeps its place", () => {
    const result = resolveAll({
        [USER]: `include "/etc/niri/config.kdl"
                 binds { Mod+Up { focus-workspace-up; } }`,
        [SYSTEM]: `binds {
                       Mod+Left { focus-column-left; }
                       Mod+Up { focus-window-up; }
                       Mod+Q { close-window; }
                   }`,
    });
    assert.equal(result.root, USER);
    assert.deepEqual(result.files, [USER, SYSTEM]);
    assert.deepEqual(result.binds.map(b => `${b.key} ${b.action}`), [
        "Mod+Left focus-column-left",
        "Mod+Up focus-workspace-up",
        "Mod+Q close-window",
    ]);
});

test("an override matches the key whatever the modifier order or case", () => {
    const result = resolveAll({
        [USER]: `binds { Mod+Shift+Slash { show-hotkey-overlay; } }
                 binds { shift+mod+slash { quit; } }`,
    });
    assert.deepEqual(result.binds.map(b => b.action), ["quit"]);
});

test("includes resolve relative to the including file, and from ~", () => {
    const result = resolveAll({
        [USER]: `include "binds/apps.kdl"
                 include "~/more.kdl"`,
        "/home/me/.config/niri/binds/apps.kdl": `include "../shared.kdl"`,
        "/home/me/.config/niri/shared.kdl": "binds { Mod+A { quit; } }",
        "/home/me/more.kdl": "binds { Mod+B { quit; } }",
    });
    assert.deepEqual(result.binds.map(b => b.key), ["Mod+A", "Mod+B"]);
    assert.deepEqual(result.problems, []);
});

test("a missing include, a parse error and a cycle are problems, not failures", () => {
    const result = resolveAll({
        [USER]: `include "gone.kdl"
                 include "broken.kdl"
                 include "loop.kdl"
                 binds { Mod+Q { close-window; } }`,
        "/home/me/.config/niri/broken.kdl": "binds {",
        "/home/me/.config/niri/loop.kdl": `include "config.kdl"`,
    });
    assert.deepEqual(result.binds.map(b => b.action), ["close-window"]);
    assert.equal(result.problems.length, 3);
    assert.match(result.problems[0], /cannot read \/home\/me\/\.config\/niri\/gone\.kdl/);
    assert.match(result.problems[1], /broken\.kdl/);
    assert.match(result.problems[2], /include cycle/);
});

test("resolveBinds keeps the overlay title, null included", () => {
    const result = resolveAll({
        [USER]: `binds {
                     Mod+T hotkey-overlay-title="Snippets" { spawn "qs"; }
                     Mod+S hotkey-overlay-title=null { spawn "orca"; }
                     Mod+Q { close-window; }
                 }`,
    });
    assert.deepEqual(result.binds.map(b => b.title), ["Snippets", null, undefined]);
});

test("no config at all is a problem with no binds", () => {
    const result = resolveAll({});
    assert.equal(result.root, null);
    assert.deepEqual(result.binds, []);
    assert.match(result.problems[0], /no niri config/);
});

// --- chord / bindId -----------------------------------------------------------

test("chord names Mod as Super and puts modifiers in one order", () => {
    assert.deepEqual(chord("Shift+Mod+Slash"), { mods: ["Super", "Shift"], key: "/" });
    assert.deepEqual(chord("Mod+Shift+Ctrl+Left"), { mods: ["Super", "Ctrl", "Shift"], key: "←" });
    assert.deepEqual(chord("Control+Alt+Delete"), { mods: ["Ctrl", "Alt"], key: "Del" });
});

test("chord gives keys the label printed on them", () => {
    const key = k => chord(k).key;
    assert.equal(key("Mod+Return"), "Enter");
    assert.equal(key("Mod+Page_Down"), "PgDn");
    assert.equal(key("Mod+Minus"), "-");
    assert.equal(key("Mod+Equal"), "=");
    assert.equal(key("Mod+Comma"), ",");
    assert.equal(key("Mod+Period"), ".");
    assert.equal(key("Print"), "PrtSc");
    assert.equal(key("Mod+q"), "Q");
    assert.equal(key("Mod+F11"), "F11");
    assert.equal(key("Mod+WheelScrollDown"), "Wheel ↓");
    assert.equal(key("XF86AudioRaiseVolume"), "Vol +");
    assert.equal(key("XF86Explorer"), "Explorer");
});

test("bindId is the same for the same key however it is written", () => {
    assert.equal(bindId("Mod+Shift+Slash"), bindId("shift+mod+slash"));
    assert.equal(bindId("Ctrl+Alt+Delete"), bindId("Alt+Control+delete"));
    assert.notEqual(bindId("Mod+Q"), bindId("Mod+Shift+Q"));
});

// --- describe ------------------------------------------------------------------

test("describe prefers the overlay title, without its Pango markup", () => {
    assert.equal(describe(bind("Mod+T", "spawn", ["qs"], "Snippets")), "Snippets");
    assert.equal(
        describe(bind("Mod+S", "spawn", ["x"], "<b>Toggle</b> <span foreground='red'>Dark</span> &amp; Light")),
        "Toggle Dark & Light");
});

test("describe says what an untitled spawn runs", () => {
    assert.equal(describe(bind("Mod+E", "spawn", ["/usr/bin/nautilus", "--new-window"])), "Run nautilus");
    assert.equal(describe(bind("Mod+E", "spawn-sh", ["pkill orca || exec orca"])), "Run pkill");
});

test("describe words common actions plainly, and the rest from their name", () => {
    assert.equal(describe(bind("Mod+Q", "close-window")), "Close window");
    assert.equal(describe(bind("Mod+1", "focus-workspace", [3])), "Workspace 3");
    assert.equal(describe(bind("Mod+Minus", "set-column-width", ["-10%"])), "Column width -10%");
    assert.equal(describe(bind("Mod+Left", "focus-column-left")), "Column left");
    assert.equal(describe(bind("Mod+Ctrl+Left", "move-column-to-monitor-left")), "Column to monitor left");
    assert.equal(describe(bind("Mod+X", "toggle-window-rule-opacity")), "Toggle window rule opacity");
});

// --- groupBinds ------------------------------------------------------------------

test("binds are grouped by what they act on, in a fixed group order", () => {
    const groups = groupBinds([
        bind("Print", "screenshot"),
        bind("Mod+Q", "close-window"),
        bind("Mod+Shift+E", "quit"),
        bind("Mod+D", "spawn", ["fuzzel"], "Run an Application: fuzzel"),
        bind("Mod+R", "switch-preset-column-width"),
        bind("Mod+Page_Down", "focus-workspace-down"),
        bind("Mod+Shift+Left", "focus-monitor-left"),
        bind("Mod+Ctrl+Left", "move-column-left"),
        bind("Mod+X", "do-screen-transition"),
    ]);
    assert.deepEqual(groups.map(g => g.name),
        ["Launch", "Windows", "Focus", "Move", "Workspaces", "Size", "Screenshots", "Session", "Other"]);
});

test("one action bound to several keys is one row", () => {
    const groups = groupBinds([
        bind("Mod+Shift+E", "quit"),
        bind("Ctrl+Alt+Delete", "quit"),
    ]);
    assert.deepEqual(lines(groups, "Session"), ["Quit niri = Super+Shift+E , Ctrl+Alt+Del"]);
});

test("keys sharing their modifiers are written once, as alternatives", () => {
    const groups = groupBinds([
        bind("Mod+O", "toggle-overview"),
        bind("Mod+Tab", "toggle-overview"),
    ]);
    assert.deepEqual(lines(groups, "Workspaces"), ["Overview = Super+O | Tab"]);
});

test("left and right, up and down, first and last share a row", () => {
    const groups = groupBinds([
        bind("Mod+Left", "focus-column-left"),
        bind("Mod+Right", "focus-column-right"),
        bind("Mod+H", "focus-column-left"),
        bind("Mod+L", "focus-column-right"),
        bind("Mod+Home", "focus-column-first"),
        bind("Mod+End", "focus-column-last"),
        bind("Mod+Up", "focus-workspace-up"),
        bind("Mod+Down", "focus-workspace-down"),
    ]);
    assert.deepEqual(lines(groups, "Focus"), [
        "Column left / right = Super+← → | H L",
        "First / last column = Super+Home End",
    ]);
    assert.deepEqual(lines(groups, "Workspaces"), ["Workspace up / down = Super+↑ ↓"]);
});

test("opposite keys pair up by what they are, whatever order they came in", () => {
    const groups = groupBinds([
        bind("Mod+K", "focus-workspace-up"),
        bind("Mod+Up", "focus-workspace-up"),
        bind("Mod+Down", "focus-workspace-down"),
        bind("Mod+J", "focus-workspace-down"),
    ]);
    assert.deepEqual(lines(groups, "Workspaces"), ["Workspace up / down = Super+K J | ↑ ↓"]);
});

test("a pair whose keys do not line up stays two rows", () => {
    const groups = groupBinds([
        bind("Mod+Left", "focus-column-left"),
        bind("Mod+Shift+Right", "focus-column-right"),
    ]);
    assert.deepEqual(lines(groups, "Focus"), ["Column left = Super+←", "Column right = Super+Shift+→"]);
});

test("minus and plus the same amount share a row", () => {
    const groups = groupBinds([
        bind("Mod+Minus", "set-column-width", ["-10%"]),
        bind("Mod+Equal", "set-column-width", ["+10%"]),
    ]);
    assert.deepEqual(lines(groups, "Size"), ["Column width -10% / +10% = Super+- ="]);
});

test("numbered binds on their digit collapse into one row", () => {
    const binds = [];
    for (let n = 1; n <= 9; n++) {
        binds.push(bind(`Mod+${n}`, "focus-workspace", [n]));
        binds.push(bind(`Mod+Ctrl+${n}`, "move-column-to-workspace", [n]));
    }
    const groups = groupBinds(binds);
    assert.deepEqual(lines(groups, "Workspaces"), [
        "Workspace 1–9 = Super+1–9",
        "Move column to 1–9 = Super+Ctrl+1–9",
    ]);
});

test("a short or broken run of numbers is left as it is", () => {
    const groups = groupBinds([
        bind("Mod+1", "focus-workspace", [1]),
        bind("Mod+2", "focus-workspace", [2]),
        bind("Mod+5", "focus-workspace", ["chat"]),
    ]);
    assert.deepEqual(lines(groups, "Workspaces"), [
        "Workspace 1 = Super+1",
        "Workspace 2 = Super+2",
        "Workspace chat = Super+5",
    ]);
});

test("a null title hides a bind, and so does an untitled hardware key", () => {
    const groups = groupBinds([
        bind("Mod+S", "spawn", ["orca"], null),
        bind("XF86AudioMute", "spawn", ["wpctl"]),
        bind("XF86AudioPlay", "spawn", ["playerctl"], "Play or pause"),
        bind("Mod+Q", "close-window"),
    ]);
    assert.deepEqual(lines(groups, "Launch"), ["Play or pause = Play"]);
    assert.deepEqual(lines(groups, "Windows"), ["Close window = Super+Q"]);
});

test("rows keep the order their binds came in", () => {
    const groups = groupBinds([
        bind("Mod+Return", "spawn", ["ghostty"], "Terminal"),
        bind("Mod+D", "spawn", ["fuzzel"], "Launcher"),
        bind("Mod+T", "spawn", ["qs"], "Snippets"),
    ]);
    assert.deepEqual(lines(groups, "Launch"),
        ["Terminal = Super+Enter", "Launcher = Super+D", "Snippets = Super+T"]);
});

// --- filterGroups ---------------------------------------------------------------

test("filterGroups keeps the rows every word of the query matches", () => {
    const groups = groupBinds([
        bind("Mod+Q", "close-window"),
        bind("Mod+F", "maximize-column"),
        bind("Mod+T", "spawn", ["qs"], "Snippets"),
    ]);
    assert.deepEqual(filterGroups(groups, "  "), groups);
    assert.deepEqual(lines(filterGroups(groups, "COLUMN max"), "Windows"), ["Maximize column = Super+F"]);
    assert.deepEqual(filterGroups(groups, "column").map(g => g.name), ["Windows"]);
});

test("filterGroups matches key labels and the group name too", () => {
    const groups = groupBinds([
        bind("Mod+Q", "close-window"),
        bind("Print", "screenshot"),
    ]);
    assert.deepEqual(filterGroups(groups, "prtsc").map(g => g.name), ["Screenshots"]);
    assert.deepEqual(filterGroups(groups, "windows").map(g => g.name), ["Windows"]);
});

// --- packColumns ----------------------------------------------------------------

const sized = (...counts) => counts.map((n, i) => ({ name: `g${i}`, rows: Array(n).fill({}) }));
const names = columns => columns.map(col => col.map(g => g.name));

test("packColumns keeps the group order and evens out the columns", () => {
    assert.deepEqual(names(packColumns(sized(8, 2, 2, 4, 4), 2)), [["g0", "g1"], ["g2", "g3", "g4"]]);
    assert.deepEqual(names(packColumns(sized(3, 3, 3), 3)), [["g0"], ["g1"], ["g2"]]);
});

test("packColumns never makes more columns than groups, nor fewer than one", () => {
    assert.deepEqual(names(packColumns(sized(5, 5), 4)), [["g0"], ["g1"]]);
    assert.deepEqual(names(packColumns(sized(2, 2), 0)), [["g0", "g1"]]);
    assert.deepEqual(packColumns([], 3), []);
});
